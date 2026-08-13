import 'package:test/test.dart';
import 'package:wristload_tui/src/frontend/port/tui_snapshot.dart';
import 'package:wristload_tui/src/frontend/terminal/cell_width.dart';
import 'package:wristload_tui/src/frontend/views/diagnostic_log_panel.dart';

void main() {
  final entries = [
    TuiLogEntry(
      timestamp: DateTime(2026, 8, 13, 12),
      level: TuiLogLevel.info,
      category: TuiLogCategory.discovery,
      eventCode: 'discovery.scan.start',
      message: '开始扫描设备',
    ),
    TuiLogEntry(
      timestamp: DateTime(2026, 8, 13, 12, 0, 1),
      level: TuiLogLevel.error,
      category: TuiLogCategory.install,
      eventCode: 'install.failed',
      message: '安装失败',
    ),
  ];

  test('filters by severity and category with fixed visible dimensions', () {
    final lines = DiagnosticLogPanel(
      entries: entries,
      width: 48,
      height: 2,
      levels: const {TuiLogLevel.error},
      categories: const {TuiLogCategory.install},
      ansi: false,
    ).render();

    expect(lines, hasLength(2));
    expect(lines.first, contains('install.failed'));
    expect(lines.first, isNot(contains('扫描')));
    expect(lines.every((line) => CellWidth.of(line) == 48), isTrue);
  });

  test('supports no-color output and level color with reset', () {
    final colored = DiagnosticLogPanel(entries: entries, width: 64, height: 1).render();
    final plain = DiagnosticLogPanel(entries: entries, width: 64, height: 1, ansi: false).render();

    expect(colored.single, contains('\x1B[31m'));
    expect(colored.single, contains('\x1B[0m'));
    expect(plain.single, isNot(contains('\x1B[')));
    expect(CellWidth.of(colored.single), 64);
  });

  test('follows the tail or honors a clamped scroll offset', () {
    final tail = DiagnosticLogPanel(entries: entries, width: 64, height: 1, ansi: false).render();
    final head = DiagnosticLogPanel(entries: entries, width: 64, height: 1, followTail: false, scrollOffset: 0, ansi: false).render();

    expect(tail.single, contains('install.failed'));
    expect(head.single, contains('discovery.scan.start'));
  });

  test('renders a fixed-size empty state', () {
    final lines = DiagnosticLogPanel(entries: const [], width: 12, height: 3, ansi: false).render();
    expect(lines, hasLength(3));
    expect(lines.every((line) => CellWidth.of(line) == 12), isTrue);
  });
}
