import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:path/path.dart' as p;

import '../documents/adapters/document_adapter.dart';
import '../documents/document_format.dart';
import '../documents/table.dart';
import '../llm/llm_client.dart';
import 'tool_registry.dart';

/// Files the user has attached to the chat for the agent to read.
///
/// This list is the agent's entire view of the file system beyond the open
/// document: [ReadSupportingFileTool] refuses any file not in it. Files are
/// read locally on demand and never uploaded anywhere except as tool
/// results in the conversation with the configured provider.
class SupportingFiles extends ChangeNotifier {
  final List<String> _paths = [];

  /// Absolute paths, in the order they were attached.
  List<String> get paths => List.unmodifiable(_paths);

  bool get isEmpty => _paths.isEmpty;

  /// Attaches [paths], ignoring ones already attached.
  void addAll(Iterable<String> paths) {
    var changed = false;
    for (final path in paths) {
      final normalized = p.normalize(path);
      if (!_paths.contains(normalized)) {
        _paths.add(normalized);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void remove(String path) {
    if (_paths.remove(p.normalize(path))) notifyListeners();
  }

  /// How the agent should refer to [path]: its base name, or the full path
  /// when several attached files share that name.
  String displayName(String path) {
    final name = p.basename(path);
    final clashes = _paths.where((other) => p.basename(other) == name).length;
    return clashes > 1 ? path : name;
  }

  /// Names to list in the agent's system prompt.
  List<String> get displayNames => [for (final path in _paths) displayName(path)];

  /// Resolves a name the agent supplied to an attached path, or null.
  String? resolve(String name) {
    final trimmed = name.trim();
    for (final path in _paths) {
      if (path == trimmed || displayName(path) == trimmed) return path;
    }
    return null;
  }
}

/// Lets the agent read a file the user attached as supporting material.
class ReadSupportingFileTool extends AgentTool {
  ReadSupportingFileTool(
    this._files, {
    this.maxChars = 24000,
    this.maxBytes = 10 * 1024 * 1024,
  });

  final SupportingFiles _files;

  /// Characters returned per call; longer files are paged.
  final int maxChars;

  /// Files larger than this are refused.
  final int maxBytes;

  @override
  LlmTool get definition => const LlmTool(
        name: 'read_supporting_file',
        description:
            'Reads the text of a supporting file the user attached to the '
            'chat (listed in the system prompt). Only attached files can be '
            'read. Supports .txt, .md and .docx files and other plain-text '
            'files. Long files are returned in pages.',
        parameters: {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'The file name exactly as listed.',
            },
            'offset': {
              'type': 'integer',
              'description':
                  'Character offset to start reading from (default 0).',
            },
          },
          'required': ['name'],
        },
      );

  @override
  Future<ToolOutcome> execute(Map<String, dynamic> arguments) async {
    final name = requireString(arguments, 'name');
    final offset = optionalInt(arguments, 'offset') ?? 0;
    final path = _files.resolve(name);
    if (path == null) {
      final available = _files.displayNames;
      return ToolOutcome.error(
        available.isEmpty
            ? 'No supporting files are attached. Ask the user to attach the '
                'file with the paperclip button in the chat.'
            : '"$name" is not an attached file. Attached files: '
                '${available.join(', ')}.',
        summary: 'Tried to read "$name", which is not attached',
      );
    }

    final label = _files.displayName(path);
    try {
      final file = File(path);
      final size = await file.length();
      if (size > maxBytes) {
        return ToolOutcome.error(
          '$label is too large to read ($size bytes).',
          summary: 'Could not read $label (too large)',
        );
      }
      final text = _extractText(path, await file.readAsBytes());
      return ToolOutcome(
        content: pageText(text, offset: offset, maxChars: maxChars),
        summary: 'Read supporting file $label',
      );
    } on FileSystemException catch (error) {
      return ToolOutcome.error(
        'Could not read $label: ${error.message}.',
        summary: 'Could not read $label',
      );
    } on FormatException {
      return ToolOutcome.error(
        '$label is not a readable text document.',
        summary: 'Could not read $label (unsupported format)',
      );
    }
  }

  /// Converts [bytes] to plain text: supported document formats through
  /// their adapter (tables rendered as `a | b` rows), anything else as
  /// UTF-8 text. Throws [FormatException] for binary content.
  static String _extractText(String path, List<int> bytes) {
    final format = DocumentFormat.fromFileName(path);
    if (format == null) return utf8.decode(bytes);
    return _deltaToText(DocumentAdapter.forFormat(format).parse(bytes));
  }

  static String _deltaToText(Delta delta) {
    final buffer = StringBuffer();
    for (final op in delta.toList()) {
      final data = op.data;
      if (data is String) {
        buffer.write(data);
        continue;
      }
      final table = TableEmbed.tryParseOp(data);
      if (table == null) continue;
      for (final row in table.rows) {
        buffer.writeln(row
            .map((cell) => cell.toPlainText().trim().replaceAll('\n', ' '))
            .join(' | '));
      }
    }
    return buffer.toString();
  }
}
