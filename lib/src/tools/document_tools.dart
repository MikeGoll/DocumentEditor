import '../documents/document_state.dart';
import '../llm/llm_client.dart';
import 'tool_registry.dart';

/// Lets the agent read the live content of the open document.
///
/// Unlike the snapshot in the system prompt, this always reflects the
/// latest state, including edits the user made while the agent was
/// working.
class ReadDocumentTool extends AgentTool {
  ReadDocumentTool(this._document, {this.maxChars = 24000});

  final DocumentState _document;

  /// Characters returned per call; longer documents are paged.
  final int maxChars;

  @override
  LlmTool get definition => const LlmTool(
        name: 'read_document',
        description:
            'Returns the current plain-text content of the open document. '
            'The user may edit the document while you work, so call this '
            'again before editing if your copy may be stale. The character '
            '￼ marks an embedded object (such as a table) that cannot be '
            'edited. Long documents are returned in pages.',
        parameters: {
          'type': 'object',
          'properties': {
            'offset': {
              'type': 'integer',
              'description':
                  'Character offset to start reading from (default 0).',
            },
          },
        },
      );

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> arguments) async {
    if (!_document.hasDocument) {
      return const ToolOutcome.error('No document is open.',
          summary: 'Tried to read the document, but none is open');
    }
    final offset = optionalInt(arguments, 'offset') ?? 0;
    final text = _document.quill.document.toPlainText();
    return ToolOutcome(
      content: pageText(text, offset: offset, maxChars: maxChars),
      summary: 'Read the document',
    );
  }
}

/// Lets the agent edit the open document.
///
/// Edits are applied immediately to the live editor (the user watches them
/// appear) as a single undoable step. See [DocumentState.applyTextEdits]
/// for how concurrent user edits are handled.
class WriteDocumentTool extends AgentTool {
  WriteDocumentTool(this._document);

  final DocumentState _document;

  @override
  LlmTool get definition => const LlmTool(
        name: 'write_document',
        description:
            'Edits the open document. Each edit replaces old_text, which must '
            'match exactly one place in the current document (including '
            'whitespace and line breaks), with new_text. Use an empty old_text '
            'to append new_text to the end of the document. All edits in one '
            'call are applied together as a single undoable change; if any '
            'edit cannot be applied, none are. Text is inserted as plain text '
            'and keeps the formatting of the text it replaces; Markdown or '
            'other markup is not interpreted. The changes appear in the '
            "user's editor immediately but are not saved to disk.",
        parameters: {
          'type': 'object',
          'properties': {
            'edits': {
              'type': 'array',
              'description': 'The replacements to apply.',
              'items': {
                'type': 'object',
                'properties': {
                  'old_text': {
                    'type': 'string',
                    'description':
                        'Exact existing text to replace; include enough '
                        'context to be unique. Empty to append.',
                  },
                  'new_text': {
                    'type': 'string',
                    'description': 'Replacement text (empty to delete).',
                  },
                },
                'required': ['old_text', 'new_text'],
              },
            },
          },
          'required': ['edits'],
        },
      );

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> arguments) async {
    final rawEdits = arguments['edits'];
    if (rawEdits is! List || rawEdits.isEmpty) {
      throw const ToolArgumentException('"edits" must be a non-empty array.');
    }
    final edits = <TextEdit>[];
    for (final raw in rawEdits) {
      if (raw is! Map<String, dynamic>) {
        throw const ToolArgumentException(
            'Each edit must be an object with old_text and new_text.');
      }
      edits.add(TextEdit(
        oldText: requireString(raw, 'old_text'),
        newText: requireString(raw, 'new_text'),
      ));
    }

    try {
      final applied = _document.applyTextEdits(edits);
      if (applied == 0) {
        return const ToolOutcome(
          content: 'No changes: the new text matches the existing text.',
          summary: 'Proposed edits made no changes',
        );
      }
      return ToolOutcome(
        content: 'Applied $applied edit${applied == 1 ? '' : 's'}. The user '
            'can see the changes and undo them.',
        summary: applied == 1
            ? 'Edited the document'
            : 'Edited the document ($applied changes)',
      );
    } on DocumentEditException catch (error) {
      return ToolOutcome.error(
        '${error.message} No edits were applied. Call read_document to get '
        'the current content, then retry.',
        summary: 'Document edit failed',
      );
    }
  }
}
