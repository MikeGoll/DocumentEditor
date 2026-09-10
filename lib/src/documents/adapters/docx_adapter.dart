import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:xml/xml.dart';

import '../document_format.dart';
import 'delta_lines.dart';
import 'document_adapter.dart';

part 'docx_serialize.dart';

/// Microsoft Word (`.docx`) adapter.
///
/// A `.docx` file is a ZIP archive of XML parts. This adapter writes a
/// minimal but standards-compliant package (document, styles and numbering)
/// and reads any `.docx` by inspecting `word/document.xml`.
///
/// Supported round-trip formatting:
///  - inline: bold, italic, underline, strike
///  - block:  headings 1-6, bullet and ordered lists
///
/// Everything else is reduced to plain text so content is never lost.
class DocxAdapter implements DocumentAdapter {
  const DocxAdapter();

  @override
  final DocumentFormat format = DocumentFormat.docx;

  static const String _wordNs =
      'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  static const String _relsNs =
      'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
  static const String _packageNs =
      'http://schemas.openxmlformats.org/package/2006/relationships';
  static const String _contentTypesNs =
      'http://schemas.openxmlformats.org/package/2006/content-types';

  @override
  Delta parse(List<int> bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on ArchiveException catch (e) {
      throw FormatException('Not a valid .docx file: $e');
    }

    final document = _findFile(archive, 'word/document.xml');
    if (document == null) {
      throw const FormatException(
        'Not a .docx file: word/document.xml is missing',
      );
    }

    XmlDocument docXml;
    try {
      docXml = XmlDocument.parse(utf8.decode(document, allowMalformed: true));
    } on XmlException {
      throw const FormatException(
        'Not a .docx file: word/document.xml is not valid XML',
      );
    }

    final numbering = _findFile(archive, 'word/numbering.xml');
    final numIdToType = _parseNumbering(numbering);

    final lines = <DeltaLine>[];
    final root = docXml.rootElement;
    final body =
        root.findElements('body', namespaceUri: _wordNs).firstOrNull;
    for (final p in (body ?? root).findElements('p', namespaceUri: _wordNs)) {
      lines.add(_parseParagraph(p, numIdToType));
    }
    return linesToDelta(lines);
  }

  @override
  List<int> serialize(Delta delta) {
    final lines = deltaToLines(delta);
    final zip = Archive();
    zip.add(
      ArchiveFile.string('[Content_Types].xml', _contentTypesXml()),
    );
    zip.add(ArchiveFile.string('_rels/.rels', _rootRelsXml()));
    zip.add(
      ArchiveFile.string('word/_rels/document.xml.rels', _documentRelsXml()),
    );
    zip.add(ArchiveFile.string('word/styles.xml', _stylesXml()));
    zip.add(ArchiveFile.string('word/numbering.xml', _numberingXml()));
    zip.add(
      ArchiveFile.string('word/document.xml', _documentXml(lines)),
    );
    return ZipEncoder().encodeBytes(zip);
  }

  // ---------------------------------------------------------------------
  // Parsing
  // ---------------------------------------------------------------------

  List<int>? _findFile(Archive archive, String name) {
    for (final file in archive) {
      if (file.name == name && file.isFile) {
        return file.readBytes();
      }
    }
    return null;
  }

  /// Reads [name] from [el], preferring the wordprocessingml namespace.
  ///
  /// OOXML attributes are namespace-qualified (e.g. `w:val`), so a plain
  /// `getAttribute('val')` never matches; fall back to the unprefixed form
  /// for documents that omit the prefix.
  static String? _attr(XmlElement? el, String name) {
    if (el == null) return null;
    return el.getAttribute(name, namespaceUri: _wordNs) ??
        el.getAttribute(name);
  }

