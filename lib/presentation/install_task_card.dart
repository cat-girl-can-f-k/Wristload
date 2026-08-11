import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../domain/install_task.dart';

/// Material 3 summary for one active or completed installation.
///
/// The grey layer is data submitted to RFCOMM; the primary-colour layer is
/// data confirmed by cumulative device ACKs. Animation is visual only and
/// never changes the protocol checkpoint.
class InstallTaskCard extends StatelessWidget {
  const InstallTaskCard({
    required this.task,
    required this.onCancel,
    required this.onCheck,
    required this.onRetry,
    super.key,
  });

  final InstallTask task;
  final Future<void> Function() onCancel;
  final Future<void> Function() onCheck;
  final Future<void> Function() onRetry;

  String _kilobytes(num bytes) => '${(bytes / 1024).toStringAsFixed(1)} KB';

  String _speed(double? bytesPerSecond) => bytesPerSecond == null
      ? '测速中…'
      : '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';

  String _stageLabel(InstallStage stage) => switch (stage) {
        InstallStage.idle => '待处理',
        InstallStage.validating => '校验中',
        InstallStage.waitingForProtocol => '等待协议',
        InstallStage.transferring => '传输中',
        InstallStage.awaitingDevice => '设备安装中',
        InstallStage.succeeded => '已完成',
        InstallStage.cancelled => '已取消',
        InstallStage.stateUnknown => '状态未知',
        InstallStage.failed => '安装失败',
      };

  String? _packageSummary() => switch (task.kind) {
        InstallKind.watchface when task.faceId != null =>
          'faceId：${task.faceId}',
        InstallKind.quickApp when task.packageName != null =>
          '包名：${task.packageName}${task.versionCode == null ? '' : ' · 版本：${task.versionCode}'}',
        _ => null,
      };

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(top: 12),
        child: ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(task.fileName),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(task.message),
              if (_packageSummary() case final summary?) ...[
                const SizedBox(height: 4),
                Text(summary),
              ],
              if (task.targetDeviceName case final target?)
                Text('目标设备：$target'),
              if (task.md5Hex case final digest?)
                Text(
                  'MD5：$digest',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                ),
              if ((task.totalBytes ?? 0) > 0) ...[
                const SizedBox(height: 8),
                _InstallProgressBar(
                  confirmedBytes: task.confirmedBytes ?? 0,
                  queuedBytes: task.queuedBytes ?? task.confirmedBytes ?? 0,
                  totalBytes: task.totalBytes!,
                ),
                const SizedBox(height: 4),
              ],
              if (task.currentSegment case final current?)
                Text(
                  '设备确认：片 $current/${task.totalSegments ?? '?'} · '
                  '${_kilobytes(task.confirmedBytes ?? 0)}/'
                  '${_kilobytes(task.totalBytes ?? 0)}'
                  '${(task.totalBytes ?? 0) > 0 ? ' · ${((task.confirmedBytes ?? 0) * 100 / task.totalBytes!).toStringAsFixed(1)}%' : ''}'
                  ' · ${_speed(task.bytesPerSecond)}'
                  '${task.queuedSegment != null ? '（已提交至 ${task.queuedSegment}/${task.totalSegments ?? '?'} 片）' : ''}',
                ),
            ],
          ),
          trailing: switch (task.stage) {
            InstallStage.waitingForProtocol ||
            InstallStage.transferring ||
            InstallStage.awaitingDevice =>
              TextButton(onPressed: onCancel, child: const Text('取消')),
            InstallStage.cancelled ||
            InstallStage.stateUnknown =>
              PopupMenuButton<String>(
                tooltip: '恢复操作',
                onSelected: (value) {
                  if (value == 'check') {
                    onCheck();
                  } else {
                    onRetry();
                  }
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'check', child: Text('重新连接并检查')),
                  PopupMenuItem(value: 'retry', child: Text('从头重试')),
                ],
              ),
            _ => Text(_stageLabel(task.stage)),
          },
        ),
      );
}

class _InstallProgressBar extends StatelessWidget {
  const _InstallProgressBar({
    required this.confirmedBytes,
    required this.queuedBytes,
    required this.totalBytes,
  });

  final int confirmedBytes;
  final int queuedBytes;
  final int totalBytes;

  @override
  Widget build(BuildContext context) {
    final confirmed = confirmedBytes.clamp(0, totalBytes) / totalBytes;
    final queued = queuedBytes.clamp(0, totalBytes) / totalBytes;
    final colors = Theme.of(context).colorScheme;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: queued),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (context, animatedQueued, child) =>
          TweenAnimationBuilder<double>(
        tween: Tween<double>(end: confirmed),
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
        builder: (context, animatedConfirmed, child) => SizedBox(
          height: 14,
          width: double.infinity,
          child: CustomPaint(
            painter: _InstallProgressPainter(
              confirmed: animatedConfirmed,
              queued: animatedQueued,
              confirmedColor: colors.primary,
              queuedColor: Colors.grey.shade400,
              trackColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _InstallProgressPainter extends CustomPainter {
  const _InstallProgressPainter({
    required this.confirmed,
    required this.queued,
    required this.confirmedColor,
    required this.queuedColor,
    required this.trackColor,
  });

  final double confirmed;
  final double queued;
  final Color confirmedColor;
  final Color queuedColor;
  final Color trackColor;

  @override
  void paint(Canvas canvas, Size size) {
    const trackWidth = 10.0;
    const queuedWidth = 8.0;
    const confirmedWidth = 6.0;
    final centerY = size.height / 2;
    const left = trackWidth / 2;
    final usableWidth = math.max(0.0, size.width - trackWidth);

    Paint line(Color color, double width) => Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(left, centerY),
      Offset(left + usableWidth, centerY),
      line(trackColor, trackWidth),
    );
    if (queued > 0) {
      canvas.drawLine(
        Offset(left, centerY),
        Offset(left + usableWidth * queued, centerY),
        line(queuedColor, queuedWidth),
      );
    }
    if (confirmed > 0) {
      canvas.drawLine(
        Offset(left, centerY),
        Offset(left + usableWidth * confirmed, centerY),
        line(confirmedColor, confirmedWidth),
      );
    }
  }

  @override
  bool shouldRepaint(_InstallProgressPainter oldDelegate) =>
      oldDelegate.confirmed != confirmed ||
      oldDelegate.queued != queued ||
      oldDelegate.confirmedColor != confirmedColor ||
      oldDelegate.queuedColor != queuedColor ||
      oldDelegate.trackColor != trackColor;
}
