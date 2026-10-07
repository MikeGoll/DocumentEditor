import 'dart:convert';
import 'dart:io';

import 'package:document_editor/src/chat/chat_history_store.dart';
import 'package:document_editor/src/chat/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late ChatHistoryStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chat_store_test');
    store = ChatHistoryStore(baseDirectory: tempDir.path);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  ChatMessage message(String text, {ChatRole role = ChatRole.user}) =>
      ChatMessage.create(role: role, text: text);

  test('load returns empty list when no file exists', () async {
    expect(await store.load('doc', 'default'), isEmpty);
  });

  test('save then load round-trips messages', () async {
    final messages = [
      message('Hello'),
      message('Hi there', role: ChatRole.agent),
      message('Third message'),
    ];

    await store.save('doc', 'default', messages);
    final loaded = await store.load('doc', 'default');

    expect(loaded, hasLength(3));
    expect(loaded.map((m) => m.text).toList(),
        ['Hello', 'Hi there', 'Third message']);
    expect(loaded.map((m) => m.role).toList(),
        [ChatRole.user, ChatRole.agent, ChatRole.user]);
    // Timestamps and ids survive the round trip.
    expect(loaded[0].timestamp, messages[0].timestamp);
    expect(loaded.map((m) => m.id).toSet(),
        messages.map((m) => m.id).toSet());
  });

  test('history file is named {documentId}_{session}.json', () async {
    await store.save('my-doc', 's1', [message('x')]);

    final file = File('${tempDir.path}/my-doc_s1.json');
    expect(await file.exists(), isTrue);

    // Payload carries document/session metadata and a message list.
    final json = jsonDecode(await file.readAsString())
        as Map<String, dynamic>;
    expect(json['documentId'], 'my-doc');
    expect(json['session'], 's1');
    expect(json['messages'], isA<List<dynamic>>().having(
          (m) => m.length,
          'length',
          1,
        ));
  });

  test('histories for different documents do not mix', () async {
    await store.save('a', 'default', [message('from a')]);
    await store.save('b', 'default', [message('from b')]);

    expect((await store.load('a', 'default')).map((m) => m.text), ['from a']);
    expect((await store.load('b', 'default')).map((m) => m.text), ['from b']);
  });

  test('clear deletes the history file', () async {
    await store.save('doc', 'default', [message('x')]);
    final file = File(store.fileFor('doc', 'default'));
    expect(await file.exists(), isTrue);

    await store.clear('doc', 'default');

    expect(await file.exists(), isFalse);
    expect(await store.load('doc', 'default'), isEmpty);
  });

  test('clear is a no-op when no file exists', () async {
    await expectLater(store.clear('doc', 'default'), completes);
  });

  test('load returns empty list for corrupt file', () async {
    final file = File(store.fileFor('doc', 'default'));
    await store.save('doc', 'default', [message('x')]);
    await file.writeAsString('this is not json{');

    expect(await store.load('doc', 'default'), isEmpty);
  });
}
