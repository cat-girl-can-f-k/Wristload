import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/device_controller.dart';

/// 设备信息查看页。
class DeviceInfoPage extends StatelessWidget {
  const DeviceInfoPage({required this.controller, super.key});

  final DeviceController controller;

  @override
  Widget build(BuildContext context) {
    final device = controller.connectedDevice;
    return Scaffold(
      appBar: AppBar(title: const Text('设备信息')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final mac = device == null
              ? null
              : _formatMac(device.uuid.toString());
          final firmware = controller.connectedFirmwareVersion;
          final model = controller.connectedDeviceName ??
              controller.connectedProfile?.displayName;
          final battery = controller.batteryPercent;
          final storageTotal = controller.storageTotalBytes;
          final storageUsed = controller.storageUsedBytes;
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
                title: const Text('MAC 地址'),
                subtitle: Text(mac ?? '未连接'),
              ),
              const ListTile(
                leading: Icon(Icons.link),
                title: Text('连接方式'),
                subtitle: Text('经典蓝牙 RFCOMM（SPP）'),
              ),
              ListTile(
                leading: const Icon(Icons.key),
                title: const Text('authkey'),
                subtitle: Text(controller.authKey ?? '未设置'),
                trailing: controller.authKey == null
                    ? null
                    : IconButton(
                        tooltip: '复制 authkey',
                        icon: const Icon(Icons.copy),
                        onPressed: () {
                          Clipboard.setData(
                              ClipboardData(text: controller.authKey!));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('authkey 已复制')),
                          );
                        },
                      ),
              ),
              if (battery != null)
                ListTile(
                  leading: const Icon(Icons.battery_std),
                  title: const Text('电量'),
                  subtitle: Text('$battery%'),
                ),
              if (storageTotal != null)
                ListTile(
                  leading: const Icon(Icons.sd_storage),
                  title: const Text('存储'),
                  subtitle: Text(
                      '${_formatBytes(storageUsed ?? 0)} / ${_formatBytes(storageTotal)}'),
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
