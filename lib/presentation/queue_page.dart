import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../application/device_controller.dart';
import '../domain/install_metadata_reader.dart';
import '../domain/install_models.dart';
import '../domain/install_task.dart';

class QueuePage extends StatefulWidget {
  const QueuePage({required this.controller, super.key});

  final DeviceController controller;

  @override
  State<QueuePage> createState() => _QueuePageState();
}

class _QueuePageState extends State<QueuePage> {
  bool _dragging = false;
  int _dragFileCount = 0;

  DeviceController get controller => widget.controller;

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['bin', 'face', 'rpk'],
      allowMultiple: true,
    );
    if (!mounted || result == null) return;
    await _addPaths(result.files.map((file) => file.path).whereType<String>());
  }

  Future<void> _addPaths(Iterable<String> paths) async {
    final existing = controller.installQueue
        .map((entry) => File(entry.request.path).absolute.path.toLowerCase())
        .toSet();
    var added = 0;
    var duplicate = 0;
    var unsupported = 0;

    for (final sourcePath in paths) {
      final path = File(sourcePath).absolute.path;
      final normalized = path.toLowerCase();
      if (existing.contains(normalized)) {
        duplicate++;
        continue;
      }

      final extension = normalized.split('.').last;
      final kind = switch (extension) {
        'bin' || 'face' => InstallKind.watchface,
        'rpk' => InstallKind.quickApp,
        _ => null,
      };
      if (kind == null) {
        unsupported++;
        continue;
      }

      try {
        final metadata = await InstallMetadataReader().read(kind, path);
        controller.enqueue(
          InstallRequest(kind: kind, path: path, metadata: metadata),
        );
        existing.add(normalized);
        added++;
      } on Object catch (error) {
        controller.reportError('无法加入文件：$error');
      }
    }

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (unsupported > 0) {
      final colors = Theme.of(context).colorScheme;
      messenger.showSnackBar(
        SnackBar(
          backgroundColor: colors.error,
          content: Text(
            '仅支持 .bin / .face / .rpk 文件',
            style: TextStyle(color: colors.onError),
          ),
        ),
      );
    }
    if (duplicate > 0) {
      messenger.showSnackBar(
        SnackBar(content: Text('$duplicate 个文件已在队列中，已跳过')),
      );
    }
    if (added > 0) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('已加入 $added 个文件'),
          action: SnackBarAction(
            label: '开始安装',
            onPressed: controller.runQueue,
          ),
        ),
      );
    }
  }

  void _setDragging(bool value, [int fileCount = 0]) {
    if (!mounted || (_dragging == value && _dragFileCount == fileCount)) {
      return;
    }
    setState(() {
      _dragging = value;
      _dragFileCount = value ? fileCount : 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (details) => _setDragging(true, details.fileCount ?? 0),
      onDragExited: (_) => _setDragging(false),
      onDragDone: (details) {
        _setDragging(false);
        _addPaths(details.files.map((file) => file.path));
      },
      child: SafeArea(
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) {
                    final queue = controller.installQueue;
                    final total = queue.length;
                    final installing = controller.installingCount;
                    final hasCompleted = queue.any(
                      (entry) => entry.stage == QueueStage.done,
                    );
                    final hasStarted = queue.any(
                      (entry) => entry.stage != QueueStage.waiting,
                    );

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '安装队列 · $total 项${installing > 0 ? ' · $installing 项安装中' : ''}',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ),
                              if (total > 0) ...[
                                TextButton(
                                  onPressed: hasCompleted
                                      ? controller.clearCompletedQueue
                                      : null,
                                  child: const Text('清空已完成'),
                                ),
                                const SizedBox(width: 4),
                                FilledButton.tonalIcon(
                                  onPressed: _pickFiles,
                                  icon: const Icon(Icons.add),
                                  label: const Text('添加文件'),
                                ),
                                const SizedBox(width: 4),
                                FilledButton.icon(
                                  onPressed: controller.pendingCount > 0 &&
                                          controller.sessionReady &&
                                          !controller.installInProgress &&
                                          !controller.timeSyncInProgress &&
                                          !controller.statusRefreshInProgress
                                      ? controller.runQueue
                                      : null,
                                  icon: const Icon(Icons.play_arrow),
                                  label: Text(
                                    hasStarted ? '继续安装' : '开始安装',
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Expanded(
                          child: queue.isEmpty
                              ? _EmptyQueue(
                                  onPick: _pickFiles,
                                  active: _dragging,
                                )
                              : ReorderableListView.builder(
                                  buildDefaultDragHandles: false,
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    0,
                                    16,
                                    16,
                                  ),
                                  onReorderItem: (oldIndex, newIndex) =>
                                      controller.reorderQueue(
                                    oldIndex,
                                    newIndex.clamp(0, queue.length),
                                  ),
                                  itemCount: queue.length + 1,
                                  itemBuilder: (context, index) {
                                    if (index == queue.length) {
                                      return _AddMoreTile(
                                        key: const ValueKey('queue-add-more'),
                                        onPick: _pickFiles,
                                      );
                                    }
                                    final entry = queue[index];
                                    return _QueueTile(
                                      key: ObjectKey(entry),
                                      controller: controller,
                                      entry: entry,
                                      index: index,
                                    );
                                  },
                                ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            if (_dragging)
              Positioned.fill(
                child: _DropOverlay(fileCount: _dragFileCount),
              ),
          ],
        ),
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    required this.controller,
    required this.entry,
    required this.index,
    super.key,
  });

  final DeviceController controller;
  final QueueEntry entry;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final request = entry.request;
    final installing = entry.stage == QueueStage.installing;
    final typeLabel = request.kind == InstallKind.watchface ? '表盘' : '快应用';
    final subtitle = entry.stage == QueueStage.failed && entry.message != null
        ? '失败：${entry.message}'
        : '$typeLabel · ${_formatSize(request.metadata.fileSize)} · ${request.path}';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ReorderableDragStartListener(
              index: index,
              enabled: !installing,
              child: Icon(
                Icons.drag_indicator,
                color: installing
                    ? theme.disabledColor
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                request.kind == InstallKind.watchface
                    ? Icons.watch
                    : Icons.apps,
                size: 20,
              ),
            ),
          ],
        ),
        title: Text(
          request.metadata.fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _QueueStatus(controller: controller, entry: entry),
            IconButton(
              tooltip: '从队列移除',
              onPressed:
                  installing ? null : () => controller.removeQueueEntry(index),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).toStringAsFixed(1)} KB';
}

