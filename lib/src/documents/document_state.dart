import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:path/path.dart' as p;

import 'adapters/document_adapter.dart';
import 'document_edit.dart';
import 'document_format.dart';

export 'document_edit.dart';

/// Holds the state of the currently open document.
///
/// Wraps a [QuillController] (content, selection, undo/redo history) and
/// adds file-level concerns: the open file path, the document format,
/// dirty tracking and the open/save/save-as operations.
class DocumentState extends ChangeNotifier {
  final QuillController _quill = QuillController.basic();

  String? _filePath;
  DocumentFormat _format = DocumentFormat.txt;
  List<dynamic> _lastSavedDelta = [
    {
      'insert': '\n'
    }
  ];
  bool _fileEndedWithNewline = true;
  String? _errorMessage;

  /// Editor controller bound to the current document.
  QuillController get quill => _quill;

  /// Absolute path of the open file, or null when no document is open.
  String? get filePath => _filePath;

  /// Base name of the open file, or null when no document is open.
  String? get fileName {
    final path = _filePath;
    return path == null ? null : p.basename(path);
  }

  /// Whether a file is currently open.
  bool get hasDocument => _filePath != null;

  /// The storage format of the open file, as detected from its extension.
  DocumentFormat get format => _format;

  /// Whether the in-memory content differs from the last saved version.
  ///
  /// Compares full Deltas so formatting-only changes (bold, italic, ...)
  /// also count as unsaved changes.
  bool get dirty {
    if (!hasDocument) return false;
    return !const DeepCollectionEquality()
        .equals(_lastSavedDelta, _quill.document.toDelta().toJson());
  }

  /// Last error message from an open/save operation, if any.
  String? get errorMessage => _errorMessage;

  /// Toolbar/window title for the current document.
  String get title => !hasDocument
      ? 'No document'
      : (dirty ? '$fileName*' : fileName!);

  @override
  void dispose() {
    _quill.dispose();
    super.dispose();
  }

  /// Opens [filePath] and loads its content into the editor.
  ///
  /// The document format is detected from the file extension; unrecognized
  /// extensions are treated as plain text. Any previously open document is
  /// replaced without prompting.
  ///
  /// Throws [IOException] if the file cannot be read or [FormatException]
  /// if the content is not valid for the detected format.
  Future<void> openFile(String filePath) async {
    final format = DocumentFormat.fromFileName(filePath) ?? DocumentFormat.txt;
    final bytes = await File(filePath).readAsBytes();
    final delta = DocumentAdapter.forFormat(format).parse(bytes);

    _filePath = null; // Defer dirty tracking until fully loaded.
    _quill.document = Document.fromDelta(delta);
    _filePath = filePath;
    _format = format;
    _lastSavedDelta = _quill.document.toDelta().toJson();
    _fileEndedWithNewline = _endsWithNewline(format, bytes);
    _errorMessage = null;
    notifyListeners();
  }

  /// Writes the current content back to the open file in its stored format.
  ///
  /// Quill documents always end with a newline; when the original file did
  /// not, the trailing newline is stripped so unchanged files are written
  /// back byte-identical. Does nothing when no document is open. Throws
  /// [IOException] on write failure, which callers may surface to the user.
  Future<void> save() async {
    if (!hasDocument) return;
    final path = _filePath!;
    final format = _format;
    final bytes =
        DocumentAdapter.forFormat(format).serialize(_quill.document.toDelta());
    // Text formats: strip the trailing newline if the original file did
    // not end with one, so unchanged files are written back byte-identical.
    if (format != DocumentFormat.docx &&
        !_fileEndedWithNewline &&
        bytes.isNotEmpty &&
        bytes.last == 0x0A) {
      await File(path).writeAsBytes(bytes.sublist(0, bytes.length - 1));
    } else {
      await File(path).writeAsBytes(bytes);
    }
    _lastSavedDelta = _quill.document.toDelta().toJson();
    _errorMessage = null;
    notifyListeners();
  }

  /// Saves the current content to [targetPath], converting to the format
  /// implied by the target file's extension, and opens it as the current
  /// document.
  Future<void> saveAs(String targetPath) async {
    if (!hasDocument) return;
    final format = DocumentFormat.fromFileName(targetPath) ?? DocumentFormat.txt;
    final bytes =
        DocumentAdapter.forFormat(format).serialize(_quill.document.toDelta());
    await File(targetPath).writeAsBytes(bytes);
    _filePath = targetPath;
    _format = format;
    _fileEndedWithNewline = true;
    _lastSavedDelta = _quill.document.toDelta().toJson();
    _errorMessage = null;
    notifyListeners();
  }

  /// Adopts a document that has already been written to [targetPath] (e.g. by
  /// a save dialog that writes the bytes itself) in [format], and marks it as
  /// the current, saved document. Does nothing when no document is open.
  Future<void> saveAsWritten(String targetPath, DocumentFormat format) async {
    if (!hasDocument) return;
    _filePath = targetPath;
    _format = format;
    _fileEndedWithNewline = true;
    _lastSavedDelta = _quill.document.toDelta().toJson();
    _errorMessage = null;
    notifyListeners();
  }

