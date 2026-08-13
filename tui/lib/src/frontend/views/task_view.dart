import '../port/tui_snapshot.dart';
import '../state/app_state.dart';
import '../theme/tui_theme.dart';
import '../widgets/frame.dart';
import '../widgets/panel.dart';
import '../widgets/progress.dart';

/// Renders the current task / transfer / recovery view.
class TaskView {
  TaskView({
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
    final task = snapshot.activeTask;
    frame.addRow(SectionHeader(
      width: frame.width,
      eyebrow: 'TASK',
      title: '当前任务与传输',
      meta: task == null ? '空闲' : _stageLabel(task.stage),
      tone: task == null ? TuiTone.muted : _taskTone(task.stage),
      supportsColor: supportsColor,
    ).render());
    frame.addBlank();

    if (task == null) {
      frame.addRow(CalloutWidget(
        width: frame.width,
        label: '空闲',
        message: '没有正在执行的任务。',
        tone: TuiTone.muted,
        supportsColor: supportsColor,
      ).render());
    } else {
      _renderTask(task);
    }

    frame.addBlank();
    final recovery = snapshot.recovery;
    final recoveryLines = <String>[
      '状态: ${TuiTheme.paint(
        _recoveryLabel(recovery.state),
        _recoveryTone(recovery.state),
        bold: recovery.state == TuiRecoveryState.available ||
            recovery.state == TuiRecoveryState.failed,
        supportsColor: supportsColor,
      )}',
    ];
    if (recovery.fileName != null) {
      recoveryLines.add('文件: ${recovery.fileName}');
      recoveryLines.add('路径: ${recovery.literalPath ?? '-'}');
      recoveryLines.add('大小: ${_humanSize(recovery.fileSize ?? 0)}  │  '
          '最后确认片: ${recovery.lastAcknowledgedSegment ?? '-'}  │  '
          '阶段: ${recovery.phase ?? '-'}');
      if (recovery.message != null) {
        recoveryLines.add('说明: ${recovery.message}');
      }
    }
    if (recovery.message != null && recovery.fileName == null) {
      recoveryLines.add(recovery.message!);
    }
    frame.addRows(PanelWidget(
      width: frame.width,
      title: '恢复检查点',
      lines: recoveryLines,
      tone: _recoveryTone(recovery.state),
      supportsColor: supportsColor,
    ).render());
  }

  void _renderTask(TuiActiveTask task) {
    final target = task.targetDeviceName ?? '未知设备';
    final tone = _taskTone(task.stage);
    frame.addRows(PanelWidget(
      width: frame.width,
      title: '任务上下文',
      tone: tone,
      supportsColor: supportsColor,
      lines: [
        '目标设备: $target  │  类型: ${_kindLabel(task.kind)}',
        '文件: ${task.fileName}',
        '阶段: ${TuiTheme.paint(
          _stageLabel(task.stage),
          tone,
          bold: true,
          supportsColor: supportsColor,
        )}',
        '状态: ${task.message}',
      ],
    ).render());

    if (task.totalBytes != null && task.totalBytes! > 0) {
      frame.addBlank();
      frame.addRows(ProgressWidget(
        width: frame.width,
        confirmedBytes: task.confirmedBytes,
        queuedBytes: task.queuedBytes,
        totalBytes: task.totalBytes,
        stageLabel: _stageLabel(task.stage),
        tone: tone,
        supportsColor: supportsColor,
      ).render());
    } else {
      frame.addRow(TuiTheme.muted(
        '进度: 等待中…',
        supportsColor: supportsColor,
      ));
    }

    final stats = <String>[];
    if (task.bytesPerSecond != null && task.bytesPerSecond! > 0) {
      stats.add('瞬时 ${_humanSize(task.bytesPerSecond!.round())}/s');
    }
    if (task.averageBytesPerSecond != null && task.averageBytesPerSecond! > 0) {
      stats.add('平均 ${_humanSize(task.averageBytesPerSecond!.round())}/s');
    }
    if (task.elapsed != null) {
      stats.add('总耗时 ${_formatDuration(task.elapsed!)}');
    }
    if (task.transferElapsed != null) {
      stats.add('传输 ${_formatDuration(task.transferElapsed!)}');
    }
    if (task.currentSegment != null && task.totalSegments != null) {
      stats.add('片段 ${task.currentSegment}/${task.totalSegments}');
    }
    if (stats.isNotEmpty) {
      frame.addRow(TuiTheme.muted(
        stats.join('  │  '),
        supportsColor: supportsColor,
      ));
    }

    if (task.stage == TuiTaskStage.succeeded &&
        task.successVerifiedByDeviceBusinessEvent) {
      frame.addRow(CalloutWidget(
        width: frame.width,
        label: '设备确认',
        message: '设备业务完成事件已验证，安装成功。',
        tone: TuiTone.success,
        supportsColor: supportsColor,
      ).render());
    }

    if (task.stage == TuiTaskStage.succeeded &&
        !task.successVerifiedByDeviceBusinessEvent) {
      frame.addRow(CalloutWidget(
        width: frame.width,
        label: '结果未验证',
        message: '设备未返回业务完成事件，结果不可验证。',
        tone: TuiTone.warning,
        supportsColor: supportsColor,
      ).render());
    }
  }

  String _kindLabel(TuiQueueItemKind kind) => switch (kind) {
        TuiQueueItemKind.watchface => '表盘',
        TuiQueueItemKind.quickApp => '快应用',
      };

  String _stageLabel(TuiTaskStage stage) => switch (stage) {
        TuiTaskStage.validating => '校验中',
        TuiTaskStage.waitingForProtocol => '等待协议',
        TuiTaskStage.transferring => '传输中',
        TuiTaskStage.awaitingDevice => '等待设备安装结果',
        TuiTaskStage.succeeded => '安装成功',
        TuiTaskStage.failed => '安装失败',
        TuiTaskStage.cancelled => '已取消',
        TuiTaskStage.stateUnknown => '设备状态未知',
      };

  String _recoveryLabel(TuiRecoveryState state) => switch (state) {
        TuiRecoveryState.unchecked => '未检查',
        TuiRecoveryState.checking => '检查中',
        TuiRecoveryState.none => '无检查点',
        TuiRecoveryState.available => '可恢复',
        TuiRecoveryState.invalid => '无效',
        TuiRecoveryState.failed => '检查失败',
      };

  TuiTone _taskTone(TuiTaskStage stage) => switch (stage) {
        TuiTaskStage.succeeded => TuiTone.success,
        TuiTaskStage.failed => TuiTone.error,
        TuiTaskStage.cancelled || TuiTaskStage.stateUnknown => TuiTone.warning,
        TuiTaskStage.transferring => TuiTone.accent,
        TuiTaskStage.validating ||
        TuiTaskStage.waitingForProtocol ||
        TuiTaskStage.awaitingDevice =>
          TuiTone.info,
      };

  TuiTone _recoveryTone(TuiRecoveryState state) => switch (state) {
        TuiRecoveryState.available => TuiTone.success,
        TuiRecoveryState.invalid || TuiRecoveryState.failed => TuiTone.error,
        TuiRecoveryState.checking => TuiTone.info,
        TuiRecoveryState.unchecked || TuiRecoveryState.none => TuiTone.muted,
      };

  String _humanSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)}M';
  }

  String _formatDuration(Duration d) {
    final twoDigits = (int n) => n.toString().padLeft(2, '0');
    return '${twoDigits(d.inMinutes)}:${twoDigits(d.inSeconds.remainder(60))}';
  }
}
