import '../port/tui_snapshot.dart';
import '../terminal/cell_width.dart';

/// Stateless fixed-size renderer for structured diagnostic logs.
///
/// It deliberately renders existing [TuiLogEntry] values only. Sensitive-data
/// removal belongs at log construction time, before entries reach this panel.
class DiagnosticLogPanel {
  const DiagnosticLogPanel({
    required this.entries,
    required this.width,
    required this.height,
    this.levels,
    this.categories,
    this.followTail = true,
    this.scrollOffset = 0,
    this.ansi = true,
  });

  final Iterable<TuiLogEntry> entries;
  final int width;
  final int height;
  final Set<TuiLogLevel>? levels;
  final Set<TuiLogCategory>? categories;
  final bool followTail;
  final int scrollOffset;
  final bool ansi;

  List<String> render() {
    if (width <= 0 || height <= 0) return const [];
    final filtered = entries
        .where((entry) => levels == null || levels!.contains(entry.level))
        .where((entry) => categories == null || categories!.contains(entry.category))
        .toList(growable: false);
    if (filtered.isEmpty) {
      return List<String>.generate(
        height,
        (index) => CellWidth.fit(index == 0 ? '暂无诊断日志。' : '', width),
        growable: false,
      );
    }

    final maxOffset =
        (filtered.length - height).clamp(0, filtered.length).toInt();
    final offset = followTail
        ? maxOffset
        : scrollOffset.clamp(0, maxOffset).toInt();
    final end = (offset + height).clamp(offset, filtered.length).toInt();
    final lines = <String>[
      for (var index = offset; index < end; index++) _lineFor(filtered[index]),
    ];
    while (lines.length < height) {
      lines.add(CellWidth.fit('', width));
    }
    return List.unmodifiable(lines);
  }

  String _lineFor(TuiLogEntry entry) {
    final stamp = entry.timestamp.toLocal().toIso8601String().substring(11, 19);
    final level = _levelLabel(entry.level).padRight(7);
    final category = entry.category.name.padRight(14);
    final code = entry.eventCode == null ? '' : '[${entry.eventCode}] ';
    final raw = CellWidth.fit('$stamp $level $category $code${entry.message}', width);
    if (!ansi || raw.length < 16) return raw;
    final color = switch (entry.level) {
      TuiLogLevel.debug => '\x1B[90m',
      TuiLogLevel.info => '\x1B[36m',
      TuiLogLevel.warning => '\x1B[33m',
      TuiLogLevel.error => '\x1B[31m',
    };
    // The colored column is ASCII-only (the timestamp and level), so these
    // code-unit offsets cannot split a wide character.
    return '${raw.substring(0, 9)}$color${raw.substring(9, 16)}\x1B[0m${raw.substring(16)}';
  }

  String _levelLabel(TuiLogLevel level) => switch (level) {
        TuiLogLevel.debug => 'DEBUG',
        TuiLogLevel.info => 'INFO',
        TuiLogLevel.warning => 'WARN',
        TuiLogLevel.error => 'ERROR',
      };
}
