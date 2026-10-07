import 'dart:convert';

import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

/// Convenience: the concatenated text of a delta's string operations.
extension DeltaPlainText on Delta {
  String toPlainText() {
    final sb = StringBuffer();
    for (final op in toList()) {
      final data = op.data;
      if (data is String) sb.write(data);
    }
    return sb.toString();
  }
}

/// A table as a grid of cells.
///
/// Each cell is a [Delta] so that inline formatting (bold, italic, ...) and
/// several paragraphs per cell survive the round trip through the adapters.
///
/// Tables live in the Quill document as a custom block embed
/// ([TableEmbed]); this model is the JSON payload of that embed and is
/// shared by the format adapters and the editor's embed builder.
class TableData {
  const TableData(this.rows);

  /// One entry per table row; each row is one entry per cell.
  final List<List<Delta>> rows;

  int get columnCount => rows.fold(0, (m, r) => r.length > m ? r.length : m);

  bool get isEmpty =>
      rows.every((row) => row.every((cell) => cell.toPlainText().isEmpty));

  /// JSON representation: `{'rows': [[cellOps, ...], ...]}` where each cell
  /// is the JSON list of operations of its [Delta].
  Map<String, dynamic> toJson() => {
        'rows': [
          for (final row in rows)
            [for (final cell in row) cell.toJson()],
        ],
      };

  factory TableData.fromJson(Map<String, dynamic> json) {
    final rowsJson = json['rows'];
    if (rowsJson is! List) {
      throw const FormatException('Table data is missing "rows"');
    }
    return TableData(
      [
        for (final rowJson in rowsJson)
          if (rowJson is List)
            [
              for (final cellJson in rowJson)
                if (cellJson is List) Delta.fromJson(cellJson),
            ],
      ],
    );
  }
}

/// The custom block embed carrying a [TableData] in the Quill document.
///
/// In the serialized delta the embed appears as
/// `{'custom': '{"table": <TableData JSON>}'}` (see [BlockEmbed.custom]);
/// the editor rewrites such nodes back to type `'table'` before asking the
/// `embedBuilders` for a widget.
class TableEmbed extends CustomBlockEmbed {
  TableEmbed(TableData table)
      : super(tableType, jsonEncode({'table': table.toJson()}));

  /// The embed type / builder key of a table.
  static const String tableType = 'table';

  /// Decodes the raw data map of an embed insert operation (the delta
  /// `insert` value, e.g. `{'custom': '...'}`) as a table, returning null
  /// for any other embed or malformed payload so a broken table does not
  /// take down the whole document.
  ///
  /// Handles both payload shapes:
  ///  - `{'table': '<json>'}` as produced by [tryParse], and
  ///  - `{'custom': '<json>'}` from a serialized delta op, where the inner
  ///    payload is the embed's own JSON and therefore decoded once more.
  static TableData? tryParseOp(dynamic data) {
    if (data is! Map || data.length != 1) return null;
    final key = data.keys.single;
    if (key != BlockEmbed.customType && key != tableType) return null;
    final payload = data[key];
    if (payload is! String) return null;
    try {
      var tableJson = jsonDecode(payload);
      if (tableJson is! Map) return null;
      dynamic cell = tableJson[tableType];
      if (cell is String) {
        // Double-encoded op data: the value is the embed payload itself.
        cell = jsonDecode(cell);
        if (cell is Map) cell = cell[tableType];
      }
      if (cell is! Map<String, dynamic>) return null;
      final table = TableData.fromJson(cell);
      return table.isEmpty ? null : table;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  /// Decodes the data payload of an embed node (after the editor has
  /// rewritten `'custom'` nodes to their inner type) as a table, or null
  /// when [embed] is not a table embed.
  static TableData? tryParse(Embeddable embed) {
    if (embed.type != tableType || embed is! CustomBlockEmbed) return null;
    return tryParseOp({tableType: embed.data});
  }
}
