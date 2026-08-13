import '../terminal/cell_width.dart';
import '../theme/ansi_text.dart';
import '../theme/tui_theme.dart';

/// Renders a centered modal dialog box.
class DialogWidget {
  DialogWidget({
    required this.width,
    required this.title,
    required this.message,
    this.lines = const [],
    this.confirmLabel = '确认',
    this.cancelLabel = '取消',
    this.dangerous = false,
    this.focusConfirm = false,
    this.supportsColor,
  });

  final int width;
  final String title;
  final String message;
  final List<String> lines;
  final String confirmLabel;
  final String cancelLabel;
  final bool dangerous;
  final bool focusConfirm;
  final bool? supportsColor;

  static const int minWidth = 40;

  List<String> render() {
    final maxBoxWidth = (width - 4).clamp(4, width).toInt();
    final minBoxWidth = maxBoxWidth < minWidth ? maxBoxWidth : minWidth;
    final boxWidth = (width - 8).clamp(minBoxWidth, maxBoxWidth).toInt();
    final inner = boxWidth - 4;
    final out = <String>[];

    String hLine(String left, String fill, String right) {
      final tone = dangerous ? TuiTone.warning : TuiTone.muted;
      return TuiTheme.paint(
            left + fill * (boxWidth - 2) + right,
            tone,
            supportsColor: supportsColor,
          );
    }

    out.add(hLine('┌', '─', '┐'));
    out.add(_padLine(
      TuiTheme.paint(
        AnsiText.truncate(title, inner),
        dangerous ? TuiTone.warning : TuiTone.accent,
        bold: true,
        supportsColor: supportsColor,
      ),
      inner,
    ));
    out.add(hLine('├', '─', '┤'));
    out.add(_padLine(AnsiText.truncate(message, inner), inner));
    for (final line in lines) {
      out.add(_padLine(AnsiText.truncate(' $line', inner), inner));
    }
    out.add(_padLine('', inner));

    final confirm = focusConfirm
        ? TuiTheme.selected('▶ $confirmLabel', supportsColor: supportsColor)
        : '  $confirmLabel';
    final cancel = focusConfirm
        ? '  $cancelLabel'
        : TuiTheme.selected('▶ $cancelLabel', supportsColor: supportsColor);
    final buttons = '$confirm    $cancel';
    out.add(_padLine(
      AnsiText.truncate(buttons, inner),
      inner,
      alignRight: true,
    ));
    out.add(hLine('└', '─', '┘'));
    return out;
  }

  String _padLine(String text, int inner, {bool alignRight = false}) {
    final pad = inner - CellWidth.of(text);
    if (alignRight) {
      return '│${' ' * pad}$text│';
    }
    return '│$text${' ' * pad}│';
  }
}
