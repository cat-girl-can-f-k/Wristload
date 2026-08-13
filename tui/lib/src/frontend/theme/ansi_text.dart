import 'package:characters/characters.dart';

import '../terminal/cell_width.dart';
import 'tui_theme.dart';

/// ANSI-aware fitting helpers. [CellWidth.of] already ignores escape
/// sequences, while these methods also preserve them when truncating.
abstract final class AnsiText {
  static final _escape = RegExp(
    r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])',
  );

  static bool containsAnsi(String text) => _escape.hasMatch(text);

  static String strip(String text) => text.replaceAll(_escape, '');

  static String truncate(
    String text,
    int maxWidth, {
    String ellipsis = '…',
  }) {
    if (maxWidth <= 0) return '';
    if (CellWidth.of(text) <= maxWidth) return text;

    final ellipsisWidth = CellWidth.of(ellipsis);
    final target = maxWidth - ellipsisWidth;
    if (target <= 0) return _plainTruncate(ellipsis, maxWidth);

    final out = StringBuffer();
    var offset = 0;
    var cells = 0;
    var sawAnsi = false;
    while (offset < text.length) {
      final escape = _escape.matchAsPrefix(text, offset);
      if (escape != null) {
        out.write(escape.group(0));
        offset = escape.end;
        sawAnsi = true;
        continue;
      }

      final grapheme = text.substring(offset).characters.first;
      final width = CellWidth.of(grapheme);
      if (cells + width > target) break;
      out.write(grapheme);
      cells += width;
      offset += grapheme.length;
    }
    out.write(ellipsis);
    if (sawAnsi) out.write(TuiTheme.reset);
    return out.toString();
  }

  static String fit(
    String text,
    int width, {
    String ellipsis = '…',
    bool right = false,
    bool center = false,
  }) {
    final fitted = truncate(text, width, ellipsis: ellipsis);
    final padding = width - CellWidth.of(fitted);
    if (padding <= 0) return fitted;
    if (right) return '${' ' * padding}$fitted';
    if (center) {
      final left = padding ~/ 2;
      return '${' ' * left}$fitted${' ' * (padding - left)}';
    }
    return '$fitted${' ' * padding}';
  }

  static String _plainTruncate(String text, int width) {
    final out = StringBuffer();
    var cells = 0;
    for (final grapheme in text.characters) {
      final graphemeWidth = CellWidth.of(grapheme);
      if (cells + graphemeWidth > width) break;
      out.write(grapheme);
      cells += graphemeWidth;
    }
    return out.toString();
  }
}
