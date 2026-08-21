import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../application/device_controller.dart';
import '../../domain/device_profile.dart';
import '../../domain/install_preference_store.dart';
import '../../domain/resource_install_target_policy.dart';
import '../../domain/rpk_install_limit.dart';
import '../floating_window_warning_dialog.dart';
import '../install_preference_selector.dart';

import '../page_module.dart';

const wristloadPage = WristloadPageModule(
  id: 'settings',
  route: '/settings',
  label: '设置',
  icon: Icons.settings_outlined,
  selectedIcon: Icons.settings,
  order: 50,
  build: _buildSettingsPage,
);

Widget _buildSettingsPage(WristloadPageContext context) => TransferSettingsPage(
  preferredInstallTarget: context.preferredInstallTarget,
  connectionMode: context.controller.connectionMode,
  connectionModeEnabled:
      !context.controller.isConnected && !context.controller.isConnectionBusy,
  segmentIntervalMs: context.controller.segmentIntervalMs,
  massWindowSize: context.controller.massWindowSize,
  rpkMaxPackageBytes: context.controller.rpkMaxPackageBytes,
  resourceInstallTargetPolicy: context.controller.resourceInstallTargetPolicy,
  resourceInstallDevices: context.controller.resourceInstallDevices,
  autoTimeSync: context.controller.autoTimeSync,
  forceWatchfaceInstall: context.controller.forceWatchfaceInstall,
  showForceWatchfaceInstall: defaultTargetPlatform == TargetPlatform.macOS,
  autoConnectLastDevice: context.controller.autoConnectLastDeviceEnabled,
  floatingInstallWindowEnabled: context.floatingInstallWindowEnabled,
  autoOpenDiagnosticLog: context.autoOpenDiagnosticLog,
  themeSeedColor: context.themeSeedColor,
  onThemeSeedChanged: context.onThemeSeedChanged,
  onConnectionModeChanged: context.controller.setConnectionMode,
  onSegmentIntervalChanged: context.controller.setSegmentIntervalMs,
  onMassWindowSizeChanged: context.controller.setMassWindowSize,
  onRpkMaxPackageBytesChanged: context.controller.setRpkMaxPackageBytes,
  onResourceInstallTargetPolicyChanged:
      context.controller.setResourceInstallTargetPolicy,
  onAutoTimeSyncChanged: context.controller.setAutoTimeSync,
  onForceWatchfaceInstallChanged: defaultTargetPlatform == TargetPlatform.macOS
      ? context.controller.setForceWatchfaceInstall
      : null,
  onAutoConnectLastDeviceChanged:
      context.controller.setAutoConnectLastDeviceEnabled,
  onFloatingInstallWindowEnabledChanged:
      context.onFloatingInstallWindowEnabledChanged,
  onAutoOpenDiagnosticLogChanged: context.onAutoOpenDiagnosticLogChanged,
  onPreferredInstallTargetChanged: context.onPreferredInstallTargetChanged,
  onReplayOobe: context.onReplayOobe,
  onEditAuthKey: context.onEditAuthKey,
);

class TransferSettingsPage extends StatelessWidget {
  const TransferSettingsPage({
    required this.connectionMode,
    required this.preferredInstallTarget,
    required this.connectionModeEnabled,
    required this.segmentIntervalMs,
    required this.massWindowSize,
    this.rpkMaxPackageBytes = RpkInstallLimit.defaultBytes,
    this.resourceInstallTargetPolicy = const ResourceInstallTargetPolicy(),
    this.resourceInstallDevices = const <ResourceInstallDevice>[],
    this.autoTimeSync = false,
    this.forceWatchfaceInstall = false,
    this.showForceWatchfaceInstall = false,
    this.autoConnectLastDevice = true,
    this.floatingInstallWindowEnabled = false,
    this.autoOpenDiagnosticLog = false,
    this.themeSeedColor = const Color(0xFF6750A4),
    required this.onConnectionModeChanged,
    required this.onSegmentIntervalChanged,
    required this.onMassWindowSizeChanged,
    this.onRpkMaxPackageBytesChanged,
    this.onResourceInstallTargetPolicyChanged,
    this.onAutoTimeSyncChanged,
    this.onForceWatchfaceInstallChanged,
    this.onAutoConnectLastDeviceChanged,
    this.onFloatingInstallWindowEnabledChanged,
    this.onAutoOpenDiagnosticLogChanged,
    this.onReplayOobe,
    this.onThemeSeedChanged,
    this.onEditAuthKey,
    required this.onPreferredInstallTargetChanged,
    super.key,
  });

