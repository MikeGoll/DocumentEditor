import 'dart:convert';

import 'package:flutter_quill/quill_delta.dart';
import 'package:markdown/markdown.dart' as md;

import '../document_format.dart';
import 'delta_lines.dart';
import 'document_adapter.dart';

/// Markdown (`.md`) adapter.
///
/// Parsing is delegated to the `markdown` package (GitHub-flavored); the
/// result is flattened into Quill lines carrying the inline attributes
/// bold, italic, underline and strike, and the block attributes header,
/// list (bullet/ordered), blockquote and code block.
///
/// Serialization emits a safe Markdown subset. Text is escaped so that
/// round-trips (md -> delta -> md) are stable:
///  - Markdown special characters are backslash-escaped,
///  - `&`, `<` and `>` are written as HTML entities,
///  - underline (not part of standard Markdown) uses the HTML `<u>` tag.
class MarkdownAdapter implements DocumentAdapter {
  const MarkdownAdapter();

  @override
  final DocumentFormat format = DocumentFormat.markdown;

  static final md.Document _parser = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  );

  /// Characters that are backslash-escaped in serialized text.
  static const String _backslashEscaped = r'\*_`[]()#!|~';

  @override
  Delta parse(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final lines = <DeltaLine>[];
    for (final node in _parser.parse(text)) {
      _visitBlock(node, lines);
    }
    return linesToDelta(lines);
  }

  @override
  List<int> serialize(Delta delta) {
    final out = StringBuffer();
    var orderedCounter = 0;
    var inCodeFence = false;

    for (final line in deltaToLines(delta)) {
      if (line.block['code-block'] == true) {
        if (!inCodeFence) {
          out.writeln('```');
          inCodeFence = true;
        }
        out.writeln(line.text);
        continue;
      }
      if (inCodeFence) {
        out.writeln('```');
        inCodeFence = false;
      }
      orderedCounter = 0;

      final content = _inline(line.runs);
      final headerLevel = line.block['header'];
      final listType = line.block['list'];
      if (headerLevel is int && headerLevel >= 1 && headerLevel <= 6) {
        out.writeln('#' * headerLevel + (content.isEmpty ? '' : ' ') + content);
      } else if (listType == 'bullet') {
        out.writeln('- $content');
      } else if (listType == 'ordered') {
        out.writeln('${++orderedCounter}. $content');
      } else if (line.block['blockquote'] == true) {
        out.writeln('> $content');
      } else {
        out.writeln(_guardLineStart(content));
      }
    }
    if (inCodeFence) {
      out.writeln('```');
    }
    return utf8.encode(out.toString());
  }

  /// Renders the styled runs of a line as inline Markdown.
  String _inline(List<StyledText> runs) {
    final out = StringBuffer();
    for (final run in runs) {
      if (run.text.isEmpty) continue;
      var text = _escape(run.text);
      final attrs = run.attributes;
      final bold = attrs['bold'] == true;
      final italic = attrs['italic'] == true;
      final strike = attrs['strike'] == true;
      if (bold && italic) {
        text = '***$text***';
      } else if (bold) {
        text = '**$text**';
      } else if (italic) {
        text = '*$text*';
      }
      if (strike) {
        text = '~~$text~~';
      }
      if (attrs['underline'] == true) {
        text = '<u>$text</u>';
      }
      out.write(text);
    }
    return out.toString();
  }

  /// Escapes a run of text so that it parses back as the same literal text.
  String _escape(String text) {
    final out = StringBuffer();
    for (final char in text.split('')) {
      switch (char) {
        case '&':
          out.write('&amp;');
        case '<':
          out.write('&lt;');
        case '>':
          out.write('&gt;');
        default:
          if (_backslashEscaped.contains(char)) {
            out.write('\\');
          }
          out.write(char);
      }
    }
    return out.toString();
  }

  /// Protects a plain (unprefixed) line from being re-parsed as a list,
  /// blockquote or other block by escaping its leading marker character.
  String _guardLineStart(String content) {
    if (content.isEmpty) return content;
    final first = content[0];
    if (first == '-' || first == '+') {
      return '\\$content';
    }
    if (first == '>') {
      return '&gt;${content.substring(1)}';
    }
    // "1. text" / "1) text" would parse as an ordered list.
    final marker = RegExp(r'^\d{1,9}[.)] ').firstMatch(content);
    if (marker != null) {
      return '${content[0]}\\${content.substring(1)}';
    }
    return content;
  }

  /// Visits one top-level Markdown block and appends its lines.
  void _visitBlock(md.Node node, List<DeltaLine> lines) {
    if (node is! md.Element) return;
    switch (node.tag) {
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final level = int.parse(node.tag.substring(1));
        _appendLines(
          _inlineToRuns(node.children ?? const []),
          lines,
          block: {'header': level},
        );
      case 'p':
        _appendLines(_inlineToRuns(node.children ?? const []), lines);
      case 'ul':
        _appendListItems(node, lines, 'bullet');
      case 'ol':
        _appendListItems(node, lines, 'ordered');
      case 'blockquote':
        var handled = false;
        for (final child in node.children ?? const <md.Node>[]) {
          if (child is md.Element && child.tag == 'p') {
            // Use the nested paragraph content so quote lines keep their
            // inline formatting.
            _appendLines(
              _inlineToRuns(child.children ?? const []),
              lines,
              block: {'blockquote': true},
            );
            handled = true;
          }
        }
        if (!handled && node.textContent.isNotEmpty) {
          _appendLines(
            [StyledText(node.textContent)],
            lines,
            block: {'blockquote': true},
          );
        }
      case 'pre':
        final code = node.textContent;
        if (code.trim().isNotEmpty) {
          for (final codeLine in code.split('\n')) {
            if (codeLine.isEmpty && codeLine == code.split('\n').last) continue;
            lines.add(
              DeltaLine([StyledText(codeLine)], {'code-block': true}),
            );
          }
        }
      case 'hr':
        // No Quill equivalent; skip.
      default:
        // Unknown blocks (tables, alerts, ...): keep their text.
        final children = node.children;
        if (children != null && children.isNotEmpty) {
          var visited = false;
          for (final child in children) {
            if (child is md.Element) {
              _visitBlock(child, lines);
              visited = true;
            }
          }
          if (!visited && node.textContent.isNotEmpty) {
            _appendLines([StyledText(node.textContent)], lines);
          }
        }
    }
  }

  void _appendListItems(md.Element list, List<DeltaLine> lines, String type) {
    final children = list.children;
    if (children == null) return;
    for (final child in children) {
      if (child is! md.Element || child.tag != 'li') continue;
      // Flatten the item (including nested lists) to its text.
      lines.add(DeltaLine([StyledText(child.textContent)], {'list': type}));
    }
  }

  /// Converts an inline node list into styled runs, tracking the HTML `<u>`
  /// markers that represent underline.
  List<StyledText> _inlineToRuns(List<md.Node> nodes) {
    final segments = <(String, Map<String, dynamic>)>[];
    void collect(List<md.Node> children, Map<String, dynamic> attrs) {
      for (final node in children) {
        if (node is md.Text) {
          segments.add((node.text, attrs));
        } else if (node is md.Element && node.children != null) {
          final childAttrs = Map<String, dynamic>.from(attrs);
          switch (node.tag) {
            case 'strong':
              childAttrs['bold'] = true;
            case 'em':
              childAttrs['italic'] = true;
            case 'del':
              childAttrs['strike'] = true;
          }
          collect(node.children!, childAttrs);
        }
      }
    }

    collect(nodes, const {});

    // Resolve `<u>` / `</u>` markers (passed through verbatim by the
    // Markdown parser) into underline attributes.
    final runs = <StyledText>[];
    var underline = false;
    void addRun(String text, Map<String, dynamic> attrs) {
      if (text.isEmpty) return;
      final merged = underline ? {...attrs, 'underline': true} : attrs;
      if (runs.isNotEmpty && _sameAttrs(runs.last.attributes, merged)) {
        runs.last = StyledText(runs.last.text + text, merged);
      } else {
        runs.add(StyledText(text, merged));
      }
    }

    for (final (text, attrs) in segments) {
      var rest = text;
      while (true) {
        final open = rest.indexOf('<u>');
        final close = rest.indexOf('</u>');
        if (close != -1 && (open == -1 || close < open)) {
          addRun(rest.substring(0, close), attrs);
          rest = rest.substring(close + 4);
          underline = false;
          continue;
        }
        if (open != -1) {
          addRun(rest.substring(0, open), attrs);
          rest = rest.substring(open + 3);
          underline = true;
          continue;
        }
        break;
      }
      addRun(rest, attrs);
    }
    return runs;
  }

  static bool _sameAttrs(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (a[key] != b[key]) return false;
    }
    return true;
  }

  /// Splits runs on soft line breaks and appends one [DeltaLine] per line.
  void _appendLines(
    List<StyledText> runs,
    List<DeltaLine> lines, {
    Map<String, dynamic> block = const {},
  }) {
    var lineRuns = <StyledText>[];
    void closeLine() {
      lines.add(DeltaLine(List.unmodifiable(lineRuns), block));
      lineRuns = <StyledText>[];
    }

    for (final run in runs) {
      final parts = run.text.split('\n');
      for (var i = 0; i < parts.length; i++) {
        if (parts[i].isNotEmpty) {
          lineRuns.add(StyledText(parts[i], run.attributes));
        }
        if (i < parts.length - 1) closeLine();
      }
    }
    if (lineRuns.isNotEmpty) {
      closeLine();
    } else {
      lines.add(DeltaLine(const [], block));
    }
  }
}
