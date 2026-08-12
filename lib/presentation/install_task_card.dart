import 'package:flutter/material.dart';

import '../domain/install_task.dart';

class InstallTaskCard extends StatelessWidget {
  const InstallTaskCard({
    required this.task,
    required this.onCancel,
    required this.onRetry,
    this.onClear,
    super.key,
  });

  final InstallTask task;
  final Future<void> Function() onCancel;
  final Future<void> Function() onRetry;
  final VoidCallback? onClear;

  bool get _isDone => task.stage == InstallStage.succeeded;

  bool get _isFailure =>
      task.stage == InstallStage.failed ||
      task.stage == InstallStage.stateUnknown;

  bool get _canCancel =>
      task.stage == InstallStage.waitingForProtocol ||
      task.stage == InstallStage.validating ||
      task.stage == InstallStage.transferring;

  bool get _showProgress =>
      (task.stage == InstallStage.transferring ||
          task.stage == InstallStage.awaitingDevice) &&
      (task.totalBytes ?? 0) > 0;

  String _kilobytes(num bytes) => '${(bytes / 1024).toStringAsFixed(1)} KB';

  String _speed(double? value, {String unavailable = '测速中…'}) {
    if (value == null || !value.isFinite || value <= 0) return unavailable;
    final megabytesPerSecond = value / (1024 * 1024);
    return megabytesPerSecond >= 1
        ? '${megabytesPerSecond.toStringAsFixed(1)} MB/s'
        : '${(value / 1024).toStringAsFixed(1)} KB/s';
  }

