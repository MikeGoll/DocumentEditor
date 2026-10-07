import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';

import '../documents/table.dart';

/// Renders table block embeds as real [Table] widgets inside the editor.
///
/// Cells are rendered as rich text (bold, italic, underline, strike) from
/// the cell deltas stored in the embed. Tables are not editable in place;
/// the whole table can be selected and deleted like any other block.
class TableEmbedBuilder extends EmbedBuilder {
  const TableEmbedBuilder();

  @override
  String get key => TableEmbed.tableType;

  @override
  String toPlainText(Embed node) {
    final table = TableEmbed.tryParse(node.value);
    if (table == null) return super.toPlainText(node);
    return table.rows
        .map((row) =>
            row.map((cell) => cell.toPlainText().replaceAll('\n', ' ')).join(' | '))
        .join('\n');
  }

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final table = TableEmbed.tryParse(embedContext.node.value);
    final theme = Theme.of(context);
    if (table == null) {
      return const SizedBox.shrink();
    }

    final columns = math.max(table.columnCount, 1);
    final borderColor = theme.colorScheme.outlineVariant;
    final headerBackground = theme.colorScheme.surfaceContainerHighest;

    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder.all(color: borderColor),
      children: [
        for (var r = 0; r < table.rows.length; r++)
          TableRow(
            decoration:
                r == 0 ? BoxDecoration(color: headerBackground) : null,
            children: [
              for (var c = 0; c < columns; c++)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: c < table.rows[r].length
                      ? Text.rich(
                          cellSpan(table.rows[r][c]),
                          style: embedContext.textStyle,
                        )
                      : const SizedBox.shrink(),
                ),
            ],
          ),
      ],
    );
  }

  /// Builds the [TextSpan] of a cell delta: inline attributes become text
  /// styles, newlines stay inside the cell.
  TextSpan cellSpan(Delta cellDelta) {
    final children = <InlineSpan>[];
    for (final op in cellDelta.toList()) {
      final data = op.data;
      if (data is! String) continue;
      final style = _runStyle(op.attributes);
      children.add(TextSpan(text: data, style: style));
    }
    if (children.isEmpty) {
      return const TextSpan(text: '');
    }
    return TextSpan(children: children);
  }

  TextStyle? _runStyle(Map<String, dynamic>? attributes) {
    if (attributes == null || attributes.isEmpty) return null;

    final decorations = <TextDecoration>[];
    if (attributes['underline'] == true) decorations.add(TextDecoration.underline);
    if (attributes['strike'] == true) {
      decorations.add(TextDecoration.lineThrough);
    }

    return TextStyle(
      fontWeight: attributes['bold'] == true ? FontWeight.bold : null,
      fontStyle: attributes['italic'] == true ? FontStyle.italic : null,
      decoration:
          decorations.isEmpty ? null : TextDecoration.combine(decorations),
    );
  }
}
