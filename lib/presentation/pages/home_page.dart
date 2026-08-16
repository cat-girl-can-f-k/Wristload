import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../application/device_controller.dart';
import '../../application/diagnostic_log_service.dart';
import '../../domain/auth_key_binding.dart';
import '../../domain/firmware_package_inspector.dart';
import '../../domain/install_models.dart';
import '../../domain/install_task.dart';
import '../../domain/install_preference_store.dart';
import '../../domain/queue_file_importer.dart';
import '../../platform/scoped_file_picker.dart';
import '../../platform/security_scoped_file_access.dart';
import '../device_info_page.dart';
import '../firmware_inspection_dialog.dart';
import '../home_widgets.dart';
import '../install_split_button.dart';
import '../install_task_card.dart';
import '../install_warning_dialog.dart';
import '../page_module.dart';

const wristloadPage = WristloadPageModule(
  id: 'home',
  route: '/',
  label: '首页',
  icon: Icons.home_outlined,
  selectedIcon: Icons.home,
  order: 0,
  build: _buildHomePage,
);

Widget _buildHomePage(WristloadPageContext context) => HomePage(
  controller: context.controller,
  preferredInstallTarget: context.preferredInstallTarget,
  onPreferredInstallTargetChanged: context.onPreferredInstallTargetChanged,
  diagnosticLogWindowOpen: context.diagnosticLogWindowOpen,
  onDiagnosticLogWindowChanged: context.onDiagnosticLogWindowChanged,
);
Future<void> openVerifiedDeviceInfo(
  BuildContext context,
  DeviceController controller,
) {
  if (!context.mounted || !DeviceInfoPage.hasVerifiedSession(controller)) {
    return Future<void>.value();
  }
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/device-info'),
      builder: (_) => DeviceInfoPage(controller: controller),
    ),
  );
}

class HomePage extends StatelessWidget {
  const HomePage({
    required this.controller,
    required this.preferredInstallTarget,
    required this.onPreferredInstallTargetChanged,
    this.diagnosticLogWindowOpen = false,
    this.onDiagnosticLogWindowChanged,
    super.key,
  });

  final DeviceController controller;
  final InstallPreference preferredInstallTarget;
  final ValueChanged<InstallPreference> onPreferredInstallTargetChanged;
  final bool diagnosticLogWindowOpen;
  final ValueChanged<bool>? onDiagnosticLogWindowChanged;

