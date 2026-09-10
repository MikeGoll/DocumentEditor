import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:path/path.dart' as p;

import 'adapters/document_adapter.dart';
import 'document_format.dart';

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
