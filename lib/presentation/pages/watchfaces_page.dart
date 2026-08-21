import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../application/device_controller.dart';
import '../../domain/watchface.dart';
import '../page_module.dart';

const wristloadPage = WristloadPageModule(
  id: 'watchfaces',
  route: '/watchfaces',
  label: '表盘',
  icon: Icons.watch_outlined,
  selectedIcon: Icons.watch,
  order: 25,
  build: _buildWatchfacesPage,
  supportedPlatforms: const <TargetPlatform>{TargetPlatform.macOS},
);

Widget _buildWatchfacesPage(WristloadPageContext context) =>
    WatchfacesPage(controller: context.controller);

/// Shows the watchfaces reported by the authenticated device.
///
/// The device remains the source of truth. This page does not infer installed
/// faces from local files because the duplicate-ID install path and valid
/// deletion permission both come from command=4/sub=0.
class WatchfacesPage extends StatefulWidget {
  const WatchfacesPage({required this.controller, super.key});

  final DeviceController controller;

  @override
  State<WatchfacesPage> createState() => _WatchfacesPageState();
}

class _WatchfacesPageState extends State<WatchfacesPage> {
  DeviceController get controller => widget.controller;

  bool _lastSessionReady = false;
  int _sessionEpoch = 0;
  int? _autoRefreshRequestedEpoch;

