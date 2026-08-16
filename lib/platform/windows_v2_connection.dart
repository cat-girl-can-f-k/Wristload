import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'ble_transport.dart';
import 'desktop_v2_connection.dart';

/// Windows V2 defers system pairing to the RFCOMM connection itself.
///
/// The historical Windows flow issued a single pairing request while resolving
/// the serial-port service. Running [BleTransport.pairDevice] here first creates
/// a second, BLE-only pairing ceremony before the useful RFCOMM pairing.
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
    log('Windows：不执行前置 BLE 绑定；由 RFCOMM 建链一次性完成系统蓝牙绑定。');
    return null;
  }
}
