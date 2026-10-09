import 'dart:io';

import 'package:document_editor/src/chat/chat_controller.dart';
import 'package:document_editor/src/chat/chat_history_store.dart';
import 'package:document_editor/src/chat/chat_message.dart';
import 'package:document_editor/src/config/agent_config_controller.dart';
import 'package:document_editor/src/config/config_store.dart';
import 'package:document_editor/src/config/credential_store.dart';
import 'package:document_editor/src/config/llm_provider.dart';
import 'package:document_editor/src/documents/document_state.dart';
import 'package:document_editor/src/llm/agent_service.dart';
import 'package:document_editor/src/llm/llm_client.dart';
import 'package:document_editor/src/tools/document_tools.dart';
import 'package:document_editor/src/tools/supporting_files.dart';
import 'package:document_editor/src/tools/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Plays back one scripted list of events per model turn and records each
/// request it receives.
class _ScriptedClient extends LlmClient {
  _ScriptedClient(this.turns, {this.beforeTurn});

  final List<List<LlmEvent>> turns;

  /// Hook run at the start of each turn (e.g. to simulate user typing
  /// while the model is "thinking").
  final void Function(int turn)? beforeTurn;

  final List<List<LlmMessage>> requests = [];
  final List<String> systemPrompts = [];
  final List<List<LlmTool>> offeredTools = [];

  @override
  String get label => 'Scripted';

  @override
  Stream<LlmEvent> streamTurn({
    required String systemPrompt,
    required List<LlmMessage> messages,
    List<LlmTool> tools = const [],
  }) async* {
    final turn = requests.length;
    requests.add(List.of(messages));
    systemPrompts.add(systemPrompt);
    offeredTools.add(tools);
    beforeTurn?.call(turn);
    final events = turn < turns.length ? turns[turn] : turns.last;
    for (final event in events) {
      await Future<void>.delayed(Duration.zero);
      yield event;
    }
  }
}

LlmToolCallEvent toolCall(String id, String name, Map<String, dynamic> args) =>
    LlmToolCallEvent(LlmToolCall(id: id, name: name, arguments: args));

