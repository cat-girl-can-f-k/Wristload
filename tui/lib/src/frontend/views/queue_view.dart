import '../port/tui_snapshot.dart';
import '../state/app_state.dart';
import '../theme/ansi_text.dart';
import '../theme/tui_theme.dart';
import '../widgets/frame.dart';
import '../widgets/input.dart';
import '../widgets/panel.dart';
import '../widgets/table.dart';

/// Renders the installation queue view.
class QueueView {
  QueueView({
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
    frame.addRow(SectionHeader(
      width: frame.width,
      eyebrow: 'QUEUE',
      title: '安装队列',
      meta: '${snapshot.queue.length} 项 · '
          '${snapshot.pendingDecisions.length} 待确认',
      supportsColor: supportsColor,
    ).render());
    frame.addBlank();

    if (snapshot.queue.isEmpty) {
      frame.addRow(CalloutWidget(
        width: frame.width,
        label: '队列为空',
        message: '按 i 导入文件路径。',
        tone: TuiTone.muted,
        supportsColor: supportsColor,
      ).render());
    } else {
      _renderQueueTable();
    }

    if (snapshot.pendingDecisions.isNotEmpty) {
      frame.addBlank();
      final activeId = state.activeDecisionId ?? _firstPendingId();
      final lines = <String>[];
      for (final d in snapshot.pendingDecisions) {
        final selected = d.decisionId == activeId;
        final tone = _decisionTone(d.severity);
        final tag = TuiTheme.badge(
          _decisionLabel(d.severity),
          tone,
          supportsColor: supportsColor,
        );
        final title = TuiTheme.paint(
          d.title,
          tone,
          bold: true,
          supportsColor: supportsColor,
        );
        final marker = selected
            ? TuiTheme.paint(
                '▶',
                TuiTone.accent,
                bold: true,
                supportsColor: supportsColor,
              )
            : ' ';
        lines.add('$marker $tag $title: ${d.message}');
      }
      frame.addRows(PanelWidget(
        width: frame.width,
        title: '待确认项 · ${snapshot.pendingDecisions.length}',
        lines: lines,
        tone: TuiTone.warning,
        supportsColor: supportsColor,
      ).render());
    }

    if (state.showImport) {
      frame.addBlank();
      frame.addRows(PanelWidget(
        width: frame.width,
        title: '导入文件',
        tone: TuiTone.accent,
        supportsColor: supportsColor,
        lines: [
          TuiTheme.muted(
            '粘贴一个或多个文件路径（每行一个）:',
            supportsColor: supportsColor,
          ),
          InputWidget(
          width: (frame.width - 4).clamp(0, frame.width).toInt(),
          label: '路径',
          value: state.importInput,
          hint: '/Users/用户/下载/xxx.bin',
          focused: true,
          supportsColor: supportsColor,
        ).render(),
        ],
      ).render());
    }
  }

  void _renderQueueTable() {
    final cols = [
      const TableColumn('#', 4, align: TableAlign.right),
      const TableColumn('类型', 8),
      const TableColumn('文件名', 24),
      const TableColumn('大小', 10, align: TableAlign.right),
      const TableColumn('阶段', 12),
      const TableColumn('原因', 0), // variable width, handled below
    ];

    final fixed =
        cols.take(cols.length - 1).fold<int>(0, (s, c) => s + c.width);
    final reasonWidth =
        (frame.width - fixed - (cols.length - 1)).clamp(8, 60).toInt();
    final adjusted = [
      ...cols.take(cols.length - 1),
      TableColumn('原因', reasonWidth),
    ];
    final tableWidth =
        adjusted.fold<int>(0, (sum, column) => sum + column.width) +
            adjusted.length -
            1;
    if (tableWidth > frame.width) {
      _renderCompactQueue();
      return;
    }

    final rows = <List<String>>[];
    for (var i = 0; i < snapshot.queue.length; i++) {
      final item = snapshot.queue[i];
      final selected = item.itemId == state.selectedQueueItemId;
      rows.add([
        selected
            ? TuiTheme.selected(
                '▶${i + 1}',
                supportsColor: supportsColor,
              )
            : ' ${i + 1}',
        _kindLabel(item.kind),
        item.fileName,
        _humanSize(item.fileSize),
        TuiTheme.paint(
          _stageLabel(item.stage),
          _stageTone(item.stage),
          bold: item.stage == TuiQueueItemStage.done ||
              item.stage == TuiQueueItemStage.failed,
          supportsColor: supportsColor,
        ),
        item.message ?? '',
      ]);
    }
    frame.addRows(TableWidget(
      columns: adjusted,
      rows: rows,
      supportsColor: supportsColor,
    ).render());
  }

  void _renderCompactQueue() {
    for (var i = 0; i < snapshot.queue.length; i++) {
      final item = snapshot.queue[i];
      final selected = item.itemId == state.selectedQueueItemId;
      final stage = TuiTheme.paint(
        _stageLabel(item.stage),
        _stageTone(item.stage),
        bold: item.stage == TuiQueueItemStage.done ||
            item.stage == TuiQueueItemStage.failed,
        supportsColor: supportsColor,
      );
      final line = '${selected ? '▶' : ' '} ${i + 1}. '
          '${_kindLabel(item.kind)} │ ${item.fileName} │ '
          '${_humanSize(item.fileSize)} │ $stage'
          '${item.message == null ? '' : ' │ ${item.message}'}';
      frame.addRow(selected
          ? TuiTheme.selected(line, supportsColor: supportsColor)
          : AnsiText.truncate(line, frame.width));
    }
  }

  String? _firstPendingId() => snapshot.pendingDecisions.isEmpty
      ? null
      : snapshot.pendingDecisions.first.decisionId;

  String _kindLabel(TuiQueueItemKind kind) => switch (kind) {
        TuiQueueItemKind.watchface => '表盘',
        TuiQueueItemKind.quickApp => '快应用',
      };

  String _stageLabel(TuiQueueItemStage stage) => switch (stage) {
        TuiQueueItemStage.waiting => '等待',
        TuiQueueItemStage.installing => '安装中',
        TuiQueueItemStage.done => '完成',
        TuiQueueItemStage.failed => '失败',
        TuiQueueItemStage.cancelled => '已取消',
        TuiQueueItemStage.stateUnknown => '状态未知',
      };

  TuiTone _stageTone(TuiQueueItemStage stage) => switch (stage) {
        TuiQueueItemStage.waiting => TuiTone.muted,
        TuiQueueItemStage.installing => TuiTone.accent,
        TuiQueueItemStage.done => TuiTone.success,
        TuiQueueItemStage.failed => TuiTone.error,
        TuiQueueItemStage.cancelled || TuiQueueItemStage.stateUnknown =>
          TuiTone.warning,
      };

  String _decisionLabel(TuiDecisionSeverity severity) => switch (severity) {
        TuiDecisionSeverity.info => '信息',
        TuiDecisionSeverity.warning => '警告',
        TuiDecisionSeverity.error => '错误',
      };

  TuiTone _decisionTone(TuiDecisionSeverity severity) => switch (severity) {
        TuiDecisionSeverity.info => TuiTone.info,
        TuiDecisionSeverity.warning => TuiTone.warning,
        TuiDecisionSeverity.error => TuiTone.error,
      };

  String _humanSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)}M';
  }
}
