import 'dart:convert';

import 'package:flutter_quill/quill_delta.dart';

import '../document_format.dart';
import 'delta_lines.dart';
import 'document_adapter.dart';

/// Plain text (`.txt`) adapter.
///
/// Formatting is not part of the plain text format, so [parse] produces an
/// unstyled delta and [serialize] writes only the text content.
class PlainTextAdapter implements DocumentAdapter {
  const PlainTextAdapter();

  @override
  final DocumentFormat format = DocumentFormat.txt;

  @override
  Delta parse(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final delta = Delta();
    if (text.isEmpty || !text.endsWith('\n')) {
      delta.insert('$text\n');
    } else {
      delta.insert(text);
    }
    return delta;
  }

  @override
  List<int> serialize(Delta delta) {
    return utf8.encode(deltaToPlainText(delta));
  }
}