class _QueueStatus extends StatelessWidget {
  const _QueueStatus({required this.controller, required this.entry});

  final DeviceController controller;
  final QueueEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (entry.stage == QueueStage.installing) {
      final task = controller.latestTask;
      final total = task?.totalSegments ?? 0;
      final progress = total <= 0
          ? 0.0
          : ((task?.currentSegment ?? 0) / total).clamp(0.0, 1.0);
      return SizedBox(
        width: 96,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 2),
            Text('${(progress * 100).round()}%'),
          ],
        ),
      );
    }

    if (entry.stage == QueueStage.done) {
      return Tooltip(
        message: '已完成',
        child: Icon(
          Icons.check_circle,
          color: theme.colorScheme.primary,
        ),
      );
    }

    final failed = entry.stage == QueueStage.failed ||
        entry.stage == QueueStage.cancelled ||
        entry.stage == QueueStage.stateUnknown;
    return ActionChip(
      label: Text(failed ? '失败 · 重试' : '等待中'),
      backgroundColor: failed ? theme.colorScheme.errorContainer : null,
      onPressed: failed ? () => controller.retryQueueEntry(entry) : null,
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue({required this.onPick, required this.active});

  final VoidCallback onPick;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: _DashedDropArea(
        active: active,
        borderRadius: 18,
        child: InkWell(
          onTap: onPick,
          borderRadius: BorderRadius.circular(18),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 300),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.surfaceContainerHigh,
                    ),
                    child: Icon(
                      Icons.upload_file,
                      size: 38,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('队列为空', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(
                    '拖入 .bin / .face 表盘或 .rpk 快应用文件加入队列\n'
                    '文件将按顺序串行安装到已连接的设备',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: onPick,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('选择文件'),
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

class _AddMoreTile extends StatefulWidget {
  const _AddMoreTile({required this.onPick, super.key});

  final VoidCallback onPick;

  @override
  State<_AddMoreTile> createState() => _AddMoreTileState();
}

class _AddMoreTileState extends State<_AddMoreTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = _hovered
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: _DashedDropArea(
          active: _hovered,
          borderRadius: 8,
          child: InkWell(
            onTap: widget.onPick,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 72),
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  Icon(Icons.add, color: foreground),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '添加更多文件',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: foreground,
                          ),
                        ),
                        Text(
                          '.bin / .face / .rpk，也可以直接拖入本页',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: foreground,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DropOverlay extends StatelessWidget {
  const _DropOverlay({required this.fileCount});

  final int fileCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IgnorePointer(
      child: ColoredBox(
        color: theme.colorScheme.surface.withValues(alpha: .86),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: _DashedDropArea(
            active: true,
            strokeWidth: 2,
            borderRadius: 18,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.upload_file,
                    size: 52,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text('松开以加入队列', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    fileCount > 0
                        ? '检测到 $fileCount 个文件 · 将按扩展名自动识别类型'
                        : '检测到文件 · 将按扩展名自动识别类型',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
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

class _DashedDropArea extends StatelessWidget {
  const _DashedDropArea({
    required this.child,
    required this.active,
    required this.borderRadius,
    this.strokeWidth = 1.5,
  });

  final Widget child;
  final bool active;
  final double borderRadius;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return CustomPaint(
      foregroundPainter: _DashedBorderPainter(
        color: active ? colors.primary : colors.outline,
        radius: borderRadius,
        strokeWidth: strokeWidth,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: active ? colors.primaryContainer.withValues(alpha: .18) : null,
          borderRadius: BorderRadius.circular(borderRadius),
        ),
        child: child,
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({
    required this.color,
    required this.radius,
    required this.strokeWidth,
  });

  final Color color;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          rect.deflate(strokeWidth / 2),
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
        canvas.drawPath(
          metric.extractPath(distance, distance + 8),
          paint,
        );
        distance += 13;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      color != oldDelegate.color ||
      radius != oldDelegate.radius ||
      strokeWidth != oldDelegate.strokeWidth;
}
