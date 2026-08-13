import '../port/tui_snapshot.dart';
import '../state/app_state.dart';
import '../theme/tui_theme.dart';
import '../widgets/frame.dart';
import '../widgets/panel.dart';
import 'diagnostic_log_panel.dart';

/// Renders the logs / diagnostics view.
class LogsView {
  LogsView({
    required this.snapshot,
    required this.state,
    required this.frame,
    this.supportsColor,
  });

  final TuiSnapshot snapshot;
  final AppState state;
  final Frame frame;
  final bool? supportsColor;

  void render() {
    final level = state.logsFilter?.name ?? '全部级别';
    final category = state.logsCategoryFilter?.name ?? '全部类别';
    frame.addRow(SectionHeader(
      width: frame.width,
      eyebrow: 'DIAGNOSTICS',
      title: '日志 / 诊断',
      meta: '${snapshot.logs.length} 条 · $level · $category',
      supportsColor: supportsColor,
    ).render());
    frame.addBlank();
    frame.addRow(TuiTheme.muted(
      'f 级别  t 类别  0 重置  l 跟随  PageUp/PageDown 滚动  e 导出',
      supportsColor: supportsColor,
    ));
    frame.addBlank();

    final height = (frame.remaining - 2).clamp(1, frame.height).toInt();
    final lines = DiagnosticLogPanel(
      entries: snapshot.logs,
      width: frame.width,
      height: height,
      levels: state.logsFilter == null ? null : {state.logsFilter!},
      categories: state.logsCategoryFilter == null
          ? null
          : {state.logsCategoryFilter!},
      followTail: state.logsFollowTail,
      scrollOffset: state.logsScrollOffset,
      ansi: TuiTheme.useColor(supportsColor),
    ).render();
    frame.addRows(PanelWidget(
      width: frame.width,
      title: state.logsFollowTail ? 'LIVE / FOLLOW' : 'PAUSED / SCROLL',
      lines: lines,
      tone: state.logsFollowTail ? TuiTone.success : TuiTone.warning,
      supportsColor: supportsColor,
    ).render());
  }
}
