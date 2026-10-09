import 'dart:io';

import 'package:document_editor/src/documents/document_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late DocumentState document;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('document_edit_test');
    document = DocumentState();
  });

  tearDown(() async {
    document.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<void> open(String content) async {
    final file = File('${tempDir.path}/doc.txt')..writeAsStringSync(content);
    await document.openFile(file.path);
  }

  String text() => document.quill.document.toPlainText();

  group('applyTextEdits', () {
    test('replaces text found anywhere in the document', () async {
      await open('The quick brown fox.\nJumps over the dog.\n');

      final applied = document.applyTextEdits(const [
        TextEdit(oldText: 'brown', newText: 'red'),
        TextEdit(oldText: 'the dog', newText: 'the lazy dog'),
      ]);

      expect(applied, 2);
      expect(text(), 'The quick red fox.\nJumps over the lazy dog.\n');
      expect(document.dirty, isTrue);
    });

    test('appends when old text is empty', () async {
      await open('First line\n');

      document.applyTextEdits(const [
        TextEdit(oldText: '', newText: '\nSecond line'),
      ]);

      expect(text(), 'First line\nSecond line\n');
    });

    test('appends to an empty document', () async {
      await open('');

      document.applyTextEdits(const [TextEdit(oldText: '', newText: 'Hello')]);

      expect(text(), 'Hello\n');
    });

    test('keeps the mandatory trailing newline when replacing it', () async {
      await open('alpha\n');

      document.applyTextEdits(const [
        TextEdit(oldText: 'alpha\n', newText: 'beta'),
      ]);

      expect(text(), 'beta\n');
    });

    test('rejects missing text and leaves the document untouched', () async {
      await open('one two three\n');

      expect(
        () => document.applyTextEdits(const [
          TextEdit(oldText: 'one', newText: '1'),
          TextEdit(oldText: 'four', newText: '4'),
        ]),
        throwsA(isA<DocumentEditException>()
            .having((e) => e.message, 'message', contains('not found'))),
      );
      expect(text(), 'one two three\n');
      expect(document.quill.hasUndo, isFalse);
    });

    test('rejects ambiguous text', () async {
      await open('cat and cat\n');

      expect(
        () => document.applyTextEdits(
            const [TextEdit(oldText: 'cat', newText: 'dog')]),
        throwsA(isA<DocumentEditException>()
            .having((e) => e.message, 'message', contains('more than once'))),
      );
      expect(text(), 'cat and cat\n');
    });

    test('rejects overlapping edits', () async {
      await open('abcdef\n');

      expect(
        () => document.applyTextEdits(const [
          TextEdit(oldText: 'abcd', newText: 'x'),
          TextEdit(oldText: 'cdef', newText: 'y'),
        ]),
        throwsA(isA<DocumentEditException>()),
      );
      expect(text(), 'abcdef\n');
    });

    test('reports zero when nothing changes', () async {
      await open('same\n');

      expect(
        document.applyTextEdits(
            const [TextEdit(oldText: 'same', newText: 'same')]),
        0,
      );
      expect(document.quill.hasUndo, isFalse);
    });

    test('throws when no document is open', () {
      expect(
        () => document.applyTextEdits(const [TextEdit(oldText: '', newText: 'x')]),
        throwsA(isA<DocumentEditException>()),
      );
    });

    test('inherits inline formatting of the replaced text', () async {
      await open('plain bold plain\n');
      document.quill.formatText(6, 4, Attribute.bold);

      document.applyTextEdits(const [TextEdit(oldText: 'bold', newText: 'STRONG')]);

      final ops = document.quill.document.toDelta().toList();
      final strong = ops.firstWhere((op) => op.data == 'STRONG');
      expect(strong.attributes, {'bold': true});
    });

    test('is a single undo step separate from recent user typing', () async {
      await open('Hello world\n');
      // The user types just before the agent edit lands (well within
      // quill's history merge interval).
      document.quill.replaceText(
          11, 0, '!', const TextSelection.collapsed(offset: 12));
      document.applyTextEdits(const [
        TextEdit(oldText: 'Hello', newText: 'Goodbye'),
        TextEdit(oldText: 'world', newText: 'moon'),
      ]);
      expect(text(), 'Goodbye moon!\n');

      document.quill.undo();
      expect(text(), 'Hello world!\n', reason: 'agent edit undone as one unit');

      document.quill.undo();
      expect(text(), 'Hello world\n', reason: 'user typing is its own step');

      document.quill.redo();
      document.quill.redo();
      expect(text(), 'Goodbye moon!\n');
    });

    test('shifts the user caret along with text inserted before it', () async {
      await open('abc XYZ\n');
      document.quill.updateSelection(
          const TextSelection.collapsed(offset: 5), ChangeSource.local);

      document.applyTextEdits(const [TextEdit(oldText: 'abc', newText: 'abcdef')]);

      expect(document.quill.selection, const TextSelection.collapsed(offset: 8));
      expect(text().substring(8), 'YZ\n');
    });

    test('lands correctly after concurrent user edits elsewhere', () async {
      await open('Intro.\nTarget sentence.\n');
      // Agent computed its edit from this snapshot...
      const edit = TextEdit(oldText: 'Target sentence.', newText: 'New sentence.');
      // ...then the user rewrote the intro before the edit was applied.
      document.quill.compose(
        Delta()
          ..delete(6)
          ..insert('A much longer introduction.'),
        const TextSelection.collapsed(offset: 0),
        ChangeSource.local,
      );

      document.applyTextEdits(const [edit]);

      expect(text(), 'A much longer introduction.\nNew sentence.\n');
    });

    test('fails cleanly when the user changed the target text', () async {
      await open('Target sentence.\n');
      document.quill.replaceText(
          0, 6, 'Edited', const TextSelection.collapsed(offset: 6));

      expect(
        () => document.applyTextEdits(const [
          TextEdit(oldText: 'Target sentence.', newText: 'Agent text.'),
        ]),
        throwsA(isA<DocumentEditException>()),
      );
      expect(text(), 'Edited sentence.\n', reason: "user's edit is kept");
    });
  });
}
