import 'package:flutter_quill/quill_delta.dart';

import '../document_format.dart';
import 'docx_adapter.dart';
import 'markdown_adapter.dart';
import 'plain_text_adapter.dart';

/// Converts between a document's on-disk representation and the in-memory
/// Quill [Delta] used by the editor.
///
/// Each supported [DocumentFormat] has one adapter. Adapters preserve what
/// their format can express (e.g. plain text drops bold) and are built so
/// that round-trips through a more expressive format do not lose content.
abstract interface class DocumentAdapter {
  /// The storage format this adapter handles.
  DocumentFormat get format;

  /// Parses raw file [bytes] into a Quill [delta].
  ///
  /// Throws a [FormatException] when the bytes are not a valid document of
  /// this format.
  Delta parse(List<int> bytes);

  /// Serializes a Quill [delta] to raw file bytes.
  List<int> serialize(Delta delta);

  /// Returns the adapter handling [format].
  static DocumentAdapter forFormat(DocumentFormat format) =>
      switch (format) {
        DocumentFormat.txt => const PlainTextAdapter(),
        DocumentFormat.markdown => const MarkdownAdapter(),
        DocumentFormat.docx => const DocxAdapter(),
      };
}
