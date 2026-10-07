import 'package:archive/archive.dart';
import 'package:document_editor/src/documents/adapters/delta_lines.dart';
import 'package:document_editor/src/documents/adapters/docx_adapter.dart';
import 'package:document_editor/src/documents/adapters/markdown_adapter.dart';
import 'package:document_editor/src/documents/adapters/plain_text_adapter.dart';
import 'package:document_editor/src/documents/document_format.dart';
import 'package:document_editor/src/documents/document_state.dart';
import 'package:document_editor/src/documents/table.dart';
import 'package:flutter_quill/quill_delta.dart' show Delta;
import 'package:flutter_test/flutter_test.dart';
import 'dart:io' show Directory, File;

/// Builds a document [Delta] from (text, inline-attributes, block-attributes)
/// lines so tests can express formatted content compactly.
Delta buildDelta(List<(String, Map<String, dynamic>, Map<String, dynamic>)> lines) {
  final delta = Delta();
  for (final (text, inline, block) in lines) {
    if (text.isNotEmpty) {
      delta.insert(text, inline.isEmpty ? null : Map.of(inline));
    }
    delta.insert('\n', block.isEmpty ? null : Map.of(block));
  }
  return delta;
}

/// The set of inline (non-block) attribute keys applied anywhere in [delta].
Set<String> inlineKeys(Delta delta) {
  final keys = <String>{};
  for (final op in delta.operations) {
    final attrs = op.attributes;
    if (attrs == null) continue;
    for (final e in attrs.entries) {
      if (e.key != 'header' && e.key != 'list' && e.key != 'blockquote') {
        keys.add(e.key);
      }
    }
  }
  return keys;
}

String plain(Delta delta) => deltaToPlainText(delta);