  final ConnectionMode connectionMode;
  final InstallPreference preferredInstallTarget;
  final bool connectionModeEnabled;
  final int segmentIntervalMs;
  final int massWindowSize;
  final int rpkMaxPackageBytes;
  final ResourceInstallTargetPolicy resourceInstallTargetPolicy;
  final List<ResourceInstallDevice> resourceInstallDevices;
  final bool autoTimeSync;
  final bool forceWatchfaceInstall;
  final bool showForceWatchfaceInstall;
  final bool autoConnectLastDevice;
  final bool floatingInstallWindowEnabled;
  final bool autoOpenDiagnosticLog;
  final Color themeSeedColor;
  final ValueChanged<ConnectionMode> onConnectionModeChanged;
  final ValueChanged<int> onSegmentIntervalChanged;
  final ValueChanged<int> onMassWindowSizeChanged;
  final ValueChanged<int>? onRpkMaxPackageBytesChanged;
  final ValueChanged<ResourceInstallTargetPolicy>?
  onResourceInstallTargetPolicyChanged;
  final ValueChanged<bool>? onAutoTimeSyncChanged;
  final ValueChanged<bool>? onForceWatchfaceInstallChanged;
  final ValueChanged<bool>? onAutoConnectLastDeviceChanged;
  final ValueChanged<bool>? onFloatingInstallWindowEnabledChanged;
  final ValueChanged<bool>? onAutoOpenDiagnosticLogChanged;
  final VoidCallback? onReplayOobe;
  final ValueChanged<Color>? onThemeSeedChanged;
  final VoidCallback? onEditAuthKey;
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
            InstallPreferenceSelector(
              value: preferredInstallTarget,
              onChanged: onPreferredInstallTargetChanged,
              titleStyle: theme.textTheme.titleMedium,
            ),
            const Divider(height: 40),
            _ResourceInstallTargetSelector(
              policy: resourceInstallTargetPolicy,
              devices: resourceInstallDevices,
              onChanged: onResourceInstallTargetPolicyChanged,
            ),
            const Divider(height: 40),
            if (showForceWatchfaceInstall) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.delete_forever_outlined),
                title: const Text('强制安装表盘'),
                subtitle: const Text('安装之前删除同id表盘，然后安装新的表盘'),
                value: forceWatchfaceInstall,
                onChanged: onForceWatchfaceInstallChanged,
              ),
              const Divider(height: 40),
            ],
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
              secondary: const Icon(Icons.power_settings_new_outlined),
              title: const Text('启动时自动连接上次设备'),
              subtitle: const Text('启动后自动连接最近一次完成鉴权的设备；关闭后可在主页历史设备区域手动连接。'),
              value: autoConnectLastDevice,
              onChanged: onAutoConnectLastDeviceChanged,
            ),
            const Divider(height: 40),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.picture_in_picture_alt_outlined),
              title: const Text('启用悬浮安装窗'),
              subtitle: Text(
                onFloatingInstallWindowEnabledChanged == null
                    ? '悬浮安装窗目前仅支持 Windows。'
                    : '可将文件直接拖入右下角悬浮窗安装。',
              ),
              value: floatingInstallWindowEnabled,
              onChanged: onFloatingInstallWindowEnabledChanged == null
                  ? null
                  : (value) {
                      if (!value) {
                        onFloatingInstallWindowEnabledChanged!(false);
                        return;
                      }
                      // 开启前确认：悬浮窗（独立窗口）会抢占键盘焦点，
                      // 导致主窗口内输入框无法输入。
                      unawaited(
                        showFloatingWindowEnableWarning(context).then((
                          confirmed,
                        ) {
                          if (confirmed == true) {
                            onFloatingInstallWindowEnabledChanged!(true);
                          }
                        }),
                      );
                    },
            ),
            const Divider(height: 40),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.article_outlined),
              title: const Text('启动时自动打开诊断日志'),
              subtitle: Text(
                onAutoOpenDiagnosticLogChanged == null
                    ? '诊断日志独立窗口目前仅支持 Windows 和 macOS。'
                    : '下次启动 Wristload 时自动打开诊断日志独立窗口。',
              ),
              value: autoOpenDiagnosticLog,
              onChanged: onAutoOpenDiagnosticLogChanged,
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
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.vpn_key_outlined),
              title: const Text('修改绑定设备 authkey'),
              subtitle: const Text('查看历史绑定设备并修改 Wristload 当前使用的 authkey'),
              trailing: const Icon(Icons.chevron_right),
              enabled: onEditAuthKey != null,
              onTap: onEditAuthKey,
            ),
            const Divider(height: 40),
            Text('传输', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('RPK 安装包大小上限'),
              subtitle: const Text('仅限制快应用 RPK 源文件；ZIP 解压、清单和资源安全检查仍然生效。'),
              trailing: Text(
                '${(rpkMaxPackageBytes / (1024 * 1024)).round()} MB',
              ),
              onTap: onRpkMaxPackageBytesChanged == null
                  ? null
                  : () => unawaited(_editRpkMaxPackageBytes(context)),
            ),
            const Divider(height: 40),
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

  Future<void> _editRpkMaxPackageBytes(BuildContext context) async {
    final controller = TextEditingController(
      text: (rpkMaxPackageBytes / (1024 * 1024)).round().toString(),
    );
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('RPK 安装包大小上限'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '大小',
            suffixText: 'MB',
            helperText: '允许范围：16–100 MB',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final mb = int.tryParse(controller.text.trim());
              if (mb == null || mb < 16 || mb > 100) return;
              Navigator.pop(dialogContext, mb * 1024 * 1024);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null) onRpkMaxPackageBytesChanged?.call(result);
  }
}

