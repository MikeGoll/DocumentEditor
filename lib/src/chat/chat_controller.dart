import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../documents/document_state.dart';
import 'chat_history_store.dart';
import 'chat_message.dart';

/// In-memory chat state backed by a [ChatHistoryStore].
///
/// The controller follows the open document: each document has its own
/// history file, and switching documents swaps the loaded conversation.
///
/// The UI is deliberately decoupled from any LLM provider — sending a
/// message only appends it to the local history (agent replies arrive with
/// Plan 07). Listeners are notified synchronously when messages change;
/// disk writes happen in the background and never block the UI.
class ChatController extends ChangeNotifier {
  ChatController({
    required DocumentState document,
    required ChatHistoryStore store,
    String session = ChatHistoryStore.defaultSession,
  })  : _document = document,
        _store = store,
        _session = session {
    _currentDocumentId = documentIdFor(_document);
    _document.addListener(_onDocumentChanged);
    _load(_currentDocumentId!);
  }

  final DocumentState _document;
  final ChatHistoryStore _store;
  final String _session;

  List<ChatMessage> _messages = const [];
  bool _loading = true;
  bool _disposed = false;
  String? _currentDocumentId;

  /// Serializes history I/O so quick successive sends cannot write the file
  /// out of order.
  Future<void> _pending = Future.value();

  /// Completes when all in-flight history I/O has finished.
  ///
  /// Useful in tests to deterministically wait for file writes.
  Future<void> get whenIdle => _pending;

  /// Messages in chronological order.
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  /// Whether the initial history load is still in flight.
  bool get isLoading => _loading;

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
  /// Listeners are notified immediately; the file write is best-effort and
  /// does not block the UI. Does nothing when [text] is blank.
  Future<void> send(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Future.value();
    _messages = [
      ..._messages,
      ChatMessage.create(role: ChatRole.user, text: trimmed),
    ];
    _notify();
    return _persist();
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
  Future<void> reset() {
    _messages = const [];
    _loading = false;
    _notify();
    return _chain(() => _store.clear(documentIdFor(_document), _session));
  }

  /// Reloads the history when the open document changes.
  void _onDocumentChanged() {
    final documentId = documentIdFor(_document);
    if (documentId == _currentDocumentId) return;
    _currentDocumentId = documentId;
    _load(documentId);
  }

  void _load(String documentId) {
    _loading = true;
    _messages = const [];
    _notify();
    _chain(() async {
      _messages = await _store.load(documentId, _session);
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
