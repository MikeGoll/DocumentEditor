import '../config/agent_config.dart';
import 'llm_client.dart';

/// Builds the system prompt injected into every agent call.
///
/// The prompt layers, in order:
/// 1. the configured system prompt (custom or the built-in default),
/// 2. the agent's capabilities: either a reminder that it has no file
///    system or tool access, or (when [tools] are offered) how to use them
///    and which [supportingFiles] the user attached,
/// 3. the current document content (truncated to fit the context window),
/// 4. open comments on the document, and
/// 5. the translation table, so the agent uses the user's preferred wording.
String buildAgentSystemPrompt({
  required AgentConfig config,
  String? documentName,
  String? documentContent,
  List<String> comments = const [],
  List<LlmTool> tools = const [],
  List<String> supportingFiles = const [],
  int maxDocumentChars = 24000,
}) {
  final buffer = StringBuffer()
    ..writeln(config.effectiveSystemPrompt.trim())
    ..writeln();
  if (tools.isEmpty) {
    buffer.writeln(
      'You have no access to the file system, the internet, or any tools. '
      'The only document material you can see is provided below; treat it as '
      'the complete source of truth.',
    );
  } else {
    _writeToolGuidance(buffer, tools, supportingFiles);
  }

  final content = documentContent;
  if (content == null || content.trim().isEmpty) {
    buffer
      ..writeln()
      ..writeln('## Document')
      ..writeln(
        documentName == null || documentName.trim().isEmpty
            ? 'No document is currently open.'
            : 'The open document "${documentName.trim()}" is empty.',
      );
  } else {
    buffer
      ..writeln()
      ..writeln(
        '## Document'
        '${documentName == null || documentName.trim().isEmpty ? '' : ': ${documentName.trim()}'}',
      )
      ..writeln();
    buffer.writeln(_truncate(content, maxDocumentChars));
  }

  final openComments =
      comments.where((c) => c.trim().isNotEmpty).toList();
  if (openComments.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Comments on the document')
      ..writeln(
        'The user has left the following comments on the document. Take '
        'them into account when answering questions about it:',
      );
    for (final comment in openComments) {
      buffer.writeln('- ${comment.trim()}');
    }
  }

  final table = config.translationTable;
  if (table.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Translation table')
      ..writeln(
        'Whenever you write or quote document text, always use the preferred '
        'wording from this table instead of the original phrase:',
      );
    table.forEach((original, entry) {
      buffer.writeln('- "${original.trim()}" → "${entry.correction.trim()}"');
    });
  }

  return buffer.toString().trimRight();
}

/// Explains the available [tools] and attached [supportingFiles].
void _writeToolGuidance(
  StringBuffer buffer,
  List<LlmTool> tools,
  List<String> supportingFiles,
) {
  final names = {for (final tool in tools) tool.name};
  buffer.writeln(
    'You have no access to the file system or the internet. You can act '
    'only through these tools: ${names.join(', ')}.',
  );
  if (names.contains('write_document')) {
    buffer.writeln(
      'When the user asks you to change the document, make the change with '
      'write_document instead of pasting revised text into the chat, then '
      'briefly say what you changed. The user sees your edits live and can '
      'undo them.',
    );
  }
  if (names.contains('read_document')) {
    buffer.writeln(
      'The user may edit the document while you work, so the snapshot below '
      'can be out of date. If an edit fails because text was not found, call '
      'read_document for the current content and try again.',
    );
  }
  if (names.contains('read_supporting_file')) {
    buffer
      ..writeln()
      ..writeln('## Supporting files');
    if (supportingFiles.isEmpty) {
      buffer.writeln(
        'The user has not attached any supporting files. If you need one, '
        'ask the user to attach it with the paperclip button in the chat.',
      );
    } else {
      buffer.writeln(
        'The user attached these files for reference. Read them with '
        'read_supporting_file when they are relevant:',
      );
      for (final name in supportingFiles) {
        buffer.writeln('- $name');
      }
    }
  }
}

/// Truncates [text] to at most [maxChars] characters.
///
/// When truncation happens, the cut is moved to the last newline before the
/// limit (so paragraphs are not split mid-line) and a marker is appended.
String _truncate(String text, int maxChars) {
  if (text.length <= maxChars) return text;
  var cut = text.lastIndexOf('\n', maxChars);
  if (cut < maxChars ~/ 2) cut = maxChars;
  return '${text.substring(0, cut).trimRight()}\n[... document truncated ...]';
}
