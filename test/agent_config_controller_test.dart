import 'dart:io';

import 'package:document_editor/src/config/agent_config_controller.dart';
import 'package:document_editor/src/config/config_store.dart';
import 'package:document_editor/src/config/credential_store.dart';
import 'package:document_editor/src/config/llm_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late InMemoryCredentialStore credentials;
  late ConfigStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('config_controller_test');
    credentials = InMemoryCredentialStore();
    store = ConfigStore(
        baseDirectory: tempDir.path, credentials: credentials);
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  LlmProvider provider(String id, {String name = 'Provider'}) =>
      LlmProvider(id: id, name: name, type: ProviderType.openai);

  AgentConfigController controller() {
    final c = AgentConfigController(store: store);
    addTearDown(c.dispose);
    return c;
  }

  test('first added provider becomes active; later ones do not', () async {
    final c = controller();
    await c.whenIdle;
    await c.addProvider(provider('p1'));
    await c.addProvider(provider('p2'));
    await c.whenIdle;

    expect(c.config.activeProviderId, 'p1');
    expect(c.config.providers.map((p) => p.id), ['p1', 'p2']);
  });

  test('setActiveProvider switches and rejects unknown ids', () async {
    final c = controller();
    await c.whenIdle;
    await c.addProvider(provider('p1'));
    await c.addProvider(provider('p2'));
    await c.setActiveProvider('p2');
    await c.setActiveProvider('nope');
    await c.whenIdle;

    expect(c.config.activeProviderId, 'p2');
  });

  test('removing the active provider activates the first remaining one',
      () async {
    final c = controller();
    await c.whenIdle;
    await c.addProvider(provider('p1'));
    await c.addProvider(provider('p2'));
    await c.setActiveProvider('p1');
    await c.removeProvider('p1');
    await c.whenIdle;

    expect(c.config.providers.map((p) => p.id), ['p2']);
    expect(c.config.activeProviderId, 'p2');
  });

  test('removing the last provider clears the active one', () async {
    final c = controller();
    await c.whenIdle;
    await c.addProvider(provider('p1'));
    await c.removeProvider('p1');
    await c.whenIdle;

    expect(c.config.providers, isEmpty);
    expect(c.config.activeProviderId, isNull);
  });

  test('removing a provider deletes its stored API key', () async {
    final c = controller();
    await c.whenIdle;
    await c.addProvider(provider('p1'), apiKey: 'sk-1');
    await c.removeProvider('p1');
    await c.whenIdle;

    expect(await store.readApiKey('p1'), isNull);
  });

  test('updating a provider without a key keeps the stored key', () async {
    final c = controller();
    await c.whenIdle;
    await c.addProvider(provider('p1'), apiKey: 'sk-keep');
    await c.updateProvider(provider('p1', name: 'Renamed'));
    await c.whenIdle;

    expect(c.config.providers.single.name, 'Renamed');
    expect(await store.readApiKey('p1'), 'sk-keep');
  });

  test('setApiKey stores and clears keys', () async {
    final c = controller();
    await c.whenIdle;
    await c.addProvider(provider('p1'));
    await c.setApiKey('p1', 'sk-1');
    await c.whenIdle;
    expect(c.hasApiKey('p1'), isTrue);

    await c.setApiKey('p1', null);
    await c.whenIdle;
    expect(c.hasApiKey('p1'), isFalse);
  });

  test('translation entries can be added, updated, and removed', () async {
    final c = controller();
    await c.whenIdle;
    await c.setTranslationEntry('colour', 'color');
    await c.setTranslationEntry('colour', 'color (US)');
    await c.setTranslationEntry('grey', 'gray');
    await c.removeTranslationEntry('grey');
    await c.whenIdle;

    final table = c.config.translationTable;
    expect(table, hasLength(1));
    expect(table['colour']?.correction, 'color (US)');
  });

  test('system prompt can be customized, blanked, and reset', () async {
    final c = controller();
    await c.whenIdle;
    expect(c.config.isUsingDefaultPrompt, isTrue);

    await c.setSystemPrompt('Be terse.');
    expect(c.config.effectiveSystemPrompt, 'Be terse.');

    await c.setSystemPrompt('   ');
    expect(c.config.isUsingDefaultPrompt, isTrue);

    await c.setSystemPrompt('Custom again.');
    await c.resetSystemPrompt();
    await c.whenIdle;
    expect(c.config.isUsingDefaultPrompt, isTrue);
  });

  test('configuration persists across controller instances', () async {
    final c1 = controller();
    await c1.whenIdle;
    await c1.addProvider(provider('p1'), apiKey: 'sk-1');
    await c1.setTranslationEntry('colour', 'color');
    await c1.setSystemPrompt('Custom.');
    await c1.whenIdle;

    final c2 = controller();
    await c2.whenIdle;

    expect(c2.config.providers.map((p) => p.id), ['p1']);
    expect(c2.config.activeProviderId, 'p1');
    expect(c2.hasApiKey('p1'), isTrue);
    expect(c2.config.translationTable['colour']?.correction, 'color');
    expect(c2.config.systemPrompt, 'Custom.');
  });
}
