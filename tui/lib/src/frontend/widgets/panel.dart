import '../theme/ansi_text.dart';
import '../theme/tui_theme.dart';
import '../terminal/cell_width.dart';

/// Compact section chrome shared by all work views.
class SectionHeader {
  const SectionHeader({
    required this.width,
    required this.title,
    this.eyebrow,
    this.meta,
    this.tone = TuiTone.accent,
    this.supportsColor,
  });

  final int width;
  final String title;
  final String? eyebrow;
  final String? meta;
  final TuiTone tone;
  final bool? supportsColor;

  String render() {
    final prefix = eyebrow == null
        ? '━━ '
        : '━━ ${TuiTheme.paint(
            eyebrow!,
            TuiTone.muted,
            bold: true,
            supportsColor: supportsColor,
          )} / ';
    final heading = TuiTheme.paint(
      title,
      tone,
      bold: true,
      supportsColor: supportsColor,
    );
    final suffix = meta == null
        ? ''
        : '  ${TuiTheme.muted(meta!, supportsColor: supportsColor)}';
    return AnsiText.truncate('$prefix$heading$suffix', width);
  }
}

/// A restrained bordered panel for real grouped controls or state summaries.
class PanelWidget {
  const PanelWidget({
    required this.width,
    required this.title,
    required this.lines,
    this.tone = TuiTone.neutral,
    this.dense = true,
    this.supportsColor,
  });

  final int width;
  final String title;
  final List<String> lines;
  final TuiTone tone;
  final bool dense;
  final bool? supportsColor;

  List<String> render() {
    if (width < 8) {
      return [
        AnsiText.truncate(
          TuiTheme.paint(
            title,
            tone,
            bold: true,
            supportsColor: supportsColor,
          ),
          width,
        ),
        for (final line in lines) AnsiText.truncate(line, width),
      ];
    }

    final inner = width - 4;
    final titleText =
        ' ${TuiTheme.paint(
      title,
      tone,
      bold: true,
      supportsColor: supportsColor,
    )} ';
    final titleWidth = CellWidth.of(titleText);
    final fill = (width - titleWidth - 2).clamp(0, width).toInt();
    final vertical = _border('│');
    final top = '${_border('┌')}$titleText'
        '${_border(_repeat('─', fill))}${_border('┐')}';
    final bottom = '${_border('└')}'
        '${_border(_repeat('─', width - 2))}${_border('┘')}';
    final out = <String>[AnsiText.truncate(top, width)];
    if (!dense) out.add('$vertical${' ' * (width - 2)}$vertical');
    for (final line in lines) {
      out.add('$vertical ${AnsiText.fit(line, inner)} $vertical');
    }
    if (!dense) out.add('$vertical${' ' * (width - 2)}$vertical');
    out.add(bottom);
    return out;
  }

  String _border(String text) => TuiTheme.paint(
        text,
        tone,
        supportsColor: supportsColor,
      );
}

class CalloutWidget {
  const CalloutWidget({
    required this.width,
    required this.label,
    required this.message,
    this.tone = TuiTone.info,
    this.supportsColor,
  });

  final int width;
  final String label;
  final String message;
  final TuiTone tone;
  final bool? supportsColor;

  String render() {
    final marker = TuiTheme.paint(
      '▌',
      tone,
      bold: true,
      supportsColor: supportsColor,
    );
    final tag = TuiTheme.badge(
      label,
      tone,
      supportsColor: supportsColor,
    );
    return AnsiText.truncate('$marker $tag $message', width);
  }
}

String _repeat(String value, int count) =>
    count <= 0 ? '' : List.filled(count, value).join();
