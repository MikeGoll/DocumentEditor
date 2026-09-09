import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:path/path.dart' as p;

/// Holds the state of the currently open document.
///
/// Wraps a [QuillController] (content, selection, undo/redo history) and
/// adds file-level concerns: the open file path, dirty tracking and the
/// open/save operations.
class DocumentState extends ChangeNotifier {
  final QuillController _quill = QuillController.basic();

  String? _filePath;
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
  /// Any previously open document is replaced without prompting.
  /// Throws [IOException] if the file cannot be read.
  Future<void> openFile(String filePath) async {
    final content = await File(filePath).readAsString();

    _filePath = null; // Defer dirty tracking until fully loaded.
    _quill.document = Document.fromDelta(deltaFromPlainText(content));
    _filePath = filePath;
    _lastSavedDelta = _quill.document.toDelta().toJson();
    _fileEndedWithNewline = content.isEmpty || content.endsWith('\n');
    _errorMessage = null;
    notifyListeners();
  }

  /// Writes the current content back to the open file.
  ///
  /// Quill documents always end with a newline; when the original file did
  /// not, the trailing newline is stripped so unchanged files are written
  /// back byte-identical. Does nothing when no document is open. Throws
  /// [IOException] on write failure, which callers may surface to the user.
  Future<void> save() async {
    if (!hasDocument) return;
    var content = _quill.document.toPlainText();
    if (!_fileEndedWithNewline && content.endsWith('\n')) {
      content = content.substring(0, content.length - 1);
    }
    await File(_filePath!).writeAsString(content);
    _lastSavedDelta = _quill.document.toDelta().toJson();
    _errorMessage = null;
    notifyListeners();
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