void main() {
  group('DocumentFormat.fromFileName', () {
    test('recognizes supported extensions', () {
      expect(DocumentFormat.fromFileName('a.txt'), DocumentFormat.txt);
      expect(DocumentFormat.fromFileName('a.TXT'), DocumentFormat.txt);
      expect(DocumentFormat.fromFileName('a.md'), DocumentFormat.markdown);
      expect(DocumentFormat.fromFileName('a.markdown'), DocumentFormat.markdown);
      expect(DocumentFormat.fromFileName('a.docx'), DocumentFormat.docx);
    });

    test('returns null for unknown extensions', () {
      expect(DocumentFormat.fromFileName('a.pdf'), isNull);
      expect(DocumentFormat.fromFileName('noext'), isNull);
    });
  });

  group('PlainTextAdapter', () {
    test('parses text and preserves it through serialize', () {
      const adapter = PlainTextAdapter();
      final delta = adapter.parse('hello\nworld'.codeUnits);
      expect(plain(delta), 'hello\nworld\n');
      expect(String.fromCharCodes(adapter.serialize(delta)), 'hello\nworld\n');
    });
  });

  group('MarkdownAdapter', () {
    test('parses inline formatting', () {
      const adapter = MarkdownAdapter();
      final delta = adapter.parse(
        'a **bold** and *italic* and <u>under</u> and ~~strike~~ end\n'.codeUnits,
      );
      expect(
        inlineKeys(delta),
        containsAll(<String>['bold', 'italic', 'underline', 'strike']),
      );
      expect(plain(delta), 'a bold and italic and under and strike end\n');
    });

    test('parses block structure (headers, lists)', () {
      const adapter = MarkdownAdapter();
      final delta =
          adapter.parse('# One\n\n- a\n- b\n\n1. x\n2. y\n'.codeUnits);
      final lines = deltaToLines(delta);
      expect(lines.first.block['header'], 1);
      expect(
        lines.where((l) => l.block['list'] == 'bullet').length,
        2,
      );
      expect(
        lines.where((l) => l.block['list'] == 'ordered').length,
        2,
      );
    });

    test('round-trips inline formatting (delta -> md -> delta)', () {
      const adapter = MarkdownAdapter();
      final source = buildDelta([
        ('Hello', {'bold': true}, const {}),
        ('world', {'italic': true}, const {}),
      ]);
      final md = String.fromCharCodes(adapter.serialize(source));
      final reparsed = adapter.parse(md.codeUnits);
      expect(inlineKeys(reparsed), containsAll(<String>['bold', 'italic']));
      expect(plain(reparsed), 'Hello\nworld\n');
    });
  });

  group('DocxAdapter', () {
    test('round-trips inline + block formatting (delta -> docx -> delta)', () {
      const adapter = DocxAdapter();
      final source = buildDelta([
        ('Title', const {}, {'header': 1}),
        ('bold text', {'bold': true}, const {}),
        ('italic strike', {'italic': true, 'strike': true}, const {}),
        ('bullet one', const {}, {'list': 'bullet'}),
        ('bullet two', const {}, {'list': 'bullet'}),
        ('ordered one', const {}, {'list': 'ordered'}),
        ('ordered two', const {}, {'list': 'ordered'}),
      ]);

      final reparsed = adapter.parse(adapter.serialize(source));
      expect(plain(reparsed), plain(source));

      final lines = deltaToLines(reparsed);
      expect(lines.first.block['header'], 1);
      expect(
        inlineKeys(reparsed),
        containsAll(<String>['bold', 'italic', 'strike']),
      );
      expect(lines.where((l) => l.block['list'] == 'bullet').length, 2);
      expect(lines.where((l) => l.block['list'] == 'ordered').length, 2);
    });

    test('parses a hand-crafted docx with a heading, bold run and ordered list',
        () {
      const adapter = DocxAdapter();
      final delta = adapter.parse(buildComplexDocx());
      final lines = deltaToLines(delta);

      // Heading detected from pStyle "Heading2".
      expect(lines.first.block['header'], 2);
      expect(lines.first.text, 'My Heading');

      // Bold run detected from <w:b/>.
      final boldLine = lines.firstWhere((l) => l.text == 'Bold and plain');
      expect(
        boldLine.runs.any(
          (r) => r.attributes['bold'] == true && r.text == 'Bold',
        ),
        isTrue,
      );

      // Ordered list detected from the numbering reference.
      expect(
        lines.any((l) => l.block['list'] == 'ordered' && l.text == 'First item'),
        isTrue,
      );
    });

    test('parses tables into table block embeds without losing content', () {
      const adapter = DocxAdapter();
      final delta = adapter.parse(buildTableDocx());
      final lines = deltaToLines(delta);

      expect(lines.first.text, 'Before the table');
      expect(lines.last.text, 'After the table');

      final table = lines.firstWhere((l) => l.table != null).table!;
      expect(table.rows.length, 2);
      expect(table.rows[0].map((c) => c.toPlainText()).toList(),
          ['Decision', 'Stakeholders', 'Why']);
      expect(
        table.rows[1].map((c) => c.toPlainText()).toList(),
        ['Pump offboarding owner', 'Marcus', 'Overdue'],
      );

      // Inline formatting inside cells is preserved.
      for (final cell in table.rows[0]) {
        expect(
          cell.toList()
              .where((op) => op.data is String && op.data != '\n')
              .every((op) => op.attributes?['bold'] == true),
          isTrue,
          reason: 'header cell should be bold',
        );
      }

      // Plain text exports flatten the table but keep all its content.
      expect(deltaToPlainText(delta), contains('Decision | Stakeholders | Why'));
      expect(deltaToPlainText(delta),
          contains('Pump offboarding owner | Marcus | Overdue'));
    });

    test('round-trips tables through docx serialization', () {
      const adapter = DocxAdapter();
      final parsed = adapter.parse(buildTableDocx());
      final bytes = adapter.serialize(parsed);
      final reparsed = adapter.parse(bytes);
      final table =
          deltaToLines(reparsed).firstWhere((l) => l.table != null).table!;

      expect(table.rows.length, 2);
      expect(
        table.rows[1].map((c) => c.toPlainText()).toList(),
        ['Pump offboarding owner', 'Marcus', 'Overdue'],
      );
    });

    test('throws FormatException for non-zip input', () {
      expect(
        () => const DocxAdapter().parse('not a zip at all'.codeUnits),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('MarkdownAdapter tables', () {
    test('round-trips GFM tables through table embeds', () {
      const adapter = MarkdownAdapter();
      const source = '''
Intro line.

| Name | Role |
| --- | --- |
| Alice | **Engineer** |
| Bob | Designer |

Closing line.
''';

      final parsed = adapter.parse(source.codeUnits);
      final lines = deltaToLines(parsed);
      expect(lines.first.text, 'Intro line.');
      expect(lines.last.text, 'Closing line.');

      final table = lines.firstWhere((l) => l.table != null).table!;
      expect(table.rows.length, 3);
      expect(table.rows[0].map((c) => c.toPlainText()).toList(),
          ['Name', 'Role']);
      expect(table.rows[1].map((c) => c.toPlainText()).toList(),
          ['Alice', 'Engineer']);

      // Header cells and bold cells keep their bold attribute.
      expect(
        table.rows[0].map((c) => c.toDeltaOpsBold()),
        everyElement(isTrue),
        reason: 'GFM header cells should be bold',
      );
      expect(table.rows[1][1].toDeltaOpsBold(), isTrue);

      final md = String.fromCharCodes(adapter.serialize(parsed));
      expect(md, contains('| **Name** | **Role** |'));
      expect(md, contains('| --- | --- |'));
      expect(md, contains('| Alice | **Engineer** |'));

      // Re-parsing the serialized markdown yields the same table.
      final reparsed = deltaToLines(adapter.parse(md.codeUnits));
      final table2 = reparsed.firstWhere((l) => l.table != null).table!;
      expect(table2.rows.length, 3);
      expect(table2.rows[1].map((c) => c.toPlainText()).toList(),
          ['Alice', 'Engineer']);
      expect(table2.rows[1][1].toDeltaOpsBold(), isTrue);
    });
  });

  group('cross-format round trip (txt -> md -> docx -> txt)', () {
    test('carries a docx table through a markdown conversion', () {
      const docx = DocxAdapter();
      const md = MarkdownAdapter();

      final viaMd = md.serialize(docx.parse(buildTableDocx()));
      final table =
          deltaToLines(md.parse(viaMd)).firstWhere((l) => l.table != null).table!;

      expect(table.rows.length, 2);
      expect(table.rows[0].map((c) => c.toPlainText()).toList(),
          ['Decision', 'Stakeholders', 'Why']);
    });

    test('preserves plain text content across all conversions', () {
      const txt = PlainTextAdapter();
      const md = MarkdownAdapter();
      const docx = DocxAdapter();

      final source = buildDelta([
        ('Hello world', const {}, const {}),
        ('This is line two.', const {}, const {}),
        ('Final line', const {}, const {}),
      ]);

      final mdBytes = md.serialize(txt.parse(txt.serialize(source)));
      final viaMd = md.parse(mdBytes);
      final viaDocx = docx.parse(docx.serialize(viaMd));
      final backToTxt = txt.serialize(viaDocx);

      expect(String.fromCharCodes(backToTxt), 'Hello world\nThis is line two.\nFinal line\n');
    });

    test('preserves bold through md and docx', () {
      const md = MarkdownAdapter();
      const docx = DocxAdapter();
      const txt = PlainTextAdapter();

      final source = buildDelta([('important', {'bold': true}, const {})]);

      final fromMd = md.parse(md.serialize(source));
      expect(inlineKeys(fromMd), contains('bold'));

      final fromDocx = docx.parse(docx.serialize(fromMd));
      expect(inlineKeys(fromDocx), contains('bold'));
      expect(String.fromCharCodes(txt.serialize(fromDocx)), 'important\n');
    });
  });

  group('DocumentState format handling', () {
    late DocumentState state;
    late Directory tmp;

    setUp(() {
      state = DocumentState();
      tmp = Directory.systemTemp.createTempSync('docfmt');
    });
    tearDown(() {
      state.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('open + save .md round trip', () async {
      final path = '${tmp.path}/doc.md';
      File(path).writeAsStringSync('# Title\n\nsome text\n');

      await state.openFile(path);
      expect(state.format, DocumentFormat.markdown);
      // The editor holds the parsed document, not the raw Markdown source:
      // the header is stored as a block attribute and the blank line is
      // collapsed away by the parser.
      expect(state.quill.document.toPlainText(), 'Title\nsome text\n');

      await state.save();
      expect(File(path).readAsStringSync(), contains('Title'));
    });

    test('saveAs converts txt to md preserving content', () async {
      final src = '${tmp.path}/a.txt';
      final dst = '${tmp.path}/a.md';
      File(src).writeAsStringSync('hello world\n');
      await state.openFile(src);
      expect(state.format, DocumentFormat.txt);

      await state.saveAs(dst);
      expect(state.format, DocumentFormat.markdown);
      expect(state.filePath, dst);
      expect(File(dst).readAsStringSync(), contains('hello world'));
      expect(state.dirty, isFalse);
    });

    test('saveAsWritten adopts an already-written file', () async {
      final src = '${tmp.path}/a.txt';
      File(src).writeAsStringSync('seed\n');
      await state.openFile(src);

      final dst = '${tmp.path}/b.docx';
      final bytes =
          const DocxAdapter().serialize(state.quill.document.toDelta());
      File(dst).writeAsBytesSync(bytes);

      await state.saveAsWritten(dst, DocumentFormat.docx);
      expect(state.format, DocumentFormat.docx);
      expect(state.filePath, dst);
      expect(state.dirty, isFalse);
    });
  });
}

/// Whether every text operation of a cell delta is bold.
extension on Delta {
  bool toDeltaOpsBold() => toList()
      .where((op) => op.data is String && op.data != '\n')
      .every((op) => op.attributes?['bold'] == true);
}

/// Builds a minimal .docx containing a two-row, three-cell table wrapped in
/// ordinary paragraphs, to exercise table flattening in [DocxAdapter.parse].
List<int> buildTableDocx() {
  final archive = Archive();
  const document = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
<w:p><w:r><w:t>Before the table</w:t></w:r></w:p>
<w:tbl>
<w:tr>
<w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Decision</w:t></w:r></w:p></w:tc>
<w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Stakeholders</w:t></w:r></w:p></w:tc>
<w:tc><w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Why</w:t></w:r></w:p></w:tc>
</w:tr>
<w:tr>
<w:tc><w:p><w:r><w:t>Pump offboarding owner</w:t></w:r></w:p></w:tc>
<w:tc><w:p><w:r><w:t>Marcus</w:t></w:r></w:p></w:tc>
<w:tc><w:p><w:r><w:t>Overdue</w:t></w:r></w:p></w:tc>
</w:tr>
</w:tbl>
<w:p><w:r><w:t>After the table</w:t></w:r></w:p>
<w:sectPr/>
</w:body>
</w:document>
''';
  archive.add(ArchiveFile.string('word/document.xml', document));
  return ZipEncoder().encodeBytes(archive);
}

/// Builds a small .docx entirely by hand (independent of the app's serializer)
/// containing a Heading2 paragraph, a bold run, and an ordered list item, so
/// that [DocxAdapter.parse] is exercised against realistic OOXML.
List<int> buildComplexDocx() {
  const contentTypes = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
</Types>
''';

  const rootRels = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
''';

  const docRels = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
</Relationships>
''';

  const styles = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
<w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/></w:style>
</w:styles>
''';

  const numbering = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:abstractNum w:abstractNumId="0">
<w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
</w:abstractNum>
<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
</w:numbering>
''';

  const document = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
<w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>My Heading</w:t></w:r></w:p>
<w:p><w:r><w:rPr><w:b/></w:rPr><w:t>Bold</w:t></w:r><w:r><w:t> and plain</w:t></w:r></w:p>
<w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>First item</w:t></w:r></w:p>
<w:sectPr/>
</w:body>
</w:document>
''';

  final archive = Archive()
    ..add(ArchiveFile.string('[Content_Types].xml', contentTypes))
    ..add(ArchiveFile.string('_rels/.rels', rootRels))
    ..add(ArchiveFile.string('word/_rels/document.xml.rels', docRels))
    ..add(ArchiveFile.string('word/styles.xml', styles))
    ..add(ArchiveFile.string('word/numbering.xml', numbering))
    ..add(ArchiveFile.string('word/document.xml', document));
  return ZipEncoder().encodeBytes(archive);
}
