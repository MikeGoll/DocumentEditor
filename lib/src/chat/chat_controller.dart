import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../documents/document_state.dart';
import 'chat_history_store.dart';
import 'chat_message.dart';

/// Signature of the callback that produces an agent reply for a
/// conversation.
///
/// Reply text is delivered incrementally via [onChunk]; each tool the
/// agent runs is reported via [onToolActivity]; failures are reported once
/// via [onError] with a user-facing message. Implementations should poll
/// [isCancelled] and stop (without further callbacks) once it returns
/// true. Implementations should not throw.
typedef AgentResponder = Future<void> Function({
  required List<ChatMessage> history,
  required void Function(String chunk) onChunk,
  required void Function(String error) onError,
  required void Function(String summary) onToolActivity,
  required bool Function() isCancelled,
});

/// In-memory chat state backed by a [ChatHistoryStore].
///
/// The controller follows the open document: each document has its own
/// history file, and switching documents swaps the loaded conversation.
///
/// When an [agent] responder is provided, [send] also asks it for a reply:
/// the streamed agent message is appended to (and updated in place as
/// chunks arrive) and persisted when the reply completes. Without a
/// responder, sending only appends the user message to the local history.
/// Listeners are notified synchronously when messages change; disk writes
/// happen in the background and never block the UI.
class ChatController extends ChangeNotifier {
  ChatController({
    required DocumentState document,
    required ChatHistoryStore store,
    String session = ChatHistoryStore.defaultSession,
    AgentResponder? agent,
  })  : _document = document,
        _store = store,
        _session = session,
        _agent = agent {
    _currentDocumentId = documentIdFor(_document);
    _document.addListener(_onDocumentChanged);
    _load(_currentDocumentId!);
  }

  final DocumentState _document;
  final ChatHistoryStore _store;
  final String _session;
  final AgentResponder? _agent;

  List<ChatMessage> _messages = const [];
  bool _loading = true;
  bool _disposed = false;
  String? _currentDocumentId;

  /// Whether an agent reply is currently being streamed.
  bool _responding = false;

  /// Bumped whenever the conversation is reset or the document changes so
  /// that a stale in-flight reply is discarded instead of writing into the
  /// new conversation.
  int _responseGeneration = 0;

  /// Index of the agent message currently being streamed, if any.
  int? _streamingIndex;

  /// Accumulated text of the in-flight agent reply.
  final StringBuffer _streamBuffer = StringBuffer();

  /// The in-flight agent reply, if any.
  Future<void>? _replyFuture;

  /// Serializes history I/O so quick successive sends cannot write the file
  /// out of order.
  Future<void> _pending = Future.value();

  /// Completes when all in-flight history I/O has finished.
  ///
  /// Useful in tests to deterministically wait for file writes.
  Future<void> get whenIdle => _pending;

  /// Completes when the in-flight agent reply has finished (immediately
  /// when no reply is in flight).
  Future<void> get whenReplyDone => _replyFuture ?? Future.value();

  /// Messages in chronological order.
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// Whether the initial history load is still in flight.
  bool get isLoading => _loading;

  /// Whether an agent reply is currently being streamed.
  bool get isResponding => _responding;

  /// The history file name component for the open document.
  ///
  /// Derived from the file's base name (extension stripped) so history
  /// follows the document, not its location. Unnamed characters are replaced
  /// with underscores; documents with no file use `untitled`.
  static String documentIdFor(DocumentState document) {
    final name = document.fileName;
    if (name == null) return 'untitled';
    final sanitized = p
        .basenameWithoutExtension(name)
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return sanitized.isEmpty ? 'untitled' : sanitized;
  }

  @override
  void dispose() {
    _disposed = true;
    _document.removeListener(_onDocumentChanged);
    super.dispose();
  }

  /// Appends [text] as a user message and persists the history.
  ///
  /// When an agent responder is configured and no reply is in flight, the
  /// agent is asked for a reply, which is streamed into the conversation
  /// (see [isResponding]). Listeners are notified immediately; file writes
  /// are best-effort and do not block the UI. Does nothing when [text] is
  /// blank.
  Future<void> send(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Future.value();
    _messages = [
      ..._messages,
      ChatMessage.create(role: ChatRole.user, text: trimmed),
    ];
    _notify();
    final persist = _persist();
    final agent = _agent;
    if (agent != null && !_responding) {
      final reply = _respond(agent);
      _replyFuture = reply;
      unawaited(reply);
    }
    return persist;
  }

