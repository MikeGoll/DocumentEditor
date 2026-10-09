import 'dart:io';

import 'package:document_editor/src/documents/adapters/document_adapter.dart';
import 'package:document_editor/src/documents/document_format.dart';
import 'package:document_editor/src/documents/document_state.dart';
import 'package:document_editor/src/documents/table.dart';
import 'package:document_editor/src/llm/llm_client.dart';
import 'package:document_editor/src/tools/document_tools.dart';
import 'package:document_editor/src/tools/supporting_files.dart';
import 'package:document_editor/src/tools/tool_registry.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

LlmToolCall call(String name, Map<String, dynamic> arguments) =>
    LlmToolCall(id: 'id-$name', name: name, arguments: arguments);

void main() {
  late Directory tempDir;
  late DocumentState document;
  late SupportingFiles files;
  late ToolRegistry registry;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('agent_tools_test');
    document = DocumentState();
    files = SupportingFiles();
    registry = ToolRegistry([
      ReadDocumentTool(document, maxChars: 20),
      WriteDocumentTool(document),
      ReadSupportingFileTool(files, maxChars: 1000),
    ]);
  });

  tearDown(() async {
    document.dispose();
    files.dispose();
    await tempDir.delete(recursive: true);
  });

  File writeFile(String name, String content) =>
      File('${tempDir.path}/$name')..writeAsStringSync(content);

  group('ToolRegistry', () {
    test('exposes a JSON schema for every tool', () {
      final names = registry.definitions.map((t) => t.name);
      expect(names, ['read_document', 'write_document', 'read_supporting_file']);
      for (final tool in registry.definitions) {
        expect(tool.description, isNotEmpty);
        expect(tool.parameters['type'], 'object');
      }
    });

    test('reports unknown tools as errors', () async {
      final execution = await registry.execute(call('delete_disk', const {}));

      expect(execution.result.isError, isTrue);
      expect(execution.result.callId, 'id-delete_disk');
      expect(execution.result.content, contains('Unknown tool'));
    });

    test('reports malformed arguments as errors', () async {
      final execution = await registry.execute(const LlmToolCall(
        id: 'x',
        name: 'write_document',
        arguments: {},
        malformedArguments: '{"edits": [',
      ));

      expect(execution.result.isError, isTrue);
      expect(execution.result.content, contains('valid JSON'));
    });

    test('reports invalid argument types as errors', () async {
      await document.openFile(writeFile('doc.txt', 'x').path);
      final execution = await registry.execute(
          call('write_document', const {'edits': 'not a list'}));

      expect(execution.result.isError, isTrue);
      expect(execution.result.content, contains('Invalid arguments'));
    });
  });

  group('read_document', () {
    test('returns the live content, paged', () async {
      await document.openFile(
          writeFile('doc.txt', 'abcdefghijklmnopqrstuvwxyz').path);

      final first = await registry.execute(call('read_document', const {}));
      expect(first.result.isError, isFalse);
      expect(first.result.content, startsWith('abcdefghijklmnopqrst'));
      expect(first.result.content, contains('offset 20'));
      expect(first.summary, 'Read the document');

      final second = await registry
          .execute(call('read_document', const {'offset': 20}));
      expect(second.result.content, startsWith('uvwxyz\n'));
      expect(second.result.content, contains('end of text'));
    });

    test('sees edits made by the user after opening', () async {
      await document.openFile(writeFile('doc.txt', 'old').path);
      document.quill.document.insert(0, 'new ');

      final execution = await registry.execute(call('read_document', const {}));
      expect(execution.result.content, 'new old\n');
    });

    test('errors when no document is open', () async {
      final execution = await registry.execute(call('read_document', const {}));
      expect(execution.result.isError, isTrue);
    });
  });

  group('write_document', () {
    test('applies edits to the live document', () async {
      await document.openFile(writeFile('doc.txt', 'Hello world\n').path);

      final execution = await registry.execute(call('write_document', const {
        'edits': [
          {'old_text': 'world', 'new_text': 'there'},
          {'old_text': '', 'new_text': '\nBye'},
        ],
      }));

      expect(execution.result.isError, isFalse);
      expect(execution.result.content, contains('Applied 2 edits'));
      expect(execution.summary, 'Edited the document (2 changes)');
      expect(document.quill.document.toPlainText(), 'Hello there\nBye\n');
      // Edits stay in memory; the user decides when to save.
      expect(File('${tempDir.path}/doc.txt').readAsStringSync(), 'Hello world\n');
    });

    test('returns a recoverable error when text is not found', () async {
      await document.openFile(writeFile('doc.txt', 'Hello\n').path);

      final execution = await registry.execute(call('write_document', const {
        'edits': [
          {'old_text': 'Goodbye', 'new_text': 'Hi'},
        ],
      }));

      expect(execution.result.isError, isTrue);
      expect(execution.result.content, contains('read_document'));
      expect(execution.summary, 'Document edit failed');
      expect(document.quill.document.toPlainText(), 'Hello\n');
    });
  });

  group('read_supporting_file', () {
    test('reads an attached text file', () async {
      final file = writeFile('notes.txt', 'Supporting facts.');
      files.addAll([file.path]);

      final execution = await registry
          .execute(call('read_supporting_file', const {'name': 'notes.txt'}));

      expect(execution.result.isError, isFalse);
      expect(execution.result.content, 'Supporting facts.\n');
      expect(execution.summary, 'Read supporting file notes.txt');
    });

    test('reads an attached docx file including tables', () async {
      final delta = Delta()
        ..insert('Report\n')
        ..insert(BlockEmbed.custom(TableEmbed(TableData([
          [Delta()..insert('Name\n'), Delta()..insert('Score\n')],
          [Delta()..insert('Ada\n'), Delta()..insert('42\n')],
        ]))).toJson())
        ..insert('\n');
      final bytes =
          DocumentAdapter.forFormat(DocumentFormat.docx).serialize(delta);
      final file = File('${tempDir.path}/report.docx')..writeAsBytesSync(bytes);
      files.addAll([file.path]);

      final execution = await registry
          .execute(call('read_supporting_file', const {'name': 'report.docx'}));

      expect(execution.result.isError, isFalse);
      expect(execution.result.content, contains('Report'));
      expect(execution.result.content, contains('Name | Score'));
      expect(execution.result.content, contains('Ada | 42'));
    });

    test('refuses files the user did not attach', () async {
      final attached = writeFile('a.txt', 'A');
      final secret = writeFile('secret.txt', 'top secret');
      files.addAll([attached.path]);

      for (final name in ['secret.txt', secret.path, '../secret.txt']) {
        final execution = await registry
            .execute(call('read_supporting_file', {'name': name}));
        expect(execution.result.isError, isTrue, reason: name);
        expect(execution.result.content, isNot(contains('top secret')));
        expect(execution.result.content, contains('a.txt'));
      }
    });

    test('explains how to attach when nothing is attached', () async {
      final execution = await registry
          .execute(call('read_supporting_file', const {'name': 'x.txt'}));

      expect(execution.result.isError, isTrue);
      expect(execution.result.content, contains('attach'));
    });

    test('refuses binary files', () async {
      final file = File('${tempDir.path}/image.bin')
        ..writeAsBytesSync([0xff, 0xfe, 0x00, 0xc3, 0x28]);
      files.addAll([file.path]);

      final execution = await registry
          .execute(call('read_supporting_file', const {'name': 'image.bin'}));

      expect(execution.result.isError, isTrue);
      expect(execution.result.content, contains('not a readable'));
    });

    test('reports files that disappeared', () async {
      final file = writeFile('gone.txt', 'x');
      files.addAll([file.path]);
      file.deleteSync();

      final execution = await registry
          .execute(call('read_supporting_file', const {'name': 'gone.txt'}));

      expect(execution.result.isError, isTrue);
      expect(execution.summary, contains('Could not read gone.txt'));
    });
  });

  group('SupportingFiles', () {
    test('deduplicates and notifies on change', () {
      var notifications = 0;
      files.addListener(() => notifications++);

      files.addAll(['/tmp/a.txt', '/tmp/a.txt', '/tmp/b.txt']);
      files.addAll(['/tmp/a.txt']);
      files.remove('/tmp/a.txt');

      expect(files.paths, ['/tmp/b.txt']);
      expect(notifications, 2);
    });

    test('uses full paths when base names clash', () {
      files.addAll(['/one/notes.txt', '/two/notes.txt', '/two/other.md']);

      expect(files.displayNames,
          ['/one/notes.txt', '/two/notes.txt', 'other.md']);
      expect(files.resolve('notes.txt'), isNull);
      expect(files.resolve('/two/notes.txt'), '/two/notes.txt');
      expect(files.resolve('other.md'), '/two/other.md');
    });
  });
}
