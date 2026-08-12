import 'package:flutter/material.dart';

import '../domain/device_profile.dart';
import '../domain/install_preference_store.dart';
import 'install_preference_selector.dart';

class TransferSettingsPage extends StatelessWidget {
  const TransferSettingsPage({
    required this.connectionMode,
    required this.preferredInstallTarget,
    required this.connectionModeEnabled,
    required this.segmentIntervalMs,
    required this.massWindowSize,
    this.autoTimeSync = false,
    this.floatingInstallWindowEnabled = false,
    this.themeSeedColor = const Color(0xFF6750A4),
    required this.onConnectionModeChanged,
    required this.onSegmentIntervalChanged,
    required this.onMassWindowSizeChanged,
    this.onAutoTimeSyncChanged,
    this.onFloatingInstallWindowEnabledChanged,
    this.onReplayOobe,
    this.onThemeSeedChanged,
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
  final Color themeSeedColor;
  final ValueChanged<ConnectionMode> onConnectionModeChanged;
  final ValueChanged<int> onSegmentIntervalChanged;
  final ValueChanged<int> onMassWindowSizeChanged;
  final ValueChanged<bool>? onAutoTimeSyncChanged;
  final ValueChanged<bool>? onFloatingInstallWindowEnabledChanged;
  final VoidCallback? onReplayOobe;
  final ValueChanged<Color>? onThemeSeedChanged;
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
            ThemeColorSelector(
              value: themeSeedColor,
              onChanged: onThemeSeedChanged,
            ),
            const Divider(height: 40),
            InstallPreferenceSelector(
              value: preferredInstallTarget,
              onChanged: onPreferredInstallTargetChanged,
              titleStyle: theme.textTheme.titleMedium,
            ),
            const Divider(height: 40),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.sync),
              title: const Text('自动同步时间与时区'),
              subtitle: const Text('连接成功后使用电脑当前的时间、时区和小时制同步设备'),
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
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.replay_outlined),
              title: const Text('重新查看使用引导'),
              subtitle: const Text('重置引导完成状态，并立即回到首次使用引导。'),
              trailing: const Icon(Icons.chevron_right),
              enabled: onReplayOobe != null,
              onTap: onReplayOobe,
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

class ThemeColorSelector extends StatelessWidget {
  const ThemeColorSelector({
    required this.value,
    this.onChanged,
    super.key,
  });

  final Color value;
  final ValueChanged<Color>? onChanged;

  static const _choices = <({String name, Color color})>[
    (name: '默认紫', color: Color(0xFF6750A4)),
    (name: '蓝', color: Color(0xFF0B57D0)),
    (name: '青', color: Color(0xFF018786)),
    (name: '绿', color: Color(0xFF4C8055)),
    (name: '橙', color: Color(0xFFC05621)),
    (name: '粉', color: Color(0xFFD81B60)),
    (name: '红', color: Color(0xFFB3261E)),
    (name: '金', color: Color(0xFFD4A017)),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('主题色', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          '更换全应用的强调色，浅色与深色主题都会生效；选择即时保存。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 14,
          runSpacing: 12,
          children: _choices
              .map((choice) => _ThemeColorChoice(
                    name: choice.name,
                    color: choice.color,
                    selected: choice.color.toARGB32() == value.toARGB32(),
                    onTap: onChanged == null
                        ? null
                        : () => onChanged!(choice.color),
                  ))
              .toList(growable: false),
        ),
        const SizedBox(height: 20),
        _ThemeColorPreview(colors: colors),
      ],
    );
  }
}

class _ThemeColorChoice extends StatelessWidget {
  const _ThemeColorChoice({
    required this.name,
    required this.color,
    required this.selected,
    this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final checkColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.light
            ? Colors.black
            : Colors.white;
    return Semantics(
      button: true,
      selected: selected,
      label: '$name主题色',
      child: SizedBox(
        width: 58,
        child: Column(
          children: [
            InkWell(
              key: ValueKey('theme-color-$name'),
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox.square(
                dimension: 44,
                child: Center(
                  child: selected
                      ? Container(
                          width: 38,
                          height: 38,
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: colors.surface,
                            border: Border.all(
                              color: colors.primary,
                              width: 2,
                            ),
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: color,
                            ),
                            child: Icon(
                              Icons.check,
                              color: checkColor,
                              size: 18,
                            ),
                          ),
                        )
                      : Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                          ),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              name,
              maxLines: 1,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 11,
                    letterSpacing: 0,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeColorPreview extends StatelessWidget {
  const _ThemeColorPreview({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) => Container(
        key: const ValueKey('theme-color-preview'),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colors.surfaceContainer,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('实时预览', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.watch),
                  label: const Text('安装表盘'),
                ),
                FilledButton.tonal(
                  onPressed: () {},
                  child: const Text('重试'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 6,
                child: Row(
                  children: [
                    Expanded(
                      flex: 58,
                      child: ColoredBox(
                        key: const ValueKey('theme-preview-confirmed'),
                        color: colors.primary,
                      ),
                    ),
                    Expanded(
                      flex: 24,
                      child: ColoredBox(
                        key: const ValueKey('theme-preview-submitted'),
                        color: colors.primaryContainer,
                      ),
                    ),
                    Expanded(
                      flex: 18,
                      child: ColoredBox(color: colors.surfaceContainerHighest),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  key: const ValueKey('theme-preview-navigation-pill'),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: colors.secondaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.home, color: colors.onSecondaryContainer),
                      const SizedBox(width: 6),
                      Text(
                        '侧栏选中态',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colors.onSecondaryContainer,
                            ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Badge.count(
                  count: 3,
                  child: Text(
                    '队列角标',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}
