import '../theme/ansi_text.dart';
import '../theme/tui_theme.dart';

/// Renders a simple text table with fixed columns. Column widths are given in
/// terminal cells. Values are truncated with ellipsis if too long.
class TableWidget {
  TableWidget({
    required this.columns,
    required this.rows,
    this.header = true,
    this.separator = ' ',
    this.supportsColor,
  });

  final List<TableColumn> columns;
  final List<List<String>> rows;
  final bool header;
  final String separator;
  final bool? supportsColor;

  List<String> render() {
    final out = <String>[];
    if (header) {
      out.add(_renderRow(columns.map((c) => c.title).toList(), isHeader: true));
      out.add(_renderDivider());
    }
    for (final row in rows) {
      out.add(_renderRow(row));
    }
    return out;
  }

  String _renderRow(List<String> values, {bool isHeader = false}) {
    final parts = <String>[];
    for (var i = 0; i < columns.length; i++) {
      final value = i < values.length ? values[i] : '';
      final col = columns[i];
      final styled = isHeader
          ? TuiTheme.paint(
              value,
              TuiTone.accent,
              bold: true,
              supportsColor: supportsColor,
            )
          : value;
      final fitted = AnsiText.fit(
        styled,
        col.width,
        right: col.align == TableAlign.right,
      );
      parts.add(fitted);
    }
    final divider = TuiTheme.muted(separator, supportsColor: supportsColor);
    return parts.join(divider);
  }

  String _renderDivider() {
    final parts = columns
        .map((c) => TuiTheme.paint(
              _repeat('─', c.width),
              TuiTone.muted,
              dim: true,
              supportsColor: supportsColor,
            ))
        .toList();
    return parts.join(TuiTheme.muted(separator, supportsColor: supportsColor));
  }
}

String _repeat(String value, int count) =>
    count <= 0 ? '' : List.filled(count, value).join();

class TableColumn {
  const TableColumn(this.title, this.width, {this.align = TableAlign.left});

  final String title;
  final int width;
  final TableAlign align;
}

enum TableAlign { left, right }
