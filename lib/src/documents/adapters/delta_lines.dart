import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import '../table.dart';

/// A stretch of text sharing the same inline attributes (bold, italic, ...).
class StyledText {
  const StyledText(this.text, [this.attributes = const {}]);

  /// The raw text of the run.
  final String text;

  /// Inline attributes applying to [text], e.g. `{'bold': true}`.
  final Map<String, dynamic> attributes;
}

/// A single line of a Quill document: its styled runs plus the block
/// attributes (header, list, ...) attached to the line break.
class DeltaLine {
  const DeltaLine(this.runs, [this.block = const {}, this.table]);

  /// The styled text runs of the line; empty for a blank line.
  final List<StyledText> runs;

  /// Block attributes of the line, e.g. `{'header': 2}` or
  /// `{'list': 'bullet'}`.
  final Map<String, dynamic> block;

  /// The table carried by this line, when the line is a table block
  /// embed. A table line has no text runs of its own.
  final TableData? table;

  /// The plain text content of the line, without the line break.
  String get text => runs.map((run) => run.text).join();
}

/// Splits a Quill [delta] into its [DeltaLine]s.
///
/// Non-text inserts (embeds such as images) are dropped; format adapters
/// that cannot represent them still keep the surrounding text intact.
List<DeltaLine> deltaToLines(Delta delta) {
  final lines = <DeltaLine>[];
  var runs = <StyledText>[];

  // Table embeds belong to the line that the following newline closes.
  TableData? pendingTable;

  void closeLine(Map<String, dynamic> block, TableData? table) {
    lines.add(DeltaLine(List.unmodifiable(runs), block, table));
    runs = <StyledText>[];
    // The table (if any) belongs to the line just closed; later lines must
    // not inherit it.
    pendingTable = null;
  }

  for (final op in delta.operations) {
    final data = op.data;
    if (data is String) {
      final attributes = op.attributes ?? const <String, dynamic>{};
      final segments = data.split('\n');
      for (var i = 0; i < segments.length; i++) {
        if (segments[i].isNotEmpty) {
          runs.add(StyledText(segments[i], attributes));
        }
        // Every '\n' in the data terminates a line. The block attributes
        // of the op carrying the newline are the line's block attributes
        // in a well-formed Quill delta.
        if (i < segments.length - 1) {
          closeLine(attributes, pendingTable);
        }
      }
    } else if (data is Map && data.length == 1) {
      final table = TableEmbed.tryParseOp(data);
      if (table != null) {
        // A table is a block embed: it owns its line. Flush any text
        // accumulated on the current line before attaching the table.
        if (runs.isNotEmpty) closeLine(const {}, null);
        pendingTable = table;
      }
      // Other embeds (images, ...) cannot be represented in this model;
      // drop them and keep the surrounding text intact.
    }
  }

  // A delta without a trailing newline (or an empty delta) still yields at
  // least one line so the converted document is never empty.
  if (runs.isNotEmpty || pendingTable != null || lines.isEmpty) {
    closeLine(const {}, pendingTable);
  }
  return lines;
}

/// Builds a Quill [delta] from [lines], each of which becomes one document
/// line terminated by a newline (Quill documents always end with one).
Delta linesToDelta(List<DeltaLine> lines) {
  if (lines.isEmpty) {
    lines = const [DeltaLine([])];
  }
  final delta = Delta();
  for (final line in lines) {
    final table = line.table;
    if (table != null) {
      // Tables are stored as a custom block embed occupying the whole
      // line (see [TableEmbed]).
      delta.insert(BlockEmbed.custom(TableEmbed(table)).toJson());
    } else {
      for (final run in line.runs) {
        if (run.text.isEmpty) continue;
        delta.insert(
          run.text,
          run.attributes.isEmpty ? null : Map.of(run.attributes),
        );
      }
    }
    delta.insert(
      '\n',
      line.block.isEmpty ? null : Map.of(line.block),
    );
  }
  return delta;
}

/// The plain text of a [delta] including line breaks.
///
/// Table lines are flattened to one pipe-separated line per row so that
/// text exports never lose table content.
String deltaToPlainText(Delta delta) {
  final out = StringBuffer();
  for (final line in deltaToLines(delta)) {
    final table = line.table;
    if (table != null) {
      for (final row in table.rows) {
        out.writeln(row
            .map((cell) =>
                cell.toPlainText().replaceAll('\n', ' ').trim())
            .join(' | '));
      }
    } else {
      out.writeln(line.text);
    }
  }
  return out.toString();
}