  String _duration(Duration? value) {
    if (value == null) return '—';
    if (value < const Duration(seconds: 1)) return '< 1 秒';
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60);
    final seconds = value.inSeconds.remainder(60);
    if (hours > 0) return '$hours 小时 $minutes 分';
    if (minutes > 0) return '$minutes 分 $seconds 秒';
    return '$seconds 秒';
  }

  TextStyle _tabular(TextStyle? base) => (base ?? const TextStyle()).copyWith(
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  String _typeSummary() => switch (task.kind) {
        InstallKind.watchface => [
            '表盘',
            if (task.faceId case final faceId?) 'ID $faceId',
          ].join(' · '),
        InstallKind.quickApp => [
            '快应用',
            if (task.packageName case final packageName?) packageName,
            if (task.versionCode case final versionCode?) '版本：$versionCode',
          ].join(' · '),
      };

  IconData get _headerIcon {
    if (_isDone) return Icons.check_circle;
    if (_isFailure) return Icons.error;
    if (task.stage == InstallStage.cancelled) return Icons.cancel_outlined;
    return task.kind == InstallKind.watchface ? Icons.watch : Icons.apps;
  }

  String get _title => _isDone ? '${task.fileName} 安装完成' : task.fileName;

  String _subtitle() {
    if (_isDone) {
      return '用时 ${_duration(task.elapsed)} · '
          '平均速度 ${_speed(task.averageBytesPerSecond, unavailable: '—')}';
    }
    if (_isFailure) return task.message;
    return _typeSummary();
  }

  Duration? _eta(int confirmedBytes, int totalBytes) {
    final speed = task.bytesPerSecond;
    final elapsed = task.transferElapsed;
    if (task.stage != InstallStage.transferring ||
        speed == null ||
        !speed.isFinite ||
        speed <= 0 ||
        elapsed == null ||
        elapsed < const Duration(seconds: 2) ||
        confirmedBytes >= totalBytes) {
      return null;
    }
    return Duration(
      seconds: ((totalBytes - confirmedBytes) / speed).ceil(),
    );
  }

  Future<void> _confirmCancel(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('取消安装？'),
        content: const Text('取消后已传输分片作废'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('继续安装'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认取消'),
          ),
        ],
      ),
    );
    if (confirmed == true) await onCancel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final totalBytes = task.totalBytes ?? 0;
    final confirmedBytes = (task.confirmedBytes ?? 0).clamp(0, totalBytes);
    final submittedBytes =
        (task.queuedBytes ?? confirmedBytes).clamp(confirmedBytes, totalBytes);
    final percentage = totalBytes > 0 ? confirmedBytes * 100 / totalBytes : 0.0;
    final eta = _eta(confirmedBytes, totalBytes);
    final headerColor = _isFailure ? colors.error : colors.primary;

    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(_headerIcon, color: headerColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 2),
                      Tooltip(
                        message: _subtitle(),
                        child: Text(
                          _subtitle(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _tabular(theme.textTheme.bodySmall?.copyWith(
                            color: _isFailure
                                ? colors.error
                                : colors.onSurfaceVariant,
                          )),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                if (_canCancel)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _confirmCancel(context),
                    child: const Text('取消'),
                  )
                else if (_isDone && onClear != null)
                  TextButton(
                    onPressed: onClear,
                    child: const Text('清除'),
                  ),
              ],
            ),
            if (_showProgress) ...[
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${percentage.toStringAsFixed(1)}%',
                    style: _tabular(theme.textTheme.headlineLarge?.copyWith(
                      fontSize: 36,
                      fontWeight: FontWeight.w600,
                    )),
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _speed(task.bytesPerSecond),
                        style: _tabular(theme.textTheme.titleSmall),
                      ),
                      if (eta != null)
                        Text(
                          '预计剩余 ${_duration(eta)}',
                          style: _tabular(
                            theme.textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _InstallProgressBar(
                confirmedBytes: confirmedBytes,
                submittedBytes: submittedBytes,
                totalBytes: totalBytes,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '设备确认 ${task.currentSegment ?? 0}/'
                      '${task.totalSegments ?? '?'} 片 · '
                      '${_kilobytes(confirmedBytes)}/${_kilobytes(totalBytes)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _tabular(theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      )),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _ProgressLegend(
                    confirmedColor: colors.primary,
                    submittedColor: colors.primaryContainer,
                  ),
                ],
              ),
            ],
            if (!_showProgress && !_isDone && !_isFailure) ...[
              const SizedBox(height: 10),
              Text(
                task.message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              shape: const Border(),
              collapsedShape: const Border(),
              title: const Text('详情'),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    children: [
                      _DetailRow(
                        label: 'MD5',
                        value: SelectableText(
                          task.md5Hex ?? '—',
                          style: _tabular(theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          )),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _DetailRow(
                        label: '目标设备',
                        value: Text(
                          task.targetDeviceName ?? '—',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      const SizedBox(height: 6),
                      _DetailRow(
                        label: '已提交分片',
                        value: Text(
                          '${task.queuedSegment ?? task.currentSegment ?? 0}/'
                          '${task.totalSegments ?? '?'}',
                          style: _tabular(theme.textTheme.bodySmall),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _DetailRow(
                        label: '当前阶段',
                        value: Text(
                          task.stage.name,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_isFailure || task.stage == InstallStage.cancelled)
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('再次尝试安装'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InstallProgressBar extends StatelessWidget {
  const _InstallProgressBar({
    required this.confirmedBytes,
    required this.submittedBytes,
    required this.totalBytes,
  });

  final int confirmedBytes;
  final int submittedBytes;
  final int totalBytes;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final double confirmed = totalBytes > 0
        ? (confirmedBytes / totalBytes).clamp(0.0, 1.0).toDouble()
        : 0.0;
    final double submitted = totalBytes > 0
        ? (submittedBytes / totalBytes).clamp(confirmed, 1.0).toDouble()
        : 0.0;
    return Semantics(
      label: '安装进度',
      value: '${(confirmed * 100).toStringAsFixed(1)}%',
      child: SizedBox(
        height: 6,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Stack gives non-positioned children loose constraints. Calculate
            // explicit left-aligned widths so both progress sections always
            // paint against the full, finite track width.
            final trackWidth =
                constraints.hasBoundedWidth ? constraints.maxWidth : 0.0;
            return ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(
                      key: const ValueKey('install-progress-track'),
                      color: colors.surfaceContainerHighest,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: trackWidth * submitted,
                    child: ColoredBox(
                      key: const ValueKey('install-progress-submitted'),
                      color: colors.primaryContainer,
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: trackWidth * confirmed,
                    child: ColoredBox(
                      key: const ValueKey('install-progress-confirmed'),
                      color: colors.primary,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ProgressLegend extends StatelessWidget {
  const _ProgressLegend({
    required this.confirmedColor,
    required this.submittedColor,
  });

  final Color confirmedColor;
  final Color submittedColor;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _LegendItem(color: confirmedColor, label: '已确认'),
          const SizedBox(width: 10),
          _LegendItem(color: submittedColor, label: '已提交待确认'),
        ],
      );
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: value),
      ],
    );
  }
}
