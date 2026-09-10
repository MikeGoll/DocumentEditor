import 'package:path/path.dart' as p;

/// The storage formats supported by the document editor.
enum DocumentFormat {
  /// Plain text (`.txt`).
  txt('txt', 'Plain text'),

  /// Markdown (`.md`).
  markdown('md', 'Markdown'),

  /// Microsoft Word (`.docx`).
  docx('docx', 'Word document');

  const DocumentFormat(this.fileExtension, this.label);

  /// File extension (without the dot) used in file pickers.
  final String fileExtension;

  /// Human-readable name used in dialogs.
  final String label;

  /// Detects the document format from a file name or path.
  ///
  /// Returns `null` when the extension is not recognized; callers fall
  /// back to plain text so unknown files remain readable.
  static DocumentFormat? fromFileName(String fileName) {
    switch (p.extension(fileName).toLowerCase()) {
      case '.txt':
        return DocumentFormat.txt;
      case '.md':
      case '.markdown':
        return DocumentFormat.markdown;
      case '.docx':
        return DocumentFormat.docx;
      default:
        return null;
    }
  }
}
