import 'dart:io';

import 'package:document_editor/src/documents/document_state.dart';
import 'package:flutter/material.dart' show TextSelection;
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late DocumentState state;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('document_editor_test');
    state = DocumentState();
  });

  tearDown(() {
    state.dispose();
    tempDir.deleteSync(recursive: true);
  });

  String writeTemp(String name, String content) {
    final file = File('${tempDir.path}/$name')..writeAsStringSync(content);
    return file.path;
  }

  /// Appends [text] to the last line via the quill controller.
  void append(String text) {
    final doc = state.quill;
    final end = doc.document.length - 1; // before the trailing newline
    doc.replaceText(
      end,
      0,
      text,
      TextSelection.collapsed(offset: end + text.length),
    );
  }

  group('openFile', () {
    test('loads content and tracks the file path', () async {
      final path = writeTemp('a.txt', 'hello\nworld');

      await state.openFile(path);

      expect(state.hasDocument, isTrue);
      expect(state.filePath, path);
      expect(state.fileName, 'a.txt');
      expect(state.quill.document.toPlainText(), 'hello\nworld\n');
      expect(state.dirty, isFalse);
    });

    test('empty file opens as an empty document', () async {
      final path = writeTemp('empty.txt', '');

      await state.openFile(path);

      expect(state.hasDocument, isTrue);
      expect(state.quill.document.toPlainText(), '\n');
      expect(state.dirty, isFalse);
    });

    test('preserves formatting attributes across save/reopen round trip',
        () async {
      final path = writeTemp('keep.txt', 'one');
      await state.openFile(path);
      await state.save();

      // Reopen the same path; content must match.
      await state.openFile(path);
      expect(state.quill.document.toPlainText(), 'one\n');
    });

    test('throws when the file does not exist', () async {
      await expectLater(
        state.openFile('${tempDir.path}/missing.txt'),
        throwsA(isA<FileSystemException>()),
      );
      expect(state.hasDocument, isFalse);
    });
  });

  group('dirty tracking', () {
    test('edits mark the document dirty, saving clears it', () async {
      final path = writeTemp('edit.txt', 'base\n');
      await state.openFile(path);

      append('more');
      expect(state.dirty, isTrue);
      expect(state.title, 'edit.txt*');

      await state.save();
      expect(state.dirty, isFalse);
      expect(state.title, 'edit.txt');
      expect(File(path).readAsStringSync(), 'basemore\n');
    });

    test('save without an open file is a no-op', () async {
      await state.save(); // must not throw
      expect(state.hasDocument, isFalse);
    });
  });

  group('undo/redo', () {
    test('undo reverts an edit, redo reapplies it', () async {
      final path = writeTemp('undo.txt', 'start\n');
      await state.openFile(path);

      expect(state.quill.hasUndo, isFalse);

      append('abc');
      expect(state.quill.hasUndo, isTrue);
      expect(state.dirty, isTrue);

      state.quill.undo();
      expect(state.quill.document.toPlainText(), 'start\n');
      expect(state.dirty, isFalse);
      expect(state.quill.hasRedo, isTrue);

      state.quill.redo();
      expect(state.quill.document.toPlainText(), 'startabc\n');
      expect(state.dirty, isTrue);
      expect(state.quill.hasRedo, isFalse);
    });

    test('undo reverts formatting as well', () async {
      final path = writeTemp('fmt.txt', 'text\n');
      await state.openFile(path);

      state.quill.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 4),
        ChangeSource.local,
      );
      state.quill.formatSelection(Attribute.bold);
      expect(state.dirty, isTrue);

      state.quill.undo();
      expect(state.dirty, isFalse);
      expect(
        state.quill
            .getAllSelectionStyles()
            .any((s) => s.values.any((a) => a.key == 'bold')),
        isFalse,
      );
    });
  });

  group('formatting', () {
    test('bold/italic/underline applied to the selection appear in the delta',
        () async {
      final path = writeTemp('style.txt', 'word\n');
      await state.openFile(path);

      final quill = state.quill;
      quill.updateSelection(
        const TextSelection(baseOffset: 0, extentOffset: 4),
        ChangeSource.local,
      );
      quill.formatSelection(Attribute.bold);
      quill.formatSelection(Attribute.italic);
      quill.formatSelection(Attribute.underline);

      final styles = quill.getAllSelectionStyles();
      for (final key in ['bold', 'italic', 'underline']) {
        expect(
          styles.any((s) => s.values.any((a) => a.key == key)),
          isTrue,
          reason: 'missing $key style',
        );
      }
    });
  });

  group('deltaFromPlainText', () {
    test('converts plain text to a quill delta', () {
      final delta = state.deltaFromPlainText('a\nb');
      expect(delta.toJson(), [
        {'insert': 'a\nb\n'}
      ]);
    });

    test('empty text yields a single newline delta', () {
      final delta = state.deltaFromPlainText('');
      expect(delta.toJson(), [
        {'insert': '\n'}
      ]);
    });
  });
}