  /// Whether the raw bytes of a text-format file end with a newline.
  ///
  /// Binary formats (docx) track no newline.
  bool _endsWithNewline(DocumentFormat format, List<int> bytes) {
    if (format == DocumentFormat.docx) return false;
    if (bytes.isEmpty) return true;
    // Ignore a trailing carriage return from CRLF line endings.
    if (bytes.length >= 2 && bytes.last == 0x0A && bytes[bytes.length - 2] == 0x0D) {
      return true;
    }
    return bytes.last == 0x0A;
  }

  /// Clears the stored error message (e.g. after showing it to the user).
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// Records an error from an open/save attempt.
  void reportError(String message) {
    _errorMessage = message;
    notifyListeners();
  }

  /// Applies [edits] to the live document as one undoable transaction and
  /// returns the number of edits that changed the document.
  ///
  /// Edits are anchored by content, not by offset: each
  /// [TextEdit.oldText] is located in the document *as it is now*, so edits
  /// computed from an older snapshot still land in the right place when the
  /// user has typed elsewhere in the meantime. An edit whose text is
  /// missing, ambiguous, or overlaps another edit makes the whole batch
  /// fail with a [DocumentEditException] and leaves the document untouched.
  ///
  /// The user's cursor and selection are shifted along with the change.
  /// Inserted text inherits the inline formatting (bold, italic, ...) of the
  /// text it replaces or follows. The change is recorded as its own undo
  /// step, never merged with surrounding user keystrokes.
  int applyTextEdits(List<TextEdit> edits) {
    if (!hasDocument) {
      throw const DocumentEditException('No document is open.');
    }
    final document = _quill.document;
    final text = document.toPlainText();
    final ops = document.toDelta().toList();

    final ranges = <({int order, int start, int end, String insert})>[];
    for (final (order, edit) in edits.indexed) {
      if (edit.oldText.isEmpty) {
        // Append before the document's mandatory trailing newline.
        final at = text.length - 1;
        ranges.add((order: order, start: at, end: at, insert: edit.newText));
        continue;
      }
      final start = text.indexOf(edit.oldText);
      if (start < 0) {
        throw DocumentEditException(
          'Text not found: "${_preview(edit.oldText)}". The document may have '
          'changed since you last read it.',
        );
      }
      if (text.indexOf(edit.oldText, start + 1) >= 0) {
        throw DocumentEditException(
          'Text appears more than once: "${_preview(edit.oldText)}". Include '
          'more surrounding text so it matches exactly one place.',
        );
      }
      final end = start + edit.oldText.length;
      var insert = edit.newText;
      // Quill documents must keep their final newline.
      if (end == text.length && !insert.endsWith('\n')) insert = '$insert\n';
      ranges.add((order: order, start: start, end: end, insert: insert));
    }
    ranges.sort((a, b) =>
        a.start != b.start ? a.start.compareTo(b.start) : a.order.compareTo(b.order));
    for (var i = 1; i < ranges.length; i++) {
      if (ranges[i].start < ranges[i - 1].end) {
        throw const DocumentEditException(
          'Two edits overlap the same text. Combine them into one edit.',
        );
      }
    }

    final delta = Delta();
    var cursor = 0;
    var applied = 0;
    for (final range in ranges) {
      if (text.substring(range.start, range.end) == range.insert) continue;
      applied++;
      if (range.start > cursor) delta.retain(range.start - cursor);
      if (range.end > range.start) delta.delete(range.end - range.start);
      final attributes = range.end > range.start
          ? _inlineAttributesAt(ops, range.start)
          : (range.start > 0 ? _inlineAttributesAt(ops, range.start - 1) : null);
      // Newlines carry block attributes in Quill; insert them unstyled.
      final pieces = range.insert.split('\n');
      for (final (i, piece) in pieces.indexed) {
        if (piece.isNotEmpty) delta.insert(piece, attributes);
        if (i < pieces.length - 1) delta.insert('\n');
      }
      cursor = range.end;
    }
    if (applied == 0) return 0;

    // Isolate the change in its own undo entry: quill merges changes that
    // arrive within a short interval of each other.
    final history = document.history;
    history.lastRecorded = 0;
    _quill.compose(delta, _quill.selection, ChangeSource.remote);
    history.lastRecorded = 0;
    return applied;
  }

  /// The inline attributes (bold, italic, ...) of the character at
  /// [offset], or null for a newline, an embed, or plain text. Links are
  /// not inherited.
  static Map<String, dynamic>? _inlineAttributesAt(
      List<Operation> ops, int offset) {
    var position = 0;
    for (final op in ops) {
      final length = op.length ?? 0;
      if (offset < position + length) {
        final data = op.data;
        if (data is! String || data[offset - position] == '\n') return null;
        final attributes = Map<String, dynamic>.of(op.attributes ?? const {})
          ..remove(Attribute.link.key);
        return attributes.isEmpty ? null : attributes;
      }
      position += length;
    }
    return null;
  }

  static String _preview(String text) {
    final oneLine = text.replaceAll('\n', '\\n');
    return oneLine.length <= 80 ? oneLine : '${oneLine.substring(0, 77)}...';
  }

  /// Converts [text] to a Quill [Delta] of plain text.
  ///
  /// Quill documents must end with a newline, so one is appended when
  /// [text] does not.
  Delta deltaFromPlainText(String text) {
    final delta = Delta();
    if (text.isEmpty || !text.endsWith('\n')) {
      delta.insert('$text\n');
    } else {
      delta.insert(text);
    }
    return delta;
  }
}
