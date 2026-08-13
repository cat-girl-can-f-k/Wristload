import '../theme/ansi_text.dart';
import '../theme/tui_theme.dart';

/// Renders a progress bar and associated statistics. Width is given in cells.
class ProgressWidget {
  ProgressWidget({
    required this.width,
    this.confirmedBytes,
    this.queuedBytes,
    this.totalBytes,
    this.message,
    this.stageLabel = '',
    this.tone = TuiTone.accent,
    this.supportsColor,
  });

  final int width;
  final int? confirmedBytes;
  final int? queuedBytes;
  final int? totalBytes;
  final String? message;
  final String stageLabel;
  final TuiTone tone;
  final bool? supportsColor;

  List<String> render() {
    final confirmed = confirmedBytes ?? 0;
    final total = totalBytes ?? 0;
    final percent =
        total > 0 ? (confirmed * 100 / total).round().clamp(0, 100).toInt() : 0;

    final maxBarWidth = (width - 28).clamp(0, 36).toInt();
    final barWidth = maxBarWidth < 10
        ? maxBarWidth
        : maxBarWidth.clamp(10, 36).toInt();
    final filled = barWidth > 0 ? (percent * barWidth / 100).round() : 0;
    final confirmedBar = TuiTheme.paint(
      _repeat('█', filled),
      tone,
      bold: true,
      supportsColor: supportsColor,
    );
    final pendingBar = TuiTheme.paint(
      _repeat('░', barWidth - filled),
      TuiTone.muted,
      dim: true,
      supportsColor: supportsColor,
    );
    final stage = TuiTheme.paint(
      stageLabel,
      tone,
      bold: true,
      supportsColor: supportsColor,
    );
    final percentage = TuiTheme.paint(
      '$percent%',
      tone,
      bold: true,
      supportsColor: supportsColor,
    );
    final totals = '${confirmed.toHumanBytes()}/${total.toHumanBytes()}';
    final line = '$stage $percentage [$confirmedBar$pendingBar] $totals';

    final out = <String>[
      AnsiText.truncate(line, width),
    ];
    if (message != null) {
      out.add(AnsiText.truncate(
        '  ${TuiTheme.paint(
          message!,
          tone,
          supportsColor: supportsColor,
        )}',
        width,
      ));
    }
    if (queuedBytes != null && total > 0) {
      out.add(AnsiText.truncate(
        '  ${TuiTheme.muted(
          '已提交等待确认: ${queuedBytes!.toHumanBytes()}',
          supportsColor: supportsColor,
        )}',
        width,
      ));
    }
    return out;
  }
}

String _repeat(String value, int count) =>
    count <= 0 ? '' : List.filled(count, value).join();

extension _BytesFormat on int {
  String toHumanBytes() {
    if (this < 1024) return '${this}B';
    if (this < 1024 * 1024) return '${(this / 1024).toStringAsFixed(1)}KB';
    return '${(this / (1024 * 1024)).toStringAsFixed(2)}MB';
  }
}
