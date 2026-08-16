import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/device_controller.dart';
import '../../domain/watch_app.dart';

/// Shows the quick apps reported by the connected device.
///
/// The list is deliberately refreshed from the device rather than persisted
/// locally, because package fingerprints are required for a valid uninstall
/// request and may change after an installation.
import '../page_module.dart';

const wristloadPage = WristloadPageModule(
  id: 'apps',
  route: '/apps',
  label: '快应用',
  icon: Icons.apps_outlined,
  selectedIcon: Icons.apps,
  order: 20,
  build: _buildAppsPage,
);

Widget _buildAppsPage(WristloadPageContext context) =>
    AppsPage(controller: context.controller);
class AppsPage extends StatefulWidget {
  const AppsPage({required this.controller, super.key});

  final DeviceController controller;

  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  DeviceController get controller => widget.controller;

  // A page can be opened before authentication completes.  Keep the refresh
  // scoped to the authenticated session so controller notifications do not
  // issue duplicate list requests, while a later reconnect can read again.
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
      if (!mounted) return;
      _scheduleAutoRefreshForReadySession();
    });
  }

  @override
  void didUpdateWidget(covariant AppsPage oldWidget) {
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
    if (!controller.sessionReady ||
        controller.quickAppsLoadedForCurrentSession ||
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
    await controller.refreshInstalledWatchApps();
  }

  Future<void> _refresh() async {
    if (!controller.sessionReady) {
      _showMessage('请先连接并完成设备鉴权', error: true);
      return;
    }
    final sessionEpoch = controller.quickAppSessionEpoch;
    await controller.refreshInstalledWatchApps();
    if (!mounted ||
        !controller.sessionReady ||
        controller.quickAppSessionEpoch != sessionEpoch ||
        controller.watchAppsError == null) {
      return;
    }
    _showMessage(controller.watchAppsError!, error: true);
  }

  Future<void> _uninstall(WatchAppItem app) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('卸载快应用？'),
            content: Text('将从设备中移除“${app.displayName}”。此操作不可撤销。'),
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
    final sessionEpoch = controller.quickAppSessionEpoch;
    final success = await controller.uninstallWatchApp(app);
    if (!mounted ||
        !controller.sessionReady ||
        controller.quickAppSessionEpoch != sessionEpoch) {
      return;
    }
    final error = controller.watchAppsError;
    _showMessage(
      success ? '卸载已确认（SPP ACK）' : (error ?? '卸载失败'),
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
    final apps = controller.installedWatchApps;
    final connected = controller.sessionReady;
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
                      Text('快应用', style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 4),
                      Text(
                        '查看和管理已安装在设备上的快应用',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: connected && !controller.watchAppsLoading
                      ? _refresh
                      : null,
                  icon: controller.watchAppsLoading
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
            if (!connected)
              _EmptyState(
                icon: Icons.apps_outlined,
                title: '尚未连接设备',
                message: '连接并完成鉴权后，可以读取设备中的快应用。',
              )
            else if (controller.watchAppsLoading && apps.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 72),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (controller.watchAppsError != null && apps.isEmpty)
              _EmptyState(
                icon: Icons.error_outline,
                title: '读取失败',
                message: controller.watchAppsError!,
                action: FilledButton.tonalIcon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              )
            else if (apps.isEmpty)
              _EmptyState(
                icon: Icons.apps_outlined,
                title: '没有已安装的快应用',
                message: '设备返回的快应用列表为空。',
              )
            else ...[
              Text('${apps.length} 个快应用', style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
              for (final app in apps)
                _AppCard(
                  app: app,
                  onUninstall: _uninstall,
                  uninstallEnabled: !controller.watchAppsLoading,
                ),
            ],
            if (controller.watchAppsError != null && apps.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  controller.watchAppsError!,
                  style: TextStyle(color: colors.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AppCard extends StatelessWidget {
  const _AppCard({
    required this.app,
    required this.onUninstall,
    required this.uninstallEnabled,
  });

  final WatchAppItem app;
  final Future<void> Function(WatchAppItem) onUninstall;
  final bool uninstallEnabled;

  String _fingerprint() => app.fingerprint
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join(':')
      .toUpperCase();

  Future<void> _copyFingerprint(BuildContext context) async {
    final value = _fingerprint();
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('指纹已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fingerprint = _fingerprint();
    return Card(
      color: colors.surfaceContainer,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.apps, color: colors.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.displayName,
                        style: theme.textTheme.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        app.packageName,
                        style: theme.textTheme.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (app.canRemove)
                  OutlinedButton.icon(
                    onPressed: uninstallEnabled ? () => onUninstall(app) : null,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('卸载'),
                  )
                else
                  Chip(
                    avatar: const Icon(Icons.lock_outline, size: 16),
                    label: const Text('系统应用'),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 18,
              runSpacing: 8,
              children: [
                _Detail(label: '版本', value: '${app.versionCode}'),
                if (fingerprint.isNotEmpty)
                  InkWell(
                    onTap: () => _copyFingerprint(context),
                    borderRadius: BorderRadius.circular(6),
                    child: _Detail(label: '指纹', value: fingerprint),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});

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

class _EmptyState extends StatelessWidget {
  const _EmptyState({
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
        borderRadius: BorderRadius.circular(16),
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
