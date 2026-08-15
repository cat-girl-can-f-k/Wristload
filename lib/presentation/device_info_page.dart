import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../application/device_controller.dart';

/// 设备信息查看页。
///
/// 这个页面只能展示已经完成应用层 authkey 鉴权的当前会话。系统蓝牙
/// 配对、RFCOMM 建链中，或一个已经失效的连接都不是可供用户操作的
/// "已连接设备"。路由入口会先做同样的检查；这里再检查一次，防止
/// 在页面打开后断开时保留过期设备详情。
class DeviceInfoPage extends StatefulWidget {
  const DeviceInfoPage({required this.controller, super.key});

  final DeviceController controller;

  static bool hasVerifiedSession(DeviceController controller) =>
      controller.connectedDevice != null &&
      controller.isConnected &&
      controller.sessionReady;

  @override
  State<DeviceInfoPage> createState() => _DeviceInfoPageState();
}

class _DeviceInfoPageState extends State<DeviceInfoPage> {
  bool _leaveScheduled = false;
  bool _deletingSavedDevice = false;

  DeviceController get controller => widget.controller;

  void _leaveWhenSessionIsUnavailable() {
    if (_leaveScheduled) return;
    _leaveScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _leaveScheduled = false;
      if (!mounted || DeviceInfoPage.hasVerifiedSession(controller)) return;
      // A delete-confirmation dialog can be above this route. Popping only
      // one route would dismiss the dialog and leave stale details visible.
      final navigator = Navigator.of(context, rootNavigator: true);
      if (navigator.canPop()) {
        navigator.popUntil((route) => route.isFirst);
      }
    });
  }

  Future<void> _deleteSavedDevice(
    BuildContext context, {
    required String deviceId,
    required String? deviceName,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: const Text('删除已保存设备？'),
          content: Text(
            '将删除${deviceName ?? '此设备'}在 Wristload 本机保存的 authkey、历史绑定和经典蓝牙身份映射。'
            '当前连接不会断开，也不会删除系统蓝牙配对；下次连接时必须手动输入 authkey。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除设备'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted || _deletingSavedDevice) return;

    // The dialog can remain open while the user disconnects or starts a new
    // connection. Do not let a stale details page remove records belonging to
    // a different device.
    final device = controller.connectedDevice;
    if (!DeviceInfoPage.hasVerifiedSession(controller) ||
        device == null ||
        device.uuid.toString() != deviceId) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('设备连接已结束或已改变，未删除已保存设备。')),
      );
      return;
    }

    setState(() => _deletingSavedDevice = true);
    final removed = await controller.deleteSavedDevice(device.uuid);
    if (!context.mounted) return;
    setState(() => _deletingSavedDevice = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          removed
              ? '已删除已保存设备；下次连接需要手动输入 authkey。'
              : '已从当前会话移除凭据，但部分已保存设备信息未能清除。',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设备信息')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final device = controller.connectedDevice;
          if (device == null || !DeviceInfoPage.hasVerifiedSession(controller)) {
            _leaveWhenSessionIsUnavailable();
            return const _UnavailableDeviceInfo();
          }
          final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
          final identifier = device.uuid.toString();
          final classicAddress = controller.connectedClassicAddress;
          final mac = isMacOS
              ? null
              : classicAddress ?? _formatMac(identifier);
          final firmware = controller.connectedFirmwareVersion;
          final model = controller.connectedDeviceName ??
              controller.connectedProfile?.displayName;
          final battery = controller.batteryPercent;
          final storageTotal = controller.storageTotalBytes;
          final storageUsed = controller.storageUsedBytes;
          final authKey = controller.authKey;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                leading: const Icon(Icons.devices),
                title: const Text('设备型号'),
                subtitle: Text(model ?? '未知'),
              ),
              ListTile(
                leading: const Icon(Icons.memory),
                title: const Text('固件版本'),
                subtitle: Text(firmware ?? '未知'),
              ),
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: Text(isMacOS ? '设备标识' : 'MAC 地址'),
                subtitle: Text(isMacOS ? identifier : mac ?? '未连接'),
              ),
              if (isMacOS && classicAddress != null)
                ListTile(
                  leading: const Icon(Icons.settings_bluetooth),
                  title: const Text('经典蓝牙地址'),
                  subtitle: Text(classicAddress),
                ),
              const ListTile(
                leading: Icon(Icons.link),
                title: Text('连接方式'),
                subtitle: Text('蓝牙'),
              ),
              _AuthKeyTile(value: authKey),
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 4, bottom: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const ValueKey('delete-saved-device-button'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.error,
                      side: BorderSide(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    onPressed: _deletingSavedDevice
                        ? null
                        : () => _deleteSavedDevice(
                              context,
                              deviceId: identifier,
                              deviceName: model,
                            ),
                    icon: _deletingSavedDevice
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.delete_outline),
                    label: Text(_deletingSavedDevice ? '正在删除…' : '删除已保存设备'),
                  ),
                ),
              ),
              if (battery != null && battery >= 0 && battery <= 100)
                ListTile(
                  leading: const Icon(Icons.battery_std),
                  title: const Text('电量'),
                  subtitle: Text('$battery%'),
                ),
              if (storageUsed != null &&
                  storageTotal != null &&
                  storageTotal > 0 &&
                  storageUsed <= storageTotal)
                ListTile(
                  leading: const Icon(Icons.sd_storage),
                  title: const Text('存储'),
                  subtitle: Text(
                      '${_formatBytes(storageUsed)} / ${_formatBytes(storageTotal)}'),
                ),
              ListTile(
                leading: const Icon(Icons.sync),
                title: const Text('上次同步时间'),
                subtitle: Text(controller.lastTimeSyncSummary ?? '尚未同步'),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _formatMac(String uuid) {
    // uuid 形如 00000000-0000-0000-0000-d0ae050cccf2
    final hex = uuid.replaceAll('-', '');
    final macHex = hex.substring(hex.length - 12).toUpperCase();
    final parts = <String>[];
    for (var i = 0; i < macHex.length; i += 2) {
      parts.add(macHex.substring(i, i + 2));
    }
    return parts.join(':');
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
}

class _UnavailableDeviceInfo extends StatelessWidget {
  const _UnavailableDeviceInfo();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '设备未处于已验证连接状态，无法查看设备详情。',
            textAlign: TextAlign.center,
          ),
        ),
      );
}

class _AuthKeyTile extends StatefulWidget {
  const _AuthKeyTile({required this.value});
  final String? value;
  @override
  State<_AuthKeyTile> createState() => _AuthKeyTileState();
}

class _AuthKeyTileState extends State<_AuthKeyTile> {
  bool _revealed = false;

  @override
  void didUpdateWidget(covariant _AuthKeyTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) _revealed = false;
  }

  Future<void> _copy() async {
    final value = widget.value;
    if (value == null) return;
    setState(() => _revealed = true);
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('authkey 已复制')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    final shown = value == null
        ? '未设置'
        : _revealed || value.length <= 8
            ? value
            : '${value.substring(0, 4)}******${value.substring(value.length - 4)}';
    return ListTile(
      onTap: value == null ? null : () => setState(() => _revealed = true),
      leading: const Icon(Icons.key),
      title: const Text('authkey'),
      subtitle: SelectableText(
        shown,
        style: const TextStyle(fontFamily: 'monospace'),
      ),
      trailing: value == null
          ? null
          : IconButton(
              tooltip: '复制 authkey',
              icon: const Icon(Icons.copy),
              onPressed: _copy,
            ),
    );
  }
}
