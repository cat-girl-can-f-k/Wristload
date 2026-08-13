import 'package:characters/characters.dart';
import 'package:wcwidth/wcwidth.dart';

/// Terminal cell-width utilities. All layout code must use these helpers
/// instead of [String.length] so that CJK characters and combining marks are
/// measured correctly.
class CellWidth {
  const CellWidth._();

  /// Returns the number of terminal cells occupied by [text].
  ///
  /// Control characters and ANSI escape sequences are counted as 0.
  static int of(String text) {
    var width = 0;
    final clean = _stripAnsi(text);
    for (final ch in clean.characters) {
      width += ch.wcwidth().clamp(0, 2).toInt();
    }
    return width;
  }

  /// Returns [text] truncated or padded to exactly [width] cells. Ellipsis
  /// ([ellipsis]) is appended when truncating; its width is accounted for.
  static String fit(String text, int width, {String ellipsis = '…'}) {
    final cells = of(text);
    if (cells == width) return text;
    if (cells < width) return text + ' ' * (width - cells);
    final ellipsisWidth = of(ellipsis);
    final target = width - ellipsisWidth;
    if (target <= 0) return truncate(ellipsis, width, ellipsis: '');
    final buffer = StringBuffer();
    var current = 0;
    for (final ch in text.characters) {
      final w = ch.wcwidth();
      if (current + w > target) break;
      buffer.write(ch);
      current += w;
    }
    final fitted = '$buffer$ellipsis';
    final padding = (width - of(fitted)).clamp(0, width).toInt();
    return fitted + ' ' * padding;
  }

  /// Truncates [text] to fit within [maxWidth] cells, adding an ellipsis if
  /// truncated. If [maxWidth] is not positive, returns an empty string.
  static String truncate(String text, int maxWidth, {String ellipsis = '…'}) {
    if (maxWidth <= 0) return '';
    if (of(text) <= maxWidth) return text;
    return fit(text, maxWidth, ellipsis: ellipsis);
  }

  /// Strips ANSI escape sequences from [text].
  static String _stripAnsi(String text) {
    return text.replaceAll(_ansiEscape, '');
  }

  static final _ansiEscape = RegExp(
    r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])',
  );
}
