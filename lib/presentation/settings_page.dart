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
    required this.onConnectionModeChanged,
    required this.onSegmentIntervalChanged,
    required this.onMassWindowSizeChanged,
    required this.onPreferredInstallTargetChanged,
    super.key,
  });

  final ConnectionMode connectionMode;
  final InstallPreference preferredInstallTarget;
  final bool connectionModeEnabled;
  final int segmentIntervalMs;
  final int massWindowSize;
  final ValueChanged<ConnectionMode> onConnectionModeChanged;
  final ValueChanged<int> onSegmentIntervalChanged;
  final ValueChanged<int> onMassWindowSizeChanged;
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
            Text('设备', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            SegmentedButton<ConnectionMode>(
              segments: const [
                ButtonSegment(
                  value: ConnectionMode.modern,
                  icon: Icon(Icons.bluetooth_connected),
                  label: Text('现代设备'),
                ),
                ButtonSegment(
                  value: ConnectionMode.classicExperimental,
                  icon: Icon(Icons.science_outlined),
                  label: Text('经典设备（实验）'),
                ),
              ],
              selected: {connectionMode},
              onSelectionChanged: connectionModeEnabled
                  ? (selection) => onConnectionModeChanged(selection.single)
                  : null,
            ),
            const SizedBox(height: 8),
            Text(
              connectionMode == ConnectionMode.modern
                  ? '适用于手环 9 及后续 V2 设备。'
                  : '适用于旧款设备的实验连接；安装功能不可用。',
              style: theme.textTheme.bodySmall,
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
                const Expanded(child: Text('每窗口分片数（实验）')),
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
            Text(
              massWindowSize <= 3
                  ? '设备当前协商值为 3；可逐级提高并观察 ACK、超时与稳定性。'
                  : '已超过设备协商值 3：仅用于测速，超时后会停止且不会盲目重发。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: massWindowSize <= 3 ? null : theme.colorScheme.error,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
