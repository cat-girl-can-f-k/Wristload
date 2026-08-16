import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'ble_transport.dart';
import 'desktop_v2_connection.dart';

/// macOS V2 preparation keeps CoreBluetooth UUIDs opaque and lets the native
/// bridge resolve the associated classic-Bluetooth identity.
class MacosV2Connection implements DesktopV2Connection {
  const MacosV2Connection();

  @override
  String get platformName => 'macOS';

  @override
  Future<String?> prepare({
    required BleTransport transport,
    required Peripheral peripheral,
    required String advertisedName,
    required bool directIdentity,
    required DesktopV2ConnectionLog log,
  }) async {
    // Pairing can emit native events before connectSpp attaches its stream.
    transport.listenRfcommData();
    log('已启用 macOS 经典蓝牙原生日志；等待系统配对与 SPP 建链事件。');
    if (directIdentity) {
      log('已复用已确认的 macOS 经典蓝牙身份映射；直接建立 RFCOMM。');
      return null;
    }
    log('macOS：先检查系统经典蓝牙配对，再建立 RFCOMM；不创建临时 GATT 链路。');
    return transport.pairDevice(peripheral.uuid, advertisedName: advertisedName);
  }
}
