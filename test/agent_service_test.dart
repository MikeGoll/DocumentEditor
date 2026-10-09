import 'dart:io';

import 'package:document_editor/src/chat/chat_message.dart';
import 'package:document_editor/src/config/agent_config.dart';
import 'package:document_editor/src/config/agent_config_controller.dart';
import 'package:document_editor/src/config/config_store.dart';
import 'package:document_editor/src/config/credential_store.dart';
import 'package:document_editor/src/config/llm_provider.dart';
import 'package:document_editor/src/documents/document_state.dart';
import 'package:document_editor/src/llm/agent_service.dart';
import 'package:document_editor/src/llm/llm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the request and replays canned chunks (or an error).
class _FakeLlmClient extends LlmClient {
  _FakeLlmClient(this.chunks, {this.error});

  final List<String> chunks;
  final LlmException? error;

  @override
  String get label => 'Fake';

  String? capturedSystemPrompt;
  List<LlmMessage>? capturedMessages;
  String? capturedApiKey;

  @override
  Stream<String> streamCompletion({
    required String systemPrompt,
    required List<LlmMessage> messages,
  }) async* {
    capturedSystemPrompt = systemPrompt;
    capturedMessages = messages;
    final failure = error;
    if (failure != null) throw failure;
    for (final chunk in chunks) {
      await Future<void>.delayed(Duration.zero);
      yield chunk;
    }
  }
}

void main() {
  late Directory tempDir;
  late InMemoryCredentialStore credentials;
  late AgentConfigController config;
  late DocumentState document;
  late _FakeLlmClient client;
  late AgentService service;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agent_service_test');
    credentials = InMemoryCredentialStore();
    config = AgentConfigController(
      store: ConfigStore(baseDirectory: tempDir.path, credentials: credentials),
    );
    await config.whenIdle;
    document = DocumentState();
    client = _FakeLlmClient(const []);
    service = AgentService(
      config: config,
      document: document,
      clientFactory: ({required LlmProvider provider, required String? apiKey}) {
        client.capturedApiKey = apiKey;
        return client;
      },
    );
  });

  tearDown(() async {
    document.dispose();
    config.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<void> addProvider({
    ProviderType type = ProviderType.openai,
    String model = 'gpt-4o-mini',
    String? apiKey = 'sk-test',
  }) async {
    final id = config.newProviderId();
    await config.addProvider(
      LlmProvider(id: id, name: 'Test', type: type, model: model),
      apiKey: apiKey,
    );
    await config.whenIdle;
  }

  test('streams reply chunks from the active provider', () async {
    await addProvider();
    client = _FakeLlmClient(const ['Hello', ' world']);

    final chunks = <String>[];
    final errors = <String>[];
    await service.respond(
      history: [ChatMessage.create(role: ChatRole.user, text: 'Hi there')],
      onChunk: chunks.add,
      onError: errors.add,
    );

    expect(chunks, ['Hello', ' world']);
    expect(errors, isEmpty);
    expect(client.capturedApiKey, 'sk-test');
    final messages = client.capturedMessages!;
    expect(messages, hasLength(1));
    expect(messages.single.role, LlmRole.user);
    expect(messages.single.text, 'Hi there');
  });

  test('system prompt includes document content and translation table',
      () async {
    await addProvider();
    await config.setTranslationEntry('utilize', 'use');
    await config.whenIdle;
    final file = File('${tempDir.path}/sample.txt')
      ..writeAsStringSync('The sky is blue.');
    await document.openFile(file.path);

    final errors = <String>[];
    await service.respond(
      history: [ChatMessage.create(role: ChatRole.user, text: 'Q')],
      onChunk: (_) {},
      onError: errors.add,
    );

    expect(errors, isEmpty);
    final prompt = client.capturedSystemPrompt!;
    expect(prompt, contains(AgentConfig.defaultSystemPrompt));
    expect(prompt, contains('## Document: sample.txt'));
    expect(prompt, contains('The sky is blue.'));
    expect(prompt, contains('- "utilize" → "use"'));
  });

  test('system prompt includes comments from the comments provider', () async {
    await addProvider();
    service = AgentService(
      config: config,
      document: document,
      clientFactory: ({required LlmProvider provider, required String? apiKey}) =>
          client,
      commentsProvider: () => const ['Shorten the intro'],
    );

    await service.respond(
      history: [ChatMessage.create(role: ChatRole.user, text: 'Q')],
      onChunk: (_) {},
      onError: (_) {},
    );

    expect(client.capturedSystemPrompt, contains('- Shorten the intro'));
  });

  test('sends only the most recent history messages', () async {
    await addProvider();
    service = AgentService(
      config: config,
      document: document,
      clientFactory: ({required LlmProvider provider, required String? apiKey}) =>
          client,
      maxHistoryMessages: 3,
    );

    final history = [
      for (var i = 0; i < 6; i++)
        ChatMessage.create(
          role: i.isEven ? ChatRole.user : ChatRole.agent,
          text: 'Message $i',
        ),
    ];
    await service.respond(
      history: history,
      onChunk: (_) {},
      onError: (_) {},
    );

    expect(
      client.capturedMessages!.map((m) => m.text),
      ['Message 3', 'Message 4', 'Message 5'],
    );
  });

  test('reports a friendly error when no provider is configured', () async {
    final errors = <String>[];
    await service.respond(
      history: [ChatMessage.create(role: ChatRole.user, text: 'Q')],
      onChunk: (_) {},
      onError: errors.add,
    );

    expect(errors, hasLength(1));
    expect(errors.single, contains('No LLM provider is configured'));
  });

  test('reports a friendly error when the API key is missing', () async {
    // Uses the real client factory: the OpenAI client validates the key
    // before touching the network, so this works offline.
    await addProvider(apiKey: null);
    final realService = AgentService(config: config, document: document);

    final errors = <String>[];
    await realService.respond(
      history: [ChatMessage.create(role: ChatRole.user, text: 'Q')],
      onChunk: (_) {},
      onError: errors.add,
    );

    expect(errors, hasLength(1));
    expect(errors.single, contains('No API key is stored'));
  });

  test('reports provider failures as user-facing errors', () async {
    await addProvider();
    client = _FakeLlmClient(const [],
        error: const LlmException(LlmErrorKind.network, 'Could not reach host'));

    final errors = <String>[];
    await service.respond(
      history: [ChatMessage.create(role: ChatRole.user, text: 'Q')],
      onChunk: (_) {},
      onError: errors.add,
    );

    expect(errors, ['Could not reach host']);
  });

  test('never throws on unexpected client failures', () async {
    await addProvider();
    final throwing = _ThrowingClient();
    service = AgentService(
      config: config,
      document: document,
      clientFactory: ({required LlmProvider provider, required String? apiKey}) =>
          throwing,
    );

    final errors = <String>[];
    await service.respond(
      history: [ChatMessage.create(role: ChatRole.user, text: 'Q')],
      onChunk: (_) {},
      onError: errors.add,
    );

    expect(errors, hasLength(1));
    expect(errors.single, contains('Unexpected error'));
  });
}

class _ThrowingClient extends LlmClient {
  @override
  String get label => 'Throwing';

  @override
  Stream<String> streamCompletion({
    required String systemPrompt,
    required List<LlmMessage> messages,
  }) async* {
    throw StateError('boom');
  }
}
