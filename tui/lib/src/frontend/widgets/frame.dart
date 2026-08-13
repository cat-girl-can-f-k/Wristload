import '../terminal/cell_width.dart';
import '../theme/ansi_text.dart';

/// A simple row-based drawing target. Each row is built separately and the
/// final frame is joined with newlines. The frame guarantees that no row
/// exceeds [width] cells.
class Frame {
  Frame({required this.width, required this.height});

  final int width;
  final int height;
  final List<String> _rows = [];

  void addRow(String row, {String align = 'left'}) {
    if (_rows.length >= height) return;
    _rows.add(AnsiText.fit(
      row,
      width,
      right: align == 'right',
      center: align == 'center',
    ));
  }

  void addBlank() => addRow('');

  void addRows(List<String> rows) {
    for (final row in rows) {
      addRow(row);
    }
  }

  void addWrapped(String text, {int indent = 0}) {
    final available = width - indent;
    final words = text.split(' ');
    final buffer = StringBuffer();
    for (final word in words) {
      final next = buffer.isEmpty ? word : '${buffer.toString()} $word';
      if (CellWidth.of(next) > available) {
        if (buffer.isNotEmpty) {
          addRow(' ' * indent + buffer.toString());
          buffer.clear();
        }
        if (CellWidth.of(word) > available) {
          addRow(' ' * indent + AnsiText.truncate(word, available));
        } else {
          buffer.write(word);
        }
      } else {
        buffer.clear();
        buffer.write(next);
      }
    }
    if (buffer.isNotEmpty) {
      addRow(' ' * indent + buffer.toString());
    }
  }

  /// Returns the rendered frame as a single string ending with a newline.
  String render() {
    final out = StringBuffer();
    for (final row in _rows) {
      out.writeln(row);
    }
    // Fill remaining rows to clear old content.
    for (var i = _rows.length; i < height; i++) {
      out.writeln(' ' * width);
    }
    return out.toString();
  }

  List<String> get rows => List.unmodifiable(_rows);

  int get remaining => height - _rows.length;
}
