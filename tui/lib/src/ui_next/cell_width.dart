import 'package:characters/characters.dart';
import 'package:wcwidth/wcwidth.dart';

/// Unicode and ANSI aware terminal-cell measurement owned by the new TUI.
abstract final class UiCellWidth {
  static int of(String text) {
    var width = 0;
    for (final grapheme in stripAnsi(text).characters) {
      width += grapheme.wcwidth().clamp(0, 2).toInt();
    }
    return width;
  }

  /// Terminal width of the first grapheme. Wrapping uses this to reserve
  /// enough room for a double-cell CJK or emoji grapheme after indentation.
  static int firstGraphemeWidth(String text) {
    if (text.isEmpty) return 0;
    return text.characters.first.wcwidth().clamp(0, 2).toInt();
  }

  static String stripAnsi(String text) => text.replaceAll(_ansiEscape, '');

  /// Removes terminal controls from external labels before they are rendered.
  /// ANSI sequences still count as zero-width when measuring already-rendered
  /// text, but device names must never be able to inject terminal controls.
  static String sanitizeText(String text) {
    return stripAnsi(text)
        .replaceAll(_lineControls, ' ')
        .replaceAll(_remainingControls, '');
  }

  /// Returns the longest terminal-cell prefix and the exact source offset that
  /// was consumed. The offset avoids splitting CJK/emoji graphemes while a
  /// wrapped line advances through the original Dart string.
  static UiCellPrefix takePrefix(String text, int maxCells) {
    if (maxCells <= 0 || text.isEmpty) {
      return const UiCellPrefix('', 0);
    }
    final output = StringBuffer();
    var offset = 0;
    var cells = 0;
    while (offset < text.length) {
      final ansi = _ansiEscape.matchAsPrefix(text, offset);
      if (ansi != null) {
        output.write(ansi.group(0));
        offset = ansi.end;
        continue;
      }
      final grapheme = text.substring(offset).characters.first;
      final width = grapheme.wcwidth().clamp(0, 2).toInt();
      if (cells + width > maxCells) {
        // A double-width glyph cannot occupy a one-cell terminal. Replace it
        // in this physically impossible layout while still consuming the
        // complete source grapheme so wrapping always makes progress.
        if (cells == 0) {
          output.write('?');
          offset += grapheme.length;
        }
        break;
      }
      output.write(grapheme);
      offset += grapheme.length;
      cells += width;
    }
    return UiCellPrefix(output.toString(), offset);
  }

  static final _ansiEscape = RegExp(
    r'\x1B(?:\][^\x07\x1B]*(?:\x07|\x1B\\)|[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])',
  );
  static final _lineControls = RegExp(r'[\r\n\t]');
  static final _remainingControls =
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]');
}

/// A display-cell prefix paired with the consumed UTF-16 source offset.
final class UiCellPrefix {
  const UiCellPrefix(this.text, this.consumedCodeUnits);

  final String text;
  final int consumedCodeUnits;
}