  @override
  void initState() {
    super.initState();
    _lastSessionReady = controller.sessionReady;
    if (_lastSessionReady) _sessionEpoch = 1;
    controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleAutoRefreshForReadySession();
    });
  }

  @override
  void didUpdateWidget(covariant WatchfacesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_onControllerChanged);
    _lastSessionReady = controller.sessionReady;
    _sessionEpoch++;
    _autoRefreshRequestedEpoch = null;
    controller.addListener(_onControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scheduleAutoRefreshForReadySession();
    });
  }

  @override
  void dispose() {
    controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final sessionReady = controller.sessionReady;
    if (sessionReady != _lastSessionReady) {
      _lastSessionReady = sessionReady;
      _sessionEpoch++;
      if (!sessionReady) {
        _autoRefreshRequestedEpoch = null;
      } else {
        _scheduleAutoRefreshForReadySession();
      }
    }
    if (mounted) setState(() {});
  }

  void _scheduleAutoRefreshForReadySession() {
    if (defaultTargetPlatform != TargetPlatform.macOS ||
        !controller.sessionReady ||
        controller.watchfacesLoadedForCurrentSession ||
        _autoRefreshRequestedEpoch == _sessionEpoch) {
      return;
    }
    final epoch = _sessionEpoch;
    _autoRefreshRequestedEpoch = epoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _sessionEpoch || !controller.sessionReady) {
        return;
      }
      unawaited(_refreshForSession(epoch));
    });
  }

  Future<void> _refreshForSession(int epoch) async {
    if (!mounted || epoch != _sessionEpoch || !controller.sessionReady) {
      return;
    }
    await controller.refreshInstalledWatchfaces();
  }

  Future<void> _refresh() async {
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      _showMessage('表盘管理目前仅支持 macOS', error: true);
      return;
    }
    if (!controller.sessionReady) {
      _showMessage('请先连接并完成设备鉴权', error: true);
      return;
    }
    final sessionEpoch = controller.watchfaceSessionEpoch;
    await controller.refreshInstalledWatchfaces();
    if (!mounted ||
        !controller.sessionReady ||
        controller.watchfaceSessionEpoch != sessionEpoch ||
        controller.watchfacesError == null) {
      return;
    }
    _showMessage(controller.watchfacesError!, error: true);
  }

  Future<void> _uninstall(WatchfaceItem watchface) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('卸载表盘？'),
            content: Text('将从设备中移除“${watchface.displayName}”。此操作不可撤销。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('卸载'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    final sessionEpoch = controller.watchfaceSessionEpoch;
    final success = await controller.uninstallWatchface(watchface);
    if (!mounted ||
        !controller.sessionReady ||
        controller.watchfaceSessionEpoch != sessionEpoch) {
      return;
    }
    _showMessage(
      success ? '设备已确认卸载表盘' : (controller.watchfacesError ?? '卸载失败'),
      error: !success,
    );
  }

  Future<void> _activate(WatchfaceItem watchface) async {
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      _showMessage('表盘切换目前仅支持 macOS', error: true);
      return;
    }
    if (watchface.isCurrent) return;
    if (!controller.sessionReady) {
      _showMessage('请先连接并完成设备鉴权', error: true);
      return;
    }
    final sessionEpoch = controller.watchfaceSessionEpoch;
    final success = await controller.activateWatchface(watchface);
    if (!mounted ||
        !controller.sessionReady ||
        controller.watchfaceSessionEpoch != sessionEpoch) {
      return;
    }
    _showMessage(
      success ? '设备已确认切换表盘' : (controller.watchfacesError ?? '切换失败'),
      error: !success,
    );
  }

  void _showMessage(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final watchfaces = controller.installedWatchfaces;
    final connected = controller.sessionReady;
    final supported = defaultTargetPlatform == TargetPlatform.macOS;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('表盘', style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 4),
                      Text(
                        '查看和管理已安装在设备上的表盘',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed:
                      supported && connected && !controller.watchfacesLoading
                      ? _refresh
                      : null,
                  icon: controller.watchfacesLoading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: const Text('刷新'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (!supported)
              const _WatchfaceEmptyState(
                icon: Icons.laptop_mac_outlined,
                title: '仅支持 macOS',
                message: '表盘管理只在 macOS 版本中提供。',
              )
            else if (!connected)
              const _WatchfaceEmptyState(
                icon: Icons.watch_outlined,
                title: '尚未连接设备',
                message: '连接并完成鉴权后，可以读取设备中的表盘。',
              )
            else if (controller.watchfacesLoading && watchfaces.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 72),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (controller.watchfacesError != null && watchfaces.isEmpty)
              _WatchfaceEmptyState(
                icon: Icons.error_outline,
                title: '读取失败',
                message: controller.watchfacesError!,
                action: FilledButton.tonalIcon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              )
            else if (watchfaces.isEmpty)
              const _WatchfaceEmptyState(
                icon: Icons.watch_outlined,
                title: '没有已安装的表盘',
                message: '设备返回的表盘列表为空。',
              )
            else ...[
              Text(
                '${watchfaces.length} 个表盘',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              for (final watchface in watchfaces)
                _WatchfaceCard(
                  watchface: watchface,
                  onActivate: _activate,
                  onUninstall: _uninstall,
                  activateEnabled:
                      supported &&
                      !watchface.isCurrent &&
                      !controller.watchfacesLoading,
                  uninstallEnabled: !controller.watchfacesLoading,
                ),
            ],
            if (controller.watchfacesError != null && watchfaces.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  controller.watchfacesError!,
                  style: TextStyle(color: colors.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WatchfaceCard extends StatelessWidget {
  const _WatchfaceCard({
    required this.watchface,
    required this.onActivate,
    required this.onUninstall,
    required this.activateEnabled,
    required this.uninstallEnabled,
  });

  final WatchfaceItem watchface;
  final Future<void> Function(WatchfaceItem) onActivate;
  final Future<void> Function(WatchfaceItem) onUninstall;
  final bool activateEnabled;
  final bool uninstallEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      color: colors.surfaceContainer,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.watch, color: colors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        watchface.displayName,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'ID ${watchface.id}',
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (!watchface.isCurrent)
                          FilledButton.tonalIcon(
                            onPressed: activateEnabled
                                ? () => onActivate(watchface)
                                : null,
                            icon: const Icon(Icons.swap_horiz),
                            label: const Text('切换'),
                          ),
                        if (watchface.canRemove)
                          OutlinedButton.icon(
                            onPressed: uninstallEnabled
                                ? () => onUninstall(watchface)
                                : null,
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('卸载'),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _WatchfaceDetail(
                  label: '版本',
                  value: '${watchface.versionCode}',
                ),
                _WatchfaceDetail(label: 'ID', value: watchface.id),
                if (watchface.isCurrent)
                  const Chip(
                    avatar: Icon(Icons.check_circle_outline, size: 16),
                    label: Text('当前表盘'),
                  ),
                if (!watchface.canRemove)
                  const Chip(
                    avatar: Icon(Icons.lock_outline, size: 16),
                    label: Text('不可卸载'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _WatchfaceDetail extends StatelessWidget {
  const _WatchfaceDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelMedium),
        const SizedBox(height: 2),
        SelectableText(
          value,
          style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
        ),
      ],
    );
  }
}

class _WatchfaceEmptyState extends StatelessWidget {
  const _WatchfaceEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      constraints: const BoxConstraints(minHeight: 260),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 56, color: colors.primary),
          const SizedBox(height: 14),
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            message,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
  }
}