class _ResourceInstallTargetSelector extends StatelessWidget {
  const _ResourceInstallTargetSelector({
    required this.policy,
    required this.devices,
    this.onChanged,
  });

  final ResourceInstallTargetPolicy policy;
  final List<ResourceInstallDevice> devices;
  final ValueChanged<ResourceInstallTargetPolicy>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final automaticDevice = devices
        .where((device) => device.id == policy.automaticDeviceId)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('资源安装到所有设备？', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '多设备连接时安装资源的处理方式',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        RadioListTile<ResourceInstallTargetMode>(
          contentPadding: EdgeInsets.zero,
          value: ResourceInstallTargetMode.allConnected,
          groupValue: policy.mode,
          title: const Text('为所有已连接的设备安装(可能会出现奇奇怪怪的bug)'),
          onChanged: onChanged == null
              ? null
              : (_) => unawaited(_requestAllConnectedEnable(context)),
        ),
        RadioListTile<ResourceInstallTargetMode>(
          contentPadding: EdgeInsets.zero,
          value: ResourceInstallTargetMode.manual,
          groupValue: policy.mode,
          title: const Text('关闭（我自己选择）'),
          onChanged: onChanged == null
              ? null
              : (mode) => onChanged!(ResourceInstallTargetPolicy(mode: mode!)),
        ),
        if (devices.isEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 4),
            child: Text(
              '连接设备后可指定自动安装目标。',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        for (final device in devices)
          RadioListTile<ResourceInstallTargetMode>(
            contentPadding: EdgeInsets.zero,
            value: ResourceInstallTargetMode.automaticDevice,
            groupValue: policy.mode,
            title: Text('自动为${device.name.isEmpty ? '已连接设备' : device.name}安装'),
            subtitle:
                automaticDevice != null &&
                    policy.mode == ResourceInstallTargetMode.automaticDevice &&
                    automaticDevice.id == device.id
                ? const Text('当前自动安装目标')
                : null,
            onChanged: onChanged == null
                ? null
                : (_) => onChanged!(
                    ResourceInstallTargetPolicy(
                      mode: ResourceInstallTargetMode.automaticDevice,
                      automaticDeviceId: device.id,
                    ),
                  ),
          ),
      ],
    );
  }

  Future<void> _requestAllConnectedEnable(BuildContext context) async {
    if (policy.mode == ResourceInstallTargetMode.allConnected) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (_) => const _AllConnectedInstallWarningDialog(),
    );
    if (approved == true && context.mounted) {
      onChanged!(
        const ResourceInstallTargetPolicy(
          mode: ResourceInstallTargetMode.allConnected,
        ),
      );
    }
  }
}

class _AllConnectedInstallWarningDialog extends StatefulWidget {
  const _AllConnectedInstallWarningDialog();

  @override
  State<_AllConnectedInstallWarningDialog> createState() =>
      _AllConnectedInstallWarningDialogState();
}