  Future<void> _pickFirmware(BuildContext context) async {
    final selected = await ScopedFilePicker.pickFiles(
      allowedExtensions: const ['zip', 'bin'],
    );
    final file = selected?.single;
    final path = file?.path;
    if (path == null || !context.mounted) return;

    try {
      final inspection = await SecurityScopedFileAccess.instance.withAccess(
        file!,
        (resolved) => const FirmwarePackageInspector().inspect(resolved.path),
      );
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => FirmwareInspectionDialog(inspection: inspection),
      );
    } on FormatException catch (error) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => FirmwareInspectionErrorDialog(
          fileName: path.split(RegExp(r'[/\\]')).last,
          message: error.message.toString(),
        ),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => FirmwareInspectionErrorDialog(
          fileName: path.split(RegExp(r'[/\\]')).last,
          message: '读取固件包时发生错误：$error',
        ),
      );
    }
  }

  Future<void> _pickAndTry(BuildContext context, InstallKind kind) async {
    final extensions = kind == InstallKind.watchface
        ? const ['bin', 'face']
        : const ['rpk'];
    final selected = await ScopedFilePicker.pickFiles(
      allowedExtensions: extensions,
    );
    final source = selected?.single;
    if (source == null) return;
    try {
      final importedRequest = await QueueFileImporter().prepareSingle(
        source,
        expectedKind: kind,
      );
      var metadata = importedRequest.metadata;
      var unsupportedLuaConfirmed = false;
      var watchfaceResolutionConfirmed = false;
      if (!context.mounted) return;
      if (kind == InstallKind.watchface) {
        final compatibilityError = controller.watchfaceCompatibilityError(
          metadata,
        );
        if (compatibilityError != null) {
          watchfaceResolutionConfirmed = await _confirmWatchfaceResolution(
            context,
            metadata,
          );
          if (!watchfaceResolutionConfirmed) return;
          if (!context.mounted) return;
        }
        if (controller.requiresUnsupportedLuaConfirmation(metadata)) {
          unsupportedLuaConfirmed = await _confirmUnsupportedLuaWatchface(
            context,
            metadata,
          );
          if (!unsupportedLuaConfirmed) return;
        }
        if (!context.mounted) return;
        final edited = await _editFaceId(context, metadata);
        if (edited == null) return;
        metadata = edited;
      } else if (metadata.versionCode == null) {
        if (!context.mounted) return;
        final edited = await _editRpkVersion(context, metadata);
        if (edited == null) return;
        metadata = edited;
      }
      if (kind == InstallKind.watchface &&
          !RegExp(r'^\d+$').hasMatch(metadata.faceId ?? '')) {
        throw const FormatException('faceId 必须为数值型 ID');
      }
      if (kind == InstallKind.quickApp &&
          (metadata.versionCode == null ||
              metadata.versionCode! <= 0 ||
              metadata.versionCode! > maxRpkVersionCode)) {
        throw const FormatException('RPK 清单未提供版本号，请填写有效 32 位正整数版本号');
      }
      controller.enqueue(
        importedRequest.copyWith(
          metadata: metadata,
          unsupportedLuaConfirmed: unsupportedLuaConfirmed,
          watchfaceResolutionConfirmed: watchfaceResolutionConfirmed,
        ),
      );
      await controller.runQueue();
    } on Object catch (error) {
      controller.reportError('无法创建安装计划：$error');
    }
  }

  Future<bool> _confirmWatchfaceResolution(
    BuildContext context,
    InstallMetadata metadata,
  ) async {
    var confirmed = false;
    final profile = controller.connectedProfile;
    final resolutions = metadata.watchfaceResolutions.isEmpty
        ? '未识别'
        : metadata.watchfaceResolutions.join('、');
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InstallWarningDialog(
        title: '表盘分辨率不匹配',
        message: '安装后可能无法正常显示或使用',
        rows: [
          ('表盘分辨率', resolutions, false),
          ('设备分辨率', profile?.watchfaceResolution?.toString() ?? '未知', true),
          ('文件名', metadata.fileName, false),
        ],
        onConfirm: () => confirmed = true,
      ),
    );
    return confirmed;
  }

  Future<bool> _confirmUnsupportedLuaWatchface(
    BuildContext context,
    InstallMetadata metadata,
  ) async {
    var confirmed = false;
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InstallWarningDialog(
        title: 'Lua 不被支持',
        message: '安装后可能无法正常显示或使用',
        rows: [
          ('文件名', metadata.fileName, false),
          ('检测结果', '检测到lua文件', true),
          ('目标设备', controller.connectedProfile?.displayName ?? '未知设备', false),
        ],
        onConfirm: () => confirmed = true,
      ),
    );
    return confirmed;
  }

  Future<InstallMetadata?> _editFaceId(
    BuildContext context,
    InstallMetadata metadata,
  ) async {
    // TextFormField owns its internal controller for the whole dialog route.
    // Keeping a controller in this caller and disposing it after showDialog
    // returns races the route's reverse animation on macOS.
    var faceId = metadata.faceId ?? '';
    final formKey = GlobalKey<FormState>();
    return showDialog<InstallMetadata>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('表盘 faceId'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: faceId,
            onChanged: (value) => faceId = value,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '从表盘资源解析，可按需编辑',
              border: OutlineInputBorder(),
            ),
            validator: (value) => RegExp(r'^\d+$').hasMatch(value ?? '')
                ? null
                : 'faceId 必须是非空数值',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(faceId: faceId.trim()),
              );
            },
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  Future<InstallMetadata?> _editRpkVersion(
    BuildContext context,
    InstallMetadata metadata,
  ) async {
    var versionText = '';
    final formKey = GlobalKey<FormState>();
    return showDialog<InstallMetadata>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('RPK 版本号'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: versionText,
            onChanged: (value) => versionText = value,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: '包名：${metadata.packageName}',
              helperText: '包名必须来自 RPK 清单，不能手动修改。',
              border: const OutlineInputBorder(),
            ),
            validator: (value) {
              final version = int.tryParse(value?.trim() ?? '');
              if (version == null ||
                  version <= 0 ||
                  version > maxRpkVersionCode) {
                return '请输入 1–$maxRpkVersionCode';
              }
              return null;
            },
            onFieldSubmitted: (value) {
              versionText = value;
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(versionCode: int.parse(versionText.trim())),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(versionCode: int.parse(versionText.trim())),
              );
            },
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  /// authkey 是正式会话身份校验的必填输入。
  Future<void> _connectWithAuthKey(
    BuildContext context,
    DiscoveredEventArgs result,
  ) async {
    final deviceId = result.peripheral.uuid.toString();
    // 只读取本设备经认证后保存的 authkey；绝不能把另一台设备的凭据
    // 当作通用回退值。没有本设备记录时才请求用户输入。
    if (await controller.useSavedAuthKeyForDevice(deviceId)) {
      if (!context.mounted) return;
      await controller.connect(result);
      return;
    }
    if (!context.mounted) return;
    var authKey = '';
    final formKey = GlobalKey<FormState>();
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('输入 authkey'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: authKey,
            onChanged: (value) => authKey = value,
            autofocus: true,
            maxLength: 32,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: '32 位十六进制（绑定 token，16 字节）',
              counterText: '',
              border: OutlineInputBorder(),
            ),
            validator: (value) {
              final v = value?.trim() ?? '';
              if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(v)) {
                return '请输入 32 位十六进制字符';
              }
              return null;
            },
            onFieldSubmitted: (value) {
              authKey = value;
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, authKey.trim());
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, authKey.trim());
              }
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
    if (input != null &&
        await controller.setAuthKey(input, deviceId: deviceId)) {
      // The controller persists the device-specific binding only after f=27
      // confirms the authkey. A cancelled macOS pairing or failed RFCOMM
      // handshake must not create an apparent "saved device".
      await controller.connect(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A selected peripheral is only a transport candidate until the
    // controller confirms an authenticated session. In particular, macOS
    // pairing cancellation can briefly leave a candidate behind. Do not let
    // that candidate unlock device actions in the UI.
    final connected = controller.isConnected;
    final canOpenDeviceInfo = DeviceInfoPage.hasVerifiedSession(controller);
    final device = connected ? controller.connectedDevice : null;
    final connecting = !connected && controller.isConnecting;
    final disconnecting =
        !connected && !connecting && controller.isConnectionBusy;
    final candidateName =
        (controller.connectedDeviceName ??
                controller.connectedProfile?.displayName ??
                '')
            .trim();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final battery = controller.batteryPercent;
    final hasBattery = battery != null && battery >= 0 && battery <= 100;
    final storageUsed = controller.storageUsedBytes;
    final storageTotal = controller.storageTotalBytes;
    final hasStorage =
        storageUsed != null &&
        storageTotal != null &&
        storageTotal > 0 &&
        storageUsed <= storageTotal;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              connected
                                  ? '已连接：${candidateName.isEmpty ? '未知设备' : candidateName}'
                                  : connecting
                                  ? '正在连接：${candidateName.isEmpty ? '设备' : candidateName}'
                                  : disconnecting
                                  ? '正在断开连接…'
                                  : '尚未连接设备',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleLarge,
                            ),
                          ),
                          if (canOpenDeviceInfo)
                            IconButton(
                              key: const ValueKey('device-info-button'),
                              tooltip: '查看设备信息',
                              style: IconButton.styleFrom(
                                side: BorderSide(color: colors.outlineVariant),
                              ),
                              icon: const Icon(Icons.chevron_right),
                              onPressed: () => unawaited(
                                openVerifiedDeviceInfo(context, controller),
                              ),
                            ),
                        ],
                      ),
                      if (connected) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: colors.tertiary,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text('已连接', style: theme.textTheme.bodyMedium),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                device?.uuid.toString() ?? '设备身份读取中',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.end,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (connected && (hasBattery || hasStorage)) ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            if (hasBattery)
                              Expanded(
                                child: _DeviceStat(
                                  icon: Icons.battery_std,
                                  value: '$battery%',
                                  detail: '电量',
                                  progress: battery / 100,
                                  progressColor: battery < 20
                                      ? colors.error
                                      : null,
                                ),
                              ),
                            if (hasBattery && hasStorage)
                              const SizedBox(width: 12),
                            if (hasStorage)
                              Expanded(
                                child: _DeviceStat(
                                  icon: Icons.sd_storage,
                                  value:
                                      '${_formatBytes(storageUsed)} / ${_formatBytes(storageTotal)}',
                                  detail: '存储',
                                  progress: storageUsed / storageTotal,
                                ),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (!connected && controller.bluetoothUnavailable) ...[
                        _BluetoothUnavailableBanner(
                          message: controller.bluetoothStateMessage,
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (!connected)
                        if (connecting || disconnecting)
                          Row(
                            children: [
                              const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  connecting
                                      ? '正在建立设备连接，完成验证后即可使用设备功能。'
                                      : '正在释放蓝牙连接，请稍候。',
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          )
                        else if (controller.isScanning)
                          Row(
                            children: [
                              const ScanningPulseIndicator(),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '正在扫描附近的设备…',
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                    Text(
                                      '找到 ${controller.scanResults.where(isInstallableDiscovery).length} 个可安装设备',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: colors.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton.icon(
                                onPressed: controller.stopScan,
                                icon: const Icon(Icons.stop_circle_outlined),
                                label: const Text('停止扫描'),
                              ),
                            ],
                          )
                        else
                          FilledButton.icon(
                            onPressed:
                                controller.canScan &&
                                    !controller.isConnectionBusy
                                ? controller.beginScan
                                : null,
                            icon: const Icon(Icons.bluetooth_searching),
                            label: const Text('开始扫描'),
                          )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: controller.isConnectionBusy
                                  ? null
                                  : controller.reconnect,
                              icon: controller.isConnectionBusy
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.refresh),
                              label: Text(
                                controller.isConnectionBusy ? '正在连接' : '重新连接',
                              ),
                            ),
                            OutlinedButton.icon(
                              key: const ValueKey('disconnect-button'),
                              onPressed: controller.isConnectionBusy
                                  ? null
                                  : controller.disconnect,
                              icon: const Icon(Icons.link_off),
                              label: const Text('断开连接'),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              if (controller.error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (!connected && controller.authKeyBindings.isNotEmpty) ...[
                const SizedBox(height: 12),
                _SavedDevicesSection(
                  bindings: controller.authKeyBindings,
                  enabled: !controller.isConnectionBusy && controller.canScan,
                  onConnect: controller.connectSavedDevice,
                ),
              ],
              if (!connected && !controller.isConnectionBusy) ...[
                const SizedBox(height: 12),
                ScanResultsList(
                  results: controller.scanResults,
                  onConnect: (result) => _connectWithAuthKey(context, result),
                ),
              ] else if (connected) ...[
                const SizedBox(height: 12),
                Text('安装', style: Theme.of(context).textTheme.titleMedium),
                const Text('完成设备验证后，可连续安装多个文件。'),
                const SizedBox(height: 8),
                InstallSplitButton(
                  preferredTarget: preferredInstallTarget,
                  enabled:
                      controller.sessionReady &&
                      !controller.installInProgress &&
                      !controller.timeSyncInProgress &&
                      !controller.statusRefreshInProgress,
                  onInstall: (target) => _pickAndTry(context, target),
                  onInstallFirmware: () => _pickFirmware(context),
                ),
                if (controller.latestTask case final task?)
                  InstallTaskCard(
                    task: task,
                    onCancel: controller.cancelInstall,
                    onRetry: controller.retryInstall,
                    onClear: controller.clearLatestTask,
                  ),
              ],
              const SizedBox(height: 12),
              DiagnosticLogToggle(
                entryCount: appLogger.length,
                enabled: diagnosticLogWindowOpen,
                onChanged: onDiagnosticLogWindowChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavedDevicesSection extends StatelessWidget {
  const _SavedDevicesSection({
    required this.bindings,
    required this.enabled,
    required this.onConnect,
  });

  final List<AuthKeyBinding> bindings;
  final bool enabled;
  final Future<bool> Function(AuthKeyBinding binding) onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: const ValueKey('saved-devices-section'),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Icon(Icons.history, size: 20, color: colors.primary),
                const SizedBox(width: 8),
                Text('已保存设备', style: theme.textTheme.titleMedium),
                const Spacer(),
                Text(
                  '${bindings.length} 台',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          for (var index = 0; index < bindings.length; index++) ...[
            if (index > 0) const Divider(height: 1),
            _SavedDeviceTile(
              binding: bindings[index],
              enabled: enabled,
              onConnect: onConnect,
            ),
          ],
        ],
      ),
    );
  }
}

class _SavedDeviceTile extends StatelessWidget {
  const _SavedDeviceTile({
    required this.binding,
    required this.enabled,
    required this.onConnect,
  });

  final AuthKeyBinding binding;
  final bool enabled;
  final Future<bool> Function(AuthKeyBinding binding) onConnect;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.watch_outlined),
    title: Text(
      binding.name.trim().isEmpty ? '已保存设备' : binding.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      binding.id,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontFamily: 'monospace'),
    ),
    trailing: OutlinedButton.icon(
      key: ValueKey('connect-saved-device-${binding.id}'),
      onPressed: enabled ? () => unawaited(onConnect(binding)) : null,
      icon: const Icon(Icons.link, size: 18),
      label: const Text('连接'),
    ),
  );
}

class _BluetoothUnavailableBanner extends StatelessWidget {
  const _BluetoothUnavailableBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('bluetooth-unavailable-banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.bluetooth_disabled, color: colors.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// 设备卡片上的统计块（电量/存储）。
class _DeviceStat extends StatelessWidget {
  const _DeviceStat({
    required this.icon,
    required this.value,
    required this.detail,
    required this.progress,
    this.progressColor,
  });

  final IconData icon;
  final String value;
  final String detail;
  final double progress;
  final Color? progressColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 4,
              color: progressColor ?? theme.colorScheme.primary,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(1)} KB';
}