  /// Maps numbering ids to `'bullet'` / `'ordered'` for list detection.
  Map<int, String> _parseNumbering(List<int>? numberingBytes) {
    final result = <int, String>{};
    if (numberingBytes == null) return result;
    try {
      final doc = XmlDocument.parse(
        utf8.decode(numberingBytes, allowMalformed: true),
      );
      // abstractNumId -> list type of its level 0.
      final abstractFormats = <int, String>{};
      for (final abstract
          in doc.findAllElements('abstractNum', namespaceUri: _wordNs)) {
        final id = _attr(abstract, 'abstractNumId');
        if (id == null) continue;
        final lvls = abstract.findElements('lvl', namespaceUri: _wordNs);
        final lvl = lvls.firstWhere(
          (lvl) => _attr(lvl, 'ilvl') == '0',
          orElse: () => lvls.firstOrNull ?? lvls.first,
        );
        final fmt = _attr(
          lvl.findElements('numFmt', namespaceUri: _wordNs).firstOrNull,
          'val',
        );
        abstractFormats[int.parse(id)] =
            fmt == 'decimal' || fmt == 'lowerLetter' || fmt == 'upperLetter'
                ? 'ordered'
                : 'bullet';
      }
      for (final num in doc.findAllElements('num', namespaceUri: _wordNs)) {
        final numId = _attr(num, 'numId');
        final abstractRef = _attr(
          num.findElements('abstractNumId', namespaceUri: _wordNs).firstOrNull,
          'val',
        );
        if (numId == null || abstractRef == null) continue;
        final type = abstractFormats[int.parse(abstractRef)];
        if (type != null) result[int.parse(numId)] = type;
      }
    } on XmlException {
      // Ignore unreadable numbering info; lists default to bullet.
    }
    return result;
  }

  static final RegExp _headingStyle =
      RegExp(r'heading\s*([1-6])', caseSensitive: false);

  DeltaLine _parseParagraph(XmlElement p, Map<int, String> numIdToType) {
    var block = <String, dynamic>{};

    final pPr = p.findElements('pPr', namespaceUri: _wordNs).firstOrNull;
    if (pPr != null) {
      final style = _attr(
          pPr.findElements('pStyle', namespaceUri: _wordNs).firstOrNull,
          'val',
        );
      final headingMatch = _headingStyle.firstMatch(style ?? '');
      if (headingMatch != null) {
        block = {'header': int.parse(headingMatch.group(1)!)};
      }
      // w:numId is nested in w:numPr, so search recursively within pPr.
      final numId = _attr(
          pPr.findAllElements('numId', namespaceUri: _wordNs).firstOrNull,
          'val',
        );
      if (numId != null && block.isEmpty) {
        block = {'list': numIdToType[int.parse(numId)] ?? 'bullet'};
      }
    }

    final runs = <StyledText>[];
    void addRun(String text, Map<String, dynamic> attrs) {
      if (text.isEmpty) return;
      if (runs.isNotEmpty && _sameAttrs(runs.last.attributes, attrs)) {
        runs.last = StyledText(runs.last.text + text, attrs);
      } else {
        runs.add(StyledText(text, attrs));
      }
    }

    for (final r in _paragraphRuns(p)) {
      final attrs = _runAttributes(r);
      for (final t in r.findElements('t', namespaceUri: _wordNs)) {
        addRun(t.innerText, attrs);
      }
    }
    return DeltaLine(runs, block);
  }

  /// The runs of a paragraph, descending into hyperlinks, smart tags and
  /// revision insertions, but skipping deleted (tracked) content.
  List<XmlElement> _paragraphRuns(XmlElement p) {
    final runs = <XmlElement>[];
    void walk(XmlElement element) {
      for (final child in element.children.whereType<XmlElement>()) {
        switch (child.name.local) {
          case 'r':
            runs.add(child);
          case 'del':
            // Deleted (tracked) content: skip.
          case 'hyperlink':
          case 'smartTag':
          case 'ins':
          case 'sdt':
          case 'sdtContent':
          case 'fldSimple':
          case 'p':
            walk(child);
        }
      }
    }

    walk(p);
    return runs;
  }

  Map<String, dynamic> _runAttributes(XmlElement r) {
    final rPr = r.findElements('rPr', namespaceUri: _wordNs).firstOrNull;
    if (rPr == null) return const {};
    final attrs = <String, dynamic>{};

    bool present(String name) {
      final el = rPr.findElements(name, namespaceUri: _wordNs).firstOrNull;
      if (el == null) return false;
      // w:b w:val="0" / w:val="false" explicitly disable the property.
      final val = _attr(el, 'val');
      return val != '0' && val != 'false';
    }

    if (present('b')) attrs['bold'] = true;
    if (present('i')) attrs['italic'] = true;
    final u = rPr.findElements('u', namespaceUri: _wordNs).firstOrNull;
    final uVal = _attr(u, 'val') ?? 'single';
    if (u != null && uVal != 'none') {
      attrs['underline'] = true;
    }
    if (present('strike')) attrs['strike'] = true;
    return attrs;
  }

  static bool _sameAttrs(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }
}
