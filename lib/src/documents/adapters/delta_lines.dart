import 'package:flutter_quill/quill_delta.dart';

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
  const DeltaLine(this.runs, [this.block = const {}]);

  /// The styled text runs of the line; empty for a blank line.
  final List<StyledText> runs;

  /// Block attributes of the line, e.g. `{'header': 2}` or
  /// `{'list': 'bullet'}`.
  final Map<String, dynamic> block;

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

  void closeLine(Map<String, dynamic> block) {
    lines.add(DeltaLine(List.unmodifiable(runs), block));
    runs = <StyledText>[];
  }

  for (final op in delta.operations) {
    final data = op.data;
    if (data is! String) continue;
    final attributes = op.attributes ?? const <String, dynamic>{};
    final segments = data.split('\n');
    for (var i = 0; i < segments.length; i++) {
      if (segments[i].isNotEmpty) {
        runs.add(StyledText(segments[i], attributes));
      }
      // Every '\n' in the data terminates a line. The block attributes of
      // the op carrying the newline are the line's block attributes in a
      // well-formed Quill delta.
      if (i < segments.length - 1) {
        closeLine(attributes);
      }
    }
  }

  // A delta without a trailing newline (or an empty delta) still yields at
  // least one line so the converted document is never empty.
  if (runs.isNotEmpty || lines.isEmpty) {
    closeLine(const {});
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
    for (final run in line.runs) {
      if (run.text.isEmpty) continue;
      delta.insert(
        run.text,
        run.attributes.isEmpty ? null : Map.of(run.attributes),
      );
    }
    delta.insert(
      '\n',
      line.block.isEmpty ? null : Map.of(line.block),
    );
  }
  return delta;
}

/// The plain text of a [delta] including line breaks.
String deltaToPlainText(Delta delta) {
  final lines = deltaToLines(delta);
  return lines.isEmpty ? '' : '${lines.map((l) => l.text).join('\n')}\n';
}
