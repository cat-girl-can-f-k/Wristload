import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'ble_transport.dart';

typedef DesktopV2ConnectionLog = void Function(String message);

/// Platform-owned preparation for a V2 desktop RFCOMM session.
///
/// The controller owns common connection state and the SPP/authkey handshake.
/// Each desktop platform owns only the identity resolution and pairing strategy
/// required before or during the RFCOMM connection.
abstract interface class DesktopV2Connection {
  const DesktopV2Connection();

  String get platformName;

  Future<String?> prepare({
    required BleTransport transport,
    required Peripheral peripheral,
    required String advertisedName,
    required bool directIdentity,
    required DesktopV2ConnectionLog log,
  });

}
