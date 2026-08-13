import '../terminal/cell_width.dart';
import '../theme/ansi_text.dart';
import '../theme/tui_theme.dart';

/// Renders a labeled input field with optional masking.
class InputWidget {
  InputWidget({
    required this.width,
    required this.label,
    required this.value,
    this.masked = false,
    this.focused = false,
    this.hint = '',
    this.supportsColor,
  });

  final int width;
  final String label;
  final String value;
  final bool masked;
  final bool focused;
  final String hint;
  final bool? supportsColor;

  String render() {
    final prefix = '$label: ';
    final prefixWidth = CellWidth.of(prefix);
    final cursorWidth = focused ? 1 : 0;
    final available =
        (width - prefixWidth - cursorWidth).clamp(0, width).toInt();
    final isHint = value.isEmpty;
    final rawDisplay = isHint ? hint : (masked ? '•' * value.length : value);
    final display = AnsiText.truncate(rawDisplay, available);
    final styledLabel = TuiTheme.paint(
      label,
      focused ? TuiTone.accent : TuiTone.neutral,
      bold: focused,
      supportsColor: supportsColor,
    );
    final styledDisplay = isHint
        ? TuiTheme.muted(display, supportsColor: supportsColor)
        : TuiTheme.paint(
            display,
            focused ? TuiTone.accent : TuiTone.neutral,
            supportsColor: supportsColor,
          );
    final cursor = focused
        ? TuiTheme.paint(
            '█',
            TuiTone.accent,
            bold: true,
            supportsColor: supportsColor,
          )
        : '';
    return AnsiText.truncate('$styledLabel: $styledDisplay$cursor', width);
  }
}