class _AllConnectedInstallWarningDialogState
    extends State<_AllConnectedInstallWarningDialog> {
  static const _cooldownSeconds = 5;

  Timer? _timer;
  int _remainingSeconds = _cooldownSeconds;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remainingSeconds <= 1) {
        _timer?.cancel();
        _timer = null;
        setState(() => _remainingSeconds = 0);
      } else {
        setState(() => _remainingSeconds--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _cancel() => Navigator.of(context).pop(false);

  void _confirm() {
    if (_remainingSeconds == 0) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final enabled = _remainingSeconds == 0;
    final countdownWarning =
        '经过测试，启用了该功能会触发各式各样的bug。该功能不建议开启。如需开启，等到$_remainingSeconds秒后则可开启';

    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: colors.error),
      title: const Text('确认开启多设备安装？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('开启后，拖入资源将会给所有已连接的设备安装。这可能会导致兼容性问题。'),
          const SizedBox(height: 12),
          Text(
            countdownWarning,
            key: const ValueKey('all-connected-install-warning'),
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.error),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text('取消')),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          ),
          onPressed: enabled ? _confirm : null,
          child: Text(enabled ? '确认开启' : '确认开启（$_remainingSeconds）'),
        ),
      ],
    );
  }
}

class ThemeColorSelector extends StatelessWidget {
  const ThemeColorSelector({required this.value, this.onChanged, super.key});

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
              .map(
                (choice) => _ThemeColorChoice(
                  name: choice.name,
                  color: choice.color,
                  selected: choice.color.toARGB32() == value.toARGB32(),
                  onTap: onChanged == null
                      ? null
                      : () => onChanged!(choice.color),
                ),
              )
              .toList(growable: false),
        ),
        const SizedBox(height: 20),
        _ThemeColorPreview(
          colors: colors,
          themeName: _choices
              .firstWhere(
                (choice) => choice.color.toARGB32() == value.toARGB32(),
                orElse: () => _choices.first,
              )
              .name,
        ),
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
                            border: Border.all(color: colors.primary, width: 2),
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
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(fontSize: 11, letterSpacing: 0),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeColorPreview extends StatelessWidget {
  const _ThemeColorPreview({required this.colors, required this.themeName});

  final ColorScheme colors;
  final String themeName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    return Container(
      key: const ValueKey('theme-color-preview'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '实时预览 · $themeName',
            key: const ValueKey('theme-preview-title'),
            style: textTheme.titleMedium?.copyWith(color: colors.onSurface),
          ),
          const SizedBox(height: 18),
          Wrap(
            key: const ValueKey('theme-preview-actions'),
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                key: const ValueKey('theme-preview-install'),
                onPressed: () {},
                icon: const Icon(Icons.watch),
                label: const Text('安装表盘'),
              ),
              FilledButton.tonal(
                key: const ValueKey('theme-preview-retry'),
                onPressed: () {},
                child: const Text('重试'),
              ),
              OutlinedButton(
                key: const ValueKey('theme-preview-cancel'),
                onPressed: () {},
                child: const Text('取消'),
              ),
              _ThemePreviewChip(
                key: const ValueKey('theme-preview-installable'),
                colors: colors,
                label: '可安装',
              ),
            ],
          ),
          const SizedBox(height: 26),
          Semantics(
            label: '传输进度 70%，设备确认 43/82 片',
            child: Container(
              key: const ValueKey('theme-preview-progress-track'),
              width: double.infinity,
              height: 8,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: colors.outlineVariant, width: 0.5),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 52,
                    child: ColoredBox(
                      key: const ValueKey('theme-preview-confirmed'),
                      color: colors.primary,
                    ),
                  ),
                  Expanded(
                    flex: 18,
                    child: ColoredBox(
                      key: const ValueKey('theme-preview-submitted'),
                      color: colors.primaryContainer,
                    ),
                  ),
                  const Spacer(flex: 30),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            key: const ValueKey('theme-preview-transfer-stats'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '设备确认 43/82 片 · 669.5/1301.2 KB',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '76.9 KB/s',
                textAlign: TextAlign.end,
                style: textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          Wrap(
            key: const ValueKey('theme-preview-navigation'),
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                key: const ValueKey('theme-preview-navigation-pill'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: colors.secondaryContainer,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  Icons.home,
                  color: colors.onSecondaryContainer,
                  size: 22,
                ),
              ),
              Text(
                '侧栏选中态',
                style: textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              Container(
                key: const ValueKey('theme-preview-badge'),
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '3',
                  style: textTheme.labelLarge?.copyWith(
                    color: colors.onPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '队列角标',
                style: textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ThemePreviewChip extends StatelessWidget {
  const _ThemePreviewChip({
    required this.colors,
    required this.label,
    super.key,
  });

  final ColorScheme colors;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: BoxDecoration(
      border: Border.all(color: colors.primary),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      label,
      style: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(color: colors.primary),
    ),
  );
}