void main() {
  late Directory tempDir;
  late AgentConfigController config;
  late DocumentState document;
  late SupportingFiles files;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agent_tool_loop_test');
    config = AgentConfigController(
      store: ConfigStore(
        baseDirectory: tempDir.path,
        credentials: InMemoryCredentialStore(),
      ),
    );
    await config.whenIdle;
    final id = config.newProviderId();
    await config.addProvider(
      LlmProvider(id: id, name: 'Test', type: ProviderType.openai, model: 'm'),
      apiKey: 'sk-test',
    );
    await config.whenIdle;
    document = DocumentState();
    files = SupportingFiles();
  });

  tearDown(() async {
    document.dispose();
    files.dispose();
    config.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<void> openDocument(String content) async {
    final file = File('${tempDir.path}/doc.txt')..writeAsStringSync(content);
    await document.openFile(file.path);
  }

  AgentService serviceFor(LlmClient client, {int maxToolRounds = 10}) =>
      AgentService(
        config: config,
        document: document,
        supportingFiles: files,
        maxToolRounds: maxToolRounds,
        clientFactory: ({required LlmProvider provider, required String? apiKey}) =>
            client,
        tools: ToolRegistry([
          ReadDocumentTool(document),
          WriteDocumentTool(document),
          ReadSupportingFileTool(files),
        ]),
      );

  final question = [ChatMessage.create(role: ChatRole.user, text: 'Fix it')];

  test('runs tool calls, feeds results back, and finishes with text',
      () async {
    await openDocument('The colour is red.\n');
    final client = _ScriptedClient([
      [
        const LlmTextEvent('Fixing. '),
        toolCall('c1', 'write_document', {
          'edits': [
            {'old_text': 'colour', 'new_text': 'color'},
          ],
        }),
      ],
      [const LlmTextEvent('Done.')],
    ]);

    final chunks = <String>[];
    final activity = <String>[];
    final errors = <String>[];
    await serviceFor(client).respond(
      history: question,
      onChunk: chunks.add,
      onError: errors.add,
      onToolActivity: activity.add,
    );

    expect(errors, isEmpty);
    expect(chunks, ['Fixing. ', 'Done.']);
    expect(activity, ['Edited the document']);
    expect(document.quill.document.toPlainText(), 'The color is red.\n');

    // The tools were offered, with the guidance in the system prompt.
    expect(client.offeredTools.first.map((t) => t.name),
        ['read_document', 'write_document', 'read_supporting_file']);
    expect(client.systemPrompts.first, contains('write_document'));
    expect(client.systemPrompts.first, contains('no access to the file system'));

    // Second request carries the assistant's tool call and its result.
    final second = client.requests[1];
    expect(second, hasLength(3));
    expect(second[1].role, LlmRole.assistant);
    expect(second[1].text, 'Fixing. ');
    expect(second[1].toolCalls.single.id, 'c1');
    expect(second[2].role, LlmRole.user);
    final result = second[2].toolResults.single;
    expect(result.callId, 'c1');
    expect(result.isError, isFalse);
    // The refreshed system prompt shows the edited document.
    expect(client.systemPrompts[1], contains('The color is red.'));
  });

  test('user edits during processing are preserved and edits still land',
      () async {
    await openDocument('Intro.\nTarget.\n');
    final client = _ScriptedClient(
      [
        [toolCall('r', 'read_document', const {})],
        [
          toolCall('w', 'write_document', {
            'edits': [
              {'old_text': 'Target.', 'new_text': 'Agent text.'},
            ],
          }),
        ],
        [const LlmTextEvent('Done.')],
      ],
      beforeTurn: (turn) {
        // While the model works on the write, the user rewrites the intro.
        if (turn == 1) {
          document.quill.document.replace(0, 6, 'Rewritten intro.');
        }
      },
    );

    final errors = <String>[];
    await serviceFor(client).respond(
      history: question,
      onChunk: (_) {},
      onError: errors.add,
    );

    expect(errors, isEmpty);
    expect(document.quill.document.toPlainText(),
        'Rewritten intro.\nAgent text.\n');
  });

  test('a failed edit is reported to the model so it can recover', () async {
    await openDocument('Hello\n');
    final client = _ScriptedClient([
      [
        toolCall('w1', 'write_document', {
          'edits': [
            {'old_text': 'Goodbye', 'new_text': 'x'},
          ],
        }),
      ],
      [
        toolCall('w2', 'write_document', {
          'edits': [
            {'old_text': 'Hello', 'new_text': 'Hi'},
          ],
        }),
      ],
      [const LlmTextEvent('Fixed.')],
    ]);

    final activity = <String>[];
    await serviceFor(client).respond(
      history: question,
      onChunk: (_) {},
      onError: (_) {},
      onToolActivity: activity.add,
    );

    expect(client.requests[1].last.toolResults.single.isError, isTrue);
    expect(activity, ['Document edit failed', 'Edited the document']);
    expect(document.quill.document.toPlainText(), 'Hi\n');
  });

  test('lists attached supporting files and reads them on request', () async {
    final notes = File('${tempDir.path}/notes.md')
      ..writeAsStringSync('# Notes\nBudget is 42.');
    files.addAll([notes.path]);
    final client = _ScriptedClient([
      [toolCall('s', 'read_supporting_file', const {'name': 'notes.md'})],
      [const LlmTextEvent('The budget is 42.')],
    ]);

    await serviceFor(client).respond(
      history: question,
      onChunk: (_) {},
      onError: (_) {},
    );

    expect(client.systemPrompts.first, contains('## Supporting files'));
    expect(client.systemPrompts.first, contains('- notes.md'));
    final result = client.requests[1].last.toolResults.single;
    expect(result.content, contains('Budget is 42.'));
  });

  test('stops after the maximum number of tool rounds', () async {
    await openDocument('x\n');
    final client = _ScriptedClient([
      [toolCall('r', 'read_document', const {})],
    ]);

    final errors = <String>[];
    await serviceFor(client, maxToolRounds: 3).respond(
      history: question,
      onChunk: (_) {},
      onError: errors.add,
    );

    expect(client.requests, hasLength(3));
    expect(errors.single, contains('stopped after 3 rounds'));
  });

  test('runs no tools once cancelled', () async {
    await openDocument('Hello\n');
    var cancelled = false;
    final client = _ScriptedClient([
      [
        const LlmTextEvent('Working'),
        toolCall('w', 'write_document', {
          'edits': [
            {'old_text': 'Hello', 'new_text': 'Bye'},
          ],
        }),
      ],
    ]);

    final errors = <String>[];
    await serviceFor(client).respond(
      history: question,
      onChunk: (_) => cancelled = true,
      onError: errors.add,
      isCancelled: () => cancelled,
    );

    expect(document.quill.document.toPlainText(), 'Hello\n');
    expect(errors, isEmpty);
  });

  test('tool activity is not sent back to the model as chat history',
      () async {
    final client = _ScriptedClient([
      [const LlmTextEvent('ok')],
    ]);

    await serviceFor(client).respond(
      history: [
        ChatMessage.create(role: ChatRole.user, text: 'Edit please'),
        ChatMessage.create(role: ChatRole.tool, text: 'Edited the document'),
        ChatMessage.create(role: ChatRole.agent, text: 'Done'),
        ChatMessage.create(role: ChatRole.user, text: 'Thanks'),
      ],
      onChunk: (_) {},
      onError: (_) {},
    );

    expect(client.requests.single.map((m) => m.text),
        ['Edit please', 'Done', 'Thanks']);
  });

  group('ChatController', () {
    test('shows tool activity between separate agent messages', () async {
      await openDocument('Draft\n');
      final client = _ScriptedClient([
        [
          const LlmTextEvent('Let me edit.'),
          toolCall('w', 'write_document', {
            'edits': [
              {'old_text': 'Draft', 'new_text': 'Final'},
            ],
          }),
        ],
        [const LlmTextEvent('Updated the draft.')],
      ]);
      final chat = ChatController(
        document: document,
        store: ChatHistoryStore(baseDirectory: tempDir.path),
        agent: serviceFor(client).respond,
      );
      addTearDown(chat.dispose);
      await chat.whenIdle;

      await chat.send('Finalize');
      await chat.whenReplyDone;
      await chat.whenIdle;

      expect(
        chat.messages.map((m) => (m.role, m.text)),
        [
          (ChatRole.user, 'Finalize'),
          (ChatRole.agent, 'Let me edit.'),
          (ChatRole.tool, 'Edited the document'),
          (ChatRole.agent, 'Updated the draft.'),
        ],
      );
      expect(document.quill.document.toPlainText(), 'Final\n');

      // Tool entries persist with the rest of the conversation.
      final reloaded = await ChatHistoryStore(baseDirectory: tempDir.path)
          .load(ChatController.documentIdFor(document),
              ChatHistoryStore.defaultSession);
      expect(reloaded.map((m) => m.role),
          [ChatRole.user, ChatRole.agent, ChatRole.tool, ChatRole.agent]);
    });

    test('resetting the chat stops a pending edit', () async {
      await openDocument('Keep me\n');
      late ChatController chat;
      final client = _ScriptedClient(
        [
          [toolCall('r', 'read_document', const {})],
          [
            toolCall('w', 'write_document', {
              'edits': [
                {'old_text': 'Keep me', 'new_text': 'Changed'},
              ],
            }),
          ],
        ],
        beforeTurn: (turn) {
          if (turn == 1) chat.reset();
        },
      );
      chat = ChatController(
        document: document,
        store: ChatHistoryStore(baseDirectory: tempDir.path),
        agent: serviceFor(client).respond,
      );
      addTearDown(chat.dispose);
      await chat.whenIdle;

      await chat.send('Change it');
      await chat.whenReplyDone;
      await chat.whenIdle;

      expect(document.quill.document.toPlainText(), 'Keep me\n');
      expect(chat.messages, isEmpty);
    });
  });
}
