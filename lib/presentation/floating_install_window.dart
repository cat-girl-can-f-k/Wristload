import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../domain/floating_install_snapshot.dart';
import '../domain/install_task.dart';
import '../domain/queue_file_importer.dart';

typedef FloatingFilesDropped = FutureOr<void> Function(List<String> paths);

/// Compact view rendered by the secondary Flutter engine.
///
/// Queue ownership stays in the main engine. This widget only publishes user
/// actions and renders the transport-safe snapshot it receives.
class FloatingInstallWindow extends StatefulWidget {
  const FloatingInstallWindow({
    required this.snapshot,
    required this.onFilesDropped,
    required this.onOpenMainWindow,
    required this.onHideWindow,
    required this.onRetry,
    super.key,
  });

  final FloatingInstallSnapshot snapshot;
  final FloatingFilesDropped onFilesDropped;
  final VoidCallback onOpenMainWindow;
  final VoidCallback onHideWindow;
  final VoidCallback onRetry;

  @override
  State<FloatingInstallWindow> createState() => _FloatingInstallWindowState();
}

class _FloatingInstallWindowState extends State<FloatingInstallWindow> {
  static const _windowRadius = 12.0;
  bool _dragging = false;

  void _setDragging(bool dragging) {
    if (_dragging == dragging || !mounted) return;
    setState(() => _dragging = dragging);
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    _setDragging(false);
    final paths = details.files.map((file) => file.path).toList();
    final supported = paths
        .where((path) => QueueFileImporter.kindForPath(path) != null)
        .toList();
    final unsupportedCount = paths.length - supported.length;

    if (unsupportedCount > 0 && mounted) {
      final colors = Theme.of(context).colorScheme;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: colors.error,
          content: Text(
            '仅支持 .bin / .face / .rpk 文件',
            style: TextStyle(color: colors.onError),
          ),
        ),
      );
    }
    if (supported.isNotEmpty) {
      await widget.onFilesDropped(supported);
    }
  }

  void _handleBodyTap() {
    final snapshot = widget.snapshot;
    if (snapshot.phase == FloatingInstallPhase.failed && snapshot.canRetry) {
      widget.onRetry();
      return;
    }
    if (!snapshot.connected) widget.onOpenMainWindow();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background =
        _dragging ? colors.primaryContainer : colors.surfaceContainer;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DropTarget(
        onDragEntered: (_) => _setDragging(true),
        onDragExited: (_) => _setDragging(false),
        onDragDone: _handleDrop,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(_windowRadius),
          child: CustomPaint(
            foregroundPainter: _dragging
                ? _DashedWindowBorderPainter(
                    color: colors.primary,
                    radius: _windowRadius,
                  )
                : null,
            child: ColoredBox(
              color: background,
              child: Column(
                children: [
                  _WindowHeader(
                    onOpenMainWindow: widget.onOpenMainWindow,
                    onHideWindow: widget.onHideWindow,
                  ),
                  Expanded(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _handleBodyTap,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
                          child: _dragging
                              ? const _DragOverContent()
                              : _SnapshotContent(snapshot: widget.snapshot),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WindowHeader extends StatelessWidget {
  const _WindowHeader({
    required this.onOpenMainWindow,
    required this.onHideWindow,
  });

  final VoidCallback onOpenMainWindow;
  final VoidCallback onHideWindow;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          const Expanded(
            child: DragToMoveArea(
              child: Padding(
                padding: EdgeInsets.only(left: 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Wristload',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ),
          ),
          _HeaderButton(
            icon: Icons.open_in_full,
            tooltip: '打开主窗口',
            onPressed: onOpenMainWindow,
          ),
          _HeaderButton(
            icon: Icons.close,
            tooltip: '隐藏到系统托盘',
            onPressed: onHideWindow,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: Icon(icon),
        iconSize: 16,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        style: IconButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(7),
          ),
        ),
      );
}

class _DragOverContent extends StatelessWidget {
  const _DragOverContent();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.upload_file, size: 30, color: colors.primary),
          const SizedBox(height: 5),
          Text(
            '松开开始安装',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: colors.onPrimaryContainer,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _SnapshotContent extends StatelessWidget {
  const _SnapshotContent({required this.snapshot});

  final FloatingInstallSnapshot snapshot;

  @override
  Widget build(BuildContext context) => switch (snapshot.phase) {
        FloatingInstallPhase.idle => _IdleContent(snapshot: snapshot),
        FloatingInstallPhase.installing =>
          _InstallingContent(snapshot: snapshot),
        FloatingInstallPhase.done => _ResultContent(
            icon: Icons.check_circle,
            title: '安装成功',
            fileName: snapshot.fileName,
            color: Theme.of(context).colorScheme.primary,
          ),
        FloatingInstallPhase.failed => _ResultContent(
            icon: Icons.error,
            title: snapshot.canRetry ? '安装失败 · 点击重试' : '安装失败',
            fileName: snapshot.message ?? snapshot.fileName,
            color: Theme.of(context).colorScheme.error,
          ),
      };
}

class _IdleContent extends StatelessWidget {
  const _IdleContent({required this.snapshot});

  final FloatingInstallSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final deviceName = snapshot.deviceName.trim().isEmpty
        ? (snapshot.connected ? '已连接设备' : '设备未连接')
        : snapshot.deviceName;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: snapshot.connected ? colors.primary : colors.error,
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                deviceName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
        ),
        const Spacer(),
        Icon(Icons.upload_file, color: colors.primary, size: 30),
        const SizedBox(height: 2),
        Text(
          snapshot.connected ? '拖入文件即安装' : '点击连接设备',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 1),
        Text(
          '支持 .bin / .face / .rpk',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontSize: 10,
              ),
        ),
      ],
    );
  }
}

class _InstallingContent extends StatelessWidget {
  const _InstallingContent({required this.snapshot});

  final FloatingInstallSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final percent = (snapshot.progress * 100).clamp(0, 100).round();
    final queueText = snapshot.queueLength > 1 && snapshot.queuePosition != null
        ? ' · 队列 ${snapshot.queuePosition}/${snapshot.queueLength}'
        : '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                snapshot.kind == InstallKind.quickApp
                    ? Icons.apps
                    : Icons.watch,
                size: 18,
                color: colors.primary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                snapshot.fileName ?? '正在安装',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$percent%',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
        const Spacer(),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: snapshot.progress,
            minHeight: 4,
            backgroundColor: colors.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 7),
        Text(
          '${_formatSpeed(snapshot.bytesPerSecond)}$queueText',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                fontSize: 10,
              ),
        ),
      ],
    );
  }
}

class _ResultContent extends StatelessWidget {
  const _ResultContent({
    required this.icon,
    required this.title,
    required this.fileName,
    required this.color,
  });

  final IconData icon;
  final String title;
  final String? fileName;
  final Color color;

  @override
  Widget build(BuildContext context) => Center(
        child: Row(
          children: [
            Icon(icon, color: color, size: 34),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  if (fileName != null && fileName!.trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      fileName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}

String _formatSpeed(double? bytesPerSecond) {
  if (bytesPerSecond == null || bytesPerSecond <= 0) return '正在准备传输';
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
}

class _DashedWindowBorderPainter extends CustomPainter {
  const _DashedWindowBorderPainter({
    required this.color,
    required this.radius,
  });

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    const strokeWidth = 2.0;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(strokeWidth / 2),
          Radius.circular(radius),
        ),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(metric.extractPath(distance, distance + 7), paint);
        distance += 11;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedWindowBorderPainter oldDelegate) =>
      color != oldDelegate.color || radius != oldDelegate.radius;
}
