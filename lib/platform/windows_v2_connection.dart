import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'ble_transport.dart';
import 'desktop_v2_connection.dart';

/// Windows V2 preparation uses the BLE advertisement address to request the
/// system classic-Bluetooth pairing before opening RFCOMM.
class WindowsV2Connection implements DesktopV2Connection {
  const WindowsV2Connection();

  @override
  String get platformName => 'Windows';

  @override
  Future<String?> prepare({
    required BleTransport transport,
    required Peripheral peripheral,
    required String advertisedName,
    required bool directIdentity,
    required DesktopV2ConnectionLog log,
  }) async {
    // Windows has no persisted CoreBluetooth-to-classic identity mapping.
    // A direct identity request is therefore still resolved through pairing.
    if (directIdentity) {
      log('Windows 未使用 macOS 身份映射；重新确认系统经典蓝牙配对。');
    }
    log('Windows：先检查系统经典蓝牙配对，再建立 RFCOMM；不创建临时 GATT 链路。');
    return transport.pairDevice(peripheral.uuid, advertisedName: advertisedName);
  }
}