  /// Asks [agent] for a reply to the current conversation and streams it
  /// into the message list.
  Future<void> _respond(AgentResponder agent) async {
    _responding = true;
    final generation = _responseGeneration;
    _streamingIndex = null;
    _streamBuffer.clear();
    _notify();
    try {
      await agent(
        history: _messages,
        onChunk: (chunk) {
          if (generation != _responseGeneration) return; // stale reply
          _streamBuffer.write(chunk);
          final text = _streamBuffer.toString();
          final list = List<ChatMessage>.of(_messages);
          final index = _streamingIndex;
          if (index == null) {
            list.add(ChatMessage.create(role: ChatRole.agent, text: text));
            _streamingIndex = list.length - 1;
          } else {
            list[index] = list[index].copyWith(text: text);
          }
          _messages = list;
          _notify();
        },
        onError: (error) {
          if (generation != _responseGeneration) return; // stale reply
          appendAgentMessage(error);
        },
        onToolActivity: (summary) {
          if (generation != _responseGeneration) return; // stale reply
          _messages = [
            ..._messages,
            ChatMessage.create(role: ChatRole.tool, text: summary),
          ];
          // Text after a tool call starts a new agent bubble.
          _streamingIndex = null;
          _streamBuffer.clear();
          _notify();
        },
        isCancelled: () => _disposed || generation != _responseGeneration,
      );
    } catch (_) {
      // Responders are contractually non-throwing; guard just in case.
      if (generation == _responseGeneration) {
        appendAgentMessage('The agent failed to respond.');
      }
    } finally {
      _responding = false;
      _streamingIndex = null;
      if (generation == _responseGeneration) {
        await _persist();
      }
      if (!_responding) _replyFuture = null;
      _notify();
    }
  }

  /// Appends an agent message and persists the history.
  ///
  /// Exposed now so later plans (LLM integration) can drive the same UI.
  Future<void> appendAgentMessage(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Future.value();
    _messages = [
      ..._messages,
      ChatMessage.create(role: ChatRole.agent, text: trimmed),
    ];
    _notify();
    return _persist();
  }

  /// Clears the current conversation and deletes its history file.
  ///
  /// Any in-flight agent reply is discarded.
  Future<void> reset() {
    _invalidateReply();
    _messages = const [];
    _loading = false;
    _notify();
    return _chain(() => _store.clear(documentIdFor(_document), _session));
  }

  /// Bumped on every load so a slow load cannot clobber a newer one.
  int _loadGeneration = 0;

  /// Reloads the history when the open document changes.
  void _onDocumentChanged() {
    final documentId = documentIdFor(_document);
    if (documentId == _currentDocumentId) return;
    _currentDocumentId = documentId;
    _invalidateReply();
    _load(documentId);
  }

  /// Drops any in-flight agent reply so it cannot write into the
  /// (about to be) new conversation.
  void _invalidateReply() {
    _responseGeneration++;
    _responding = false;
    _streamingIndex = null;
    _streamBuffer.clear();
  }

  void _load(String documentId) {
    _loading = true;
    _messages = const [];
    _notify();
    final generation = ++_loadGeneration;
    _chain(() async {
      final loaded = await _store.load(documentId, _session);
      if (generation != _loadGeneration) return; // superseded by a newer load
      if (_messages.isEmpty) {
        _messages = loaded;
      } else {
        // A message was added while the load was in flight; keep the loaded
        // history ahead of it so neither is lost.
        _messages = [...loaded, ..._messages];
      }
      _loading = false;
    });
  }

  Future<void> _persist() =>
      _chain(() => _store.save(documentIdFor(_document), _session, _messages));

  /// Runs [op] on the I/O chain, swallowing failures so a bad disk write
  /// never breaks the in-memory chat, and notifies on completion.
  Future<void> _chain(Future<void> Function() op) {
    _pending = _pending.then((_) async {
      try {
        await op();
      } catch (_) {
        // Persistence is best-effort; keep the in-memory chat usable.
      }
      _notify();
    });
    return _pending;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
