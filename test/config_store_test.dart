import 'dart:convert';
import 'dart:io';

import 'package:document_editor/src/config/agent_config.dart';
import 'package:document_editor/src/config/config_store.dart';
import 'package:document_editor/src/config/credential_store.dart';
import 'package:document_editor/src/config/llm_provider.dart';
import 'package:document_editor/src/config/translation_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late InMemoryCredentialStore credentials;
  late ConfigStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('config_store_test');
    credentials = InMemoryCredentialStore();
    store = ConfigStore(
        baseDirectory: tempDir.path, credentials: credentials);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('load returns empty config when no file exists', () async {
    final config = await store.load();

    expect(config.providers, isEmpty);
    expect(config.isUsingDefaultPrompt, isTrue);
  });

  test('load returns empty config for a corrupt file', () async {
    await File(store.filePath).writeAsString('not json {');

    expect((await store.load()).providers, isEmpty);
  });

  test('save then load round-trips the full configuration', () async {
    await store.save(
      AgentConfig(
        providers: [
          LlmProvider(
            id: 'p1',
            name: 'Local',
            type: ProviderType.localOpenAi,
            endpoint: 'http://localhost:11434/v1',
          ),
          LlmProvider(id: 'p2', name: 'OpenAI', type: ProviderType.openai),
        ],
        activeProviderId: 'p2',
        translationTable: {
          'colour': const TranslationEntry(
              original: 'colour', correction: 'color'),
        },
        systemPrompt: 'Custom prompt.',
      ),
      apiKeys: {'p2': 'sk-test-123'},
    );

    final loaded = await store.load();
    expect(loaded.providers, hasLength(2));
    expect(loaded.activeProviderId, 'p2');
    expect(loaded.translationTable['colour']?.correction, 'color');
    expect(loaded.systemPrompt, 'Custom prompt.');
    expect(await store.readApiKey('p2'), 'sk-test-123');
    expect(await store.apiKeyProviderIds(), {'p2'});
  });

  test('API keys are stored in the credential store, not the JSON file',
      () async {
    await store.save(
      AgentConfig(
        providers: [
          LlmProvider(id: 'p1', name: 'OpenAI', type: ProviderType.openai),
        ],
      ),
      apiKeys: {'p1': 'sk-super-secret'},
    );

    final fileContent = await File(store.filePath).readAsString();
    expect(fileContent, isNot(contains('sk-super-secret')));
    expect(await credentials.read(ConfigStore.credentialKeyFor('p1')),
        'sk-super-secret');
  });

  test('saving with a null key deletes the stored key', () async {
    await store.save(
      AgentConfig(
        providers: [
          LlmProvider(id: 'p1', name: 'OpenAI', type: ProviderType.openai),
        ],
      ),
      apiKeys: {'p1': 'sk-1'},
    );
    await store.save(
      AgentConfig(
        providers: [
          LlmProvider(id: 'p1', name: 'OpenAI', type: ProviderType.openai),
        ],
      ),
      apiKeys: {'p1': null},
    );

    expect(await store.readApiKey('p1'), isNull);
    expect(await store.apiKeyProviderIds(), isEmpty);
  });

  test('saving without mentioning a key keeps the stored key', () async {
    await store.save(
      AgentConfig(
        providers: [
          LlmProvider(id: 'p1', name: 'OpenAI', type: ProviderType.openai),
        ],
      ),
      apiKeys: {'p1': 'sk-keep'},
    );
    await store.save(
      AgentConfig(
        providers: [
          LlmProvider(id: 'p1', name: 'OpenAI', type: ProviderType.openai),
        ],
      ),
    );

    expect(await store.readApiKey('p1'), 'sk-keep');
  });

  test('config file is valid JSON with the expected top-level shape',
      () async {
    await store.save(AgentConfig());
    final json =
        jsonDecode(await File(store.filePath).readAsString())
            as Map<String, dynamic>;

    expect(json['providers'], isEmpty);
    expect(json['translationTable'], isEmpty);
    expect(json.containsKey('systemPrompt'), isFalse);
  });
}
