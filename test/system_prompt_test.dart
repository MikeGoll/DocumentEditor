import 'package:document_editor/src/config/agent_config.dart';
import 'package:document_editor/src/config/translation_entry.dart';
import 'package:document_editor/src/llm/system_prompt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildAgentSystemPrompt', () {
    test('includes the default system prompt when none is configured', () {
      final prompt = buildAgentSystemPrompt(config: AgentConfig());

      expect(prompt, contains(AgentConfig.defaultSystemPrompt));
      expect(prompt, contains('no access to the file system'));
    });

    test('includes a custom system prompt instead of the default', () {
      final config = AgentConfig(systemPrompt: 'Be brief and formal.');
      final prompt = buildAgentSystemPrompt(config: config);

      expect(prompt, contains('Be brief and formal.'));
      expect(prompt, isNot(contains(AgentConfig.defaultSystemPrompt)));
    });

    test('includes the document name and content', () {
      final prompt = buildAgentSystemPrompt(
        config: AgentConfig(),
        documentName: 'notes.txt',
        documentContent: 'The sky is blue.',
      );

      expect(prompt, contains('## Document: notes.txt'));
      expect(prompt, contains('The sky is blue.'));
    });

    test('reports when no document is open', () {
      final prompt = buildAgentSystemPrompt(config: AgentConfig());

      expect(prompt, contains('No document is currently open.'));
    });

    test('reports an empty open document', () {
      final prompt = buildAgentSystemPrompt(
        config: AgentConfig(),
        documentName: 'empty.txt',
        documentContent: '   ',
      );

      expect(prompt, contains('The open document "empty.txt" is empty.'));
    });

    test('includes open comments', () {
      final prompt = buildAgentSystemPrompt(
        config: AgentConfig(),
        documentContent: 'Body text.',
        comments: ['Make the intro shorter', '  '],
      );

      expect(prompt, contains('## Comments on the document'));
      expect(prompt, contains('- Make the intro shorter'));
      // Blank comments are filtered out: exactly one bullet is rendered.
      expect(RegExp(r'^- ', multiLine: true).allMatches(prompt).length, 1);
    });

    test('omits the comments section when there are no comments', () {
      final prompt = buildAgentSystemPrompt(config: AgentConfig());

      expect(prompt, isNot(contains('## Comments')));
    });

    test('injects the translation table', () {
      final config = AgentConfig(
        translationTable: {
          'utilize':
              const TranslationEntry(original: 'utilize', correction: 'use'),
          'leverage':
              const TranslationEntry(original: 'leverage', correction: 'use'),
        },
      );
      final prompt = buildAgentSystemPrompt(config: config);

      expect(prompt, contains('## Translation table'));
      expect(prompt, contains('- "utilize" → "use"'));
      expect(prompt, contains('- "leverage" → "use"'));
    });

    test('omits the translation table when it is empty', () {
      final prompt = buildAgentSystemPrompt(config: AgentConfig());

      expect(prompt, isNot(contains('## Translation table')));
    });

    test('truncates long documents and marks the cut', () {
      final longContent = List.generate(500, (i) => 'Line $i.').join('\n');
      final prompt = buildAgentSystemPrompt(
        config: AgentConfig(),
        documentContent: longContent,
        maxDocumentChars: 1000,
      );

      expect(prompt, contains('[... document truncated ...]'));
      expect(prompt, isNot(contains('Line 499')));
      // The cut lands on a line boundary: the last included line is whole.
      expect(prompt, contains('Line 100.'));
      expect(prompt, isNot(contains('Line 111')));
    });

    test('leaves short documents untouched', () {
      final prompt = buildAgentSystemPrompt(
        config: AgentConfig(),
        documentContent: 'Short.',
        maxDocumentChars: 100,
      );

      expect(prompt, contains('Short.'));
      expect(prompt, isNot(contains('truncated')));
    });
  });
}
