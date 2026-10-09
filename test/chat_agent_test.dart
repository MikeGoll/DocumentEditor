import 'dart:io';

import 'package:document_editor/src/chat/chat_controller.dart';
import 'package:document_editor/src/chat/chat_history_store.dart';
import 'package:document_editor/src/chat/chat_message.dart';
import 'package:document_editor/src/documents/document_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake agent responder that streams [chunks] (or reports [error]) with a
/// small delay so the in-flight state is observable.
class _FakeAgent {
  _FakeAgent(this.chunks, {this.then, this.error});

  /// Chunks for the first call; [then] (when given) for later calls.
  final List<String> chunks;
  final List<String>? then;
  final String? error;

  List<ChatMessage>? capturedHistory;
  int _calls = 0;

  Future<void> respond({
    required List<ChatMessage> history,
    required void Function(String chunk) onChunk,
    required void Function(String error) onError,
    void Function(String summary)? onToolActivity,
    bool Function()? isCancelled,
  }) async {
    capturedHistory = history;
    final failure = error;
    if (failure != null) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      onError(failure);
      return;
    }
    final active = _calls == 0 ? chunks : (then ?? chunks);
    _calls++;
    for (final chunk in active) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      onChunk(chunk);
    }
  }
}

void main() {
  late Directory tempDir;
  late DocumentState document;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chat_agent_test');
    document = DocumentState();
  });

  tearDown(() async {
    document.dispose();
    await tempDir.delete(recursive: true);
  });

  ChatController createChat(AgentResponder agent) =>
      ChatController(
        document: document,
        store: ChatHistoryStore(baseDirectory: tempDir.path),
        agent: agent,
      );

  test('streams an agent reply into the conversation and persists it',
      () async {
    final agent = _FakeAgent(const ['Hello', ' from the agent']);
    final chat = createChat(agent.respond);
    addTearDown(chat.dispose);
    await chat.whenIdle; // Let the initial (empty) history load finish.

    await chat.send('Hi');
    await chat.whenReplyDone;
    await chat.whenIdle;

    final messages = chat.messages;
    expect(messages, hasLength(2));
    expect(messages.first.role, ChatRole.user);
    expect(messages.first.text, 'Hi');
    expect(messages.last.role, ChatRole.agent);
    expect(messages.last.text, 'Hello from the agent');

    // The history handed to the agent includes the user's message.
    expect(
      agent.capturedHistory!.map((m) => m.text),
      ['Hi'],
    );

    // The reply is persisted and survives a reload.
    final reloaded = await ChatHistoryStore(baseDirectory: tempDir.path)
        .load(ChatController.documentIdFor(document),
            ChatHistoryStore.defaultSession);
    expect(reloaded.map((m) => m.text), ['Hi', 'Hello from the agent']);
  });

  test('exposes isResponding while the reply is in flight', () async {
    final agent = _FakeAgent(const ['a', 'b', 'c']);
    final chat = createChat(agent.respond);
    addTearDown(chat.dispose);
    await chat.whenIdle; // Let the initial (empty) history load finish.

    final done = chat.send('Hi');
    expect(chat.isResponding, isTrue);

    await done;
    await chat.whenReplyDone;
    await chat.whenIdle;
    expect(chat.isResponding, isFalse);
  });

  test('appends a user-facing error message when the agent fails', () async {
    final agent = _FakeAgent(const [], error: 'Could not reach OpenAI: down');
    final chat = createChat(agent.respond);
    addTearDown(chat.dispose);
    await chat.whenIdle; // Let the initial (empty) history load finish.

    await chat.send('Hi');
    await chat.whenReplyDone;
    await chat.whenIdle;

    final messages = chat.messages;
    expect(messages, hasLength(2));
    expect(messages.last.role, ChatRole.agent);
    expect(messages.last.text, 'Could not reach OpenAI: down');
  });

  test('supports consecutive exchanges', () async {
    final agent = _FakeAgent(const ['one'], then: ['two']);
    final chat = createChat(agent.respond);
    addTearDown(chat.dispose);
    await chat.whenIdle; // Let the initial (empty) history load finish.

    await chat.send('First');
    await chat.whenReplyDone;
    await chat.whenIdle;
    await chat.send('Second');
    await chat.whenReplyDone;
    await chat.whenIdle;

    expect(
      chat.messages.map((m) => m.text),
      ['First', 'one', 'Second', 'two'],
    );
    // The second reply was asked with the full conversation so far.
    expect(
      agent.capturedHistory!.map((m) => m.text),
      ['First', 'one', 'Second'],
    );
  });

  test('discards an in-flight reply when the chat is reset', () async {
    final agent = _SlowAgent();
    final chat = createChat(agent.respond);
    addTearDown(chat.dispose);
    await chat.whenIdle; // Let the initial (empty) history load finish.

    final done = chat.send('Hi');
    expect(chat.isResponding, isTrue);

    await chat.reset();
    await done;
    await chat.whenIdle;

    expect(chat.messages, isEmpty);
    expect(chat.isResponding, isFalse);
  });

  test('sending without an agent only stores the user message', () async {
    final chat = ChatController(
      document: document,
      store: ChatHistoryStore(baseDirectory: tempDir.path),
    );
    addTearDown(chat.dispose);
    await chat.whenIdle; // Let the initial (empty) history load finish.

    await chat.send('Hi');
    await chat.whenIdle;

    expect(chat.messages.map((m) => m.role), [ChatRole.user]);
    expect(chat.isResponding, isFalse);
  });
}

/// Streams one chunk, waits, then streams another — slow enough that a
/// reset lands between chunks.
class _SlowAgent {
  Future<void> respond({
    required List<ChatMessage> history,
    required void Function(String chunk) onChunk,
    required void Function(String error) onError,
    void Function(String summary)? onToolActivity,
    bool Function()? isCancelled,
  }) async {
    onChunk('partial');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    onChunk(' more');
  }
}
