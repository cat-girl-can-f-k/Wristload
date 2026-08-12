import 'package:flutter/material.dart';

import '../domain/device_profile.dart';
import '../domain/install_preference_store.dart';

class TransferSettingsPage extends StatelessWidget {
  const TransferSettingsPage({
    required this.connectionMode,
    required this.preferredInstallTarget,
    required this.connectionModeEnabled,
    required this.segmentIntervalMs,
    required this.massWindowSize,
    this.autoTimeSync = false,
    this.floatingInstallWindowEnabled = false,
    required this.onConnectionModeChanged,
    required this.onSegmentIntervalChanged,
    required this.onMassWindowSizeChanged,
    this.onAutoTimeSyncChanged,
    this.onFloatingInstallWindowEnabledChanged,
    required this.onPreferredInstallTargetChanged,
    super.key,
  });

  final ConnectionMode connectionMode;
  final InstallPreference preferredInstallTarget;
  final bool connectionModeEnabled;
  final int segmentIntervalMs;
  final int massWindowSize;
  final bool autoTimeSync;
  final bool floatingInstallWindowEnabled;
  final ValueChanged<ConnectionMode> onConnectionModeChanged;
  final ValueChanged<int> onSegmentIntervalChanged;
  final ValueChanged<int> onMassWindowSizeChanged;
  final ValueChanged<bool>? onAutoTimeSyncChanged;
  final ValueChanged<bool>? onFloatingInstallWindowEnabledChanged;
  final ValueChanged<InstallPreference> onPreferredInstallTargetChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('设置', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 4),
            Text('管理设备连接模式与传输参数。', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 28),
            Text('安装', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            SegmentedButton<InstallPreference>(
              segments: const [
                ButtonSegment(
                  value: InstallPreference.watchface,
                  icon: Icon(Icons.watch),
                  label: Text('表盘设计优先'),
                ),
                ButtonSegment(
                  value: InstallPreference.quickApp,
                  icon: Icon(Icons.apps),
                  label: Text('快应用开发优先'),
                ),
                ButtonSegment(
                  value: InstallPreference.both,
                  icon: Icon(Icons.apps_outage),
                  label: Text('均有开发'),
                ),
              ],
              selected: {preferredInstallTarget},
              onSelectionChanged: (selection) =>
                  onPreferredInstallTargetChanged(selection.single),
            ),
            const SizedBox(height: 8),
            Text(
              '主页安装按钮会优先显示所选类型；菜单中的临时安装不会修改此设置。',
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 40),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.sync),
              title: const Text('自动同步时间与时区'),
              subtitle: const Text('鉴权成功后使用电脑当前的时间、时区和小时制同步设备'),
              value: autoTimeSync,
              onChanged: onAutoTimeSyncChanged,
            ),
            const Divider(height: 40),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.picture_in_picture_alt_outlined),
              title: const Text('启用悬浮安装窗'),
              subtitle: const Text('可将文件直接拖入右下角悬浮窗安装。'),
              value: floatingInstallWindowEnabled,
              onChanged: onFloatingInstallWindowEnabledChanged,
            ),
            const Divider(height: 40),
            Text('传输', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.speed_outlined),
                const SizedBox(width: 12),
                const Expanded(child: Text('发送窗口间隔')),
                Text('$segmentIntervalMs ms'),
              ],
            ),
            Slider(
              value: segmentIntervalMs.toDouble(),
              min: 1,
              max: 20,
              divisions: 19,
              label: '$segmentIntervalMs ms',
              onChanged: (value) => onSegmentIntervalChanged(value.round()),
            ),
            Text(
              '每窗口合并写入后等待累计 ACK；1 ms 最快，20 ms 更保守。',
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 40),
            Row(
              children: [
                const Icon(Icons.view_stream_outlined),
                const SizedBox(width: 12),
                const Expanded(child: Text('每窗口分片数')),
                Text('$massWindowSize 片'),
              ],
            ),
            Slider(
              value: massWindowSize.toDouble(),
              min: 1,
              max: 50,
              divisions: 49,
              label: '$massWindowSize 片',
              onChanged: (value) => onMassWindowSizeChanged(value.round()),
            ),
            Text('值越小传输速度越慢', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
