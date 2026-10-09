import 'dart:convert';

import 'package:document_editor/src/config/agent_config.dart';
import 'package:document_editor/src/config/llm_provider.dart';
import 'package:document_editor/src/config/translation_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AgentConfig', () {
    test('empty config uses default system prompt', () {
      final config = AgentConfig();

      expect(config.providers, isEmpty);
      expect(config.activeProvider, isNull);
      expect(config.isUsingDefaultPrompt, isTrue);
      expect(config.effectiveSystemPrompt, AgentConfig.defaultSystemPrompt);
    });

    test('default prompt confines the agent to document content', () {
      final prompt = AgentConfig.defaultSystemPrompt.toLowerCase();

      expect(prompt, contains('author'));
      expect(prompt, contains('document'));
    });

    test('blank custom prompt falls back to the default', () {
      final config = AgentConfig(systemPrompt: '   ');

      expect(config.isUsingDefaultPrompt, isTrue);
      expect(config.effectiveSystemPrompt, AgentConfig.defaultSystemPrompt);
    });

    test('custom prompt is used verbatim (trimmed) when set', () {
      final config = AgentConfig(systemPrompt: '  Be terse.  ');

      expect(config.isUsingDefaultPrompt, isFalse);
      expect(config.effectiveSystemPrompt, 'Be terse.');
    });

    test('activeProvider resolves the active id', () {
      final a = LlmProvider(id: 'a', name: 'A', type: ProviderType.openai);
      final b = LlmProvider(id: 'b', name: 'B', type: ProviderType.anthropic);
      final config = AgentConfig(providers: [a, b], activeProviderId: 'b');

      expect(config.activeProvider, same(b));
    });

    test('activeProvider is null when the id is stale', () {
      final a = LlmProvider(id: 'a', name: 'A', type: ProviderType.openai);
      final config = AgentConfig(
          providers: [a], activeProviderId: 'missing');

      expect(config.activeProvider, isNull);
    });

    test('json round-trip preserves all fields', () {
      final config = AgentConfig(
        providers: [
          LlmProvider(
            id: 'p1',
            name: 'Local',
            type: ProviderType.localOpenAi,
            endpoint: 'http://localhost:11434/v1',
            model: 'llama3',
          ),
          LlmProvider(id: 'p2', name: 'OpenAI', type: ProviderType.openai),
        ],
        activeProviderId: 'p1',
        translationTable: {
          'colour': const TranslationEntry(
              original: 'colour', correction: 'color'),
        },
        systemPrompt: 'Custom prompt.',
      );

      final restored =
          AgentConfig.fromJson(jsonDecode(jsonEncode(config.toJson())));

      expect(restored.providers, hasLength(2));
      expect(restored.providers[0].endpoint, 'http://localhost:11434/v1');
      expect(restored.providers[0].model, 'llama3');
      expect(restored.providers[1].type, ProviderType.openai);
      expect(restored.activeProviderId, 'p1');
      expect(restored.translationTable['colour']?.correction, 'color');
      expect(restored.systemPrompt, 'Custom prompt.');
    });

    test('json round-trip of empty config omits optional fields', () {
      final restored =
          AgentConfig.fromJson(jsonDecode(jsonEncode(AgentConfig().toJson())));

      expect(restored.isUsingDefaultPrompt, isTrue);
      expect(restored.activeProviderId, isNull);
    });

    test('fromJson tolerates missing sections', () {
      final config = AgentConfig.fromJson(const {});

      expect(config.providers, isEmpty);
      expect(config.translationTable, isEmpty);
      expect(config.isUsingDefaultPrompt, isTrue);
    });
  });

  group('LlmProvider validation', () {
    test('local provider requires an endpoint', () {
      final provider =
          LlmProvider(id: 'p', name: 'Local', type: ProviderType.localOpenAi);

      expect(provider.validate(hasApiKey: false), contains('endpoint'));
    });

    test('local provider with endpoint is valid without a key', () {
      final provider = LlmProvider(
          id: 'p',
          name: 'Local',
          type: ProviderType.localOpenAi,
          endpoint: 'http://localhost:11434/v1');

      expect(provider.validate(hasApiKey: false), isEmpty);
    });

    for (final type in [
      ProviderType.anthropic,
      ProviderType.openai,
      ProviderType.google,
    ]) {
      test('$type requires an API key', () {
        final provider = LlmProvider(id: 'p', name: 'P', type: type);

        expect(provider.validate(hasApiKey: false), contains('apiKey'));
        expect(provider.validate(hasApiKey: true), isEmpty);
      });
    }

    test('name is required', () {
      final provider = LlmProvider(
          id: 'p', name: '  ', type: ProviderType.openai);

      expect(provider.validate(hasApiKey: true), contains('name'));
    });

    test('endpoint must be an http(s) URL when provided', () {
      final provider = LlmProvider(
          id: 'p',
          name: 'P',
          type: ProviderType.openai,
          endpoint: 'ftp://example.com');

      expect(provider.validate(hasApiKey: true), contains('endpoint'));
    });

    test('effectiveEndpoint falls back to the type default', () {
      final provider = LlmProvider(id: 'p', name: 'P', type: ProviderType.openai);

      expect(provider.effectiveEndpoint, 'https://api.openai.com/v1');
    });
  });
}
