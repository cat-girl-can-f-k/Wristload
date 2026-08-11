import 'package:flutter/material.dart';

import '../application/device_controller.dart';
import '../domain/install_models.dart';
import '../domain/install_task.dart';

/// 安装队列页：串行安装、拖拽排序、状态机。
class QueuePage extends StatelessWidget {
  const QueuePage({required this.controller, super.key});

  final DeviceController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final queue = controller.installQueue;
              final total = queue.length;
              final installing = controller.installingCount;
              final hasCompleted =
                  queue.any((entry) => entry.stage == QueueStage.done);
              final hasStarted =
                  queue.any((entry) => entry.stage != QueueStage.waiting);
              final installingLabel =
                  installing > 0 ? ' · $installing 项安装中' : '';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('安装队列',
                              style: Theme.of(context).textTheme.titleLarge),
                        ),
                        Text('$total 项$installingLabel',
                            style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(width: 12),
                        TextButton(
                          onPressed: hasCompleted
                              ? controller.clearCompletedQueue
                              : null,
                          child: const Text('清空已完成'),
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
                          label: Text(hasStarted ? '继续安装' : '开始安装'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: queue.isEmpty
                        ? const _EmptyQueue()
                        : ReorderableListView.builder(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            onReorderItem: controller.reorderQueue,
                            itemCount: queue.length,
                            itemBuilder: (context, index) {
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
    final isInstalling = entry.stage == QueueStage.installing;
    final canDrag = !isInstalling;

    final typeIcon =
        request.kind == InstallKind.watchface ? Icons.watch : Icons.apps;
    final typeLabel = request.kind == InstallKind.watchface ? '表盘' : '快应用';
    final sizeLabel = _formatSize(request.metadata.fileSize);

    String subtitle;
    if (entry.stage == QueueStage.failed && entry.message != null) {
      subtitle = '失败：${entry.message}';
    } else if (entry.stage == QueueStage.stateUnknown &&
        entry.message != null) {
      subtitle = '状态未知：${entry.message}';
    } else if (entry.stage == QueueStage.cancelled) {
      subtitle = '已取消，设备可能保留部分数据';
    } else {
      subtitle = '$typeLabel · $sizeLabel · ${request.path}';
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ReorderableDragStartListener(
              index: index,
              enabled: canDrag,
              child: Icon(
                Icons.drag_indicator,
                color: canDrag
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.disabledColor,
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(typeIcon, size: 20),
            ),
          ],
        ),
        title: Text(request.metadata.fileName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _QueueStatusIndicator(controller: controller, entry: entry),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '从队列移除',
              onPressed: isInstalling
                  ? null
                  : () => controller.removeQueueEntry(index),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
}

class _QueueStatusIndicator extends StatelessWidget {
  const _QueueStatusIndicator({required this.controller, required this.entry});

  final DeviceController controller;
  final QueueEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (entry.stage) {
      case QueueStage.waiting:
        return const _StatusChip(label: '等待中');
      case QueueStage.installing:
        return _InstallingIndicator(controller: controller);
      case QueueStage.done:
        return _StatusChip(
          label: '已完成',
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.onPrimary,
        );
      case QueueStage.failed:
        return _StatusChip(
          label: '失败 · 重试',
          backgroundColor: theme.colorScheme.errorContainer,
          foregroundColor: theme.colorScheme.onErrorContainer,
          onTap: () => controller.retryQueueEntry(entry),
        );
      case QueueStage.cancelled:
        return _StatusChip(
          label: '已取消 · 重试',
          onTap: () => controller.retryQueueEntry(entry),
        );
      case QueueStage.stateUnknown:
        return _StatusChip(
          label: '状态未知 · 重试',
          backgroundColor: theme.colorScheme.errorContainer,
          foregroundColor: theme.colorScheme.onErrorContainer,
          onTap: () => controller.retryQueueEntry(entry),
        );
    }
  }
}

class _InstallingIndicator extends StatelessWidget {
  const _InstallingIndicator({required this.controller});

  final DeviceController controller;

  @override
  Widget build(BuildContext context) {
    final task = controller.latestTask;
    final total = task?.totalSegments ?? 0;
    final done = task?.currentSegment ?? 0;
    final percent = total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return SizedBox(
      width: 96,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LinearProgressIndicator(value: percent),
          const SizedBox(height: 2),
          Text('${(percent * 100).toStringAsFixed(0)}%',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    this.backgroundColor,
    this.foregroundColor,
    this.onTap,
  });

  final String label;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final chip = ActionChip(
      label: Text(label),
      labelStyle: TextStyle(
        fontSize: 12,
        color:
            foregroundColor ?? Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      backgroundColor: backgroundColor ?? Colors.transparent,
      side: backgroundColor == null
          ? BorderSide(color: Theme.of(context).colorScheme.outline)
          : BorderSide.none,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      onPressed: onTap,
    );
    return chip;
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.queue, size: 64, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text('安装队列为空', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text('从首页选择文件加入队列',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
