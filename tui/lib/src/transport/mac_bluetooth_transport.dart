library;

import 'dart:typed_data';

/// A real classic-Bluetooth (BR/EDR) device address.
///
/// It accepts the three user-facing forms used by Wristload, compares by a
/// separator-free uppercase key, and always renders in macOS' hyphenated form.
/// A CoreBluetooth peripheral UUID is deliberately not accepted.
final class MacBluetoothAddress {
  MacBluetoothAddress._(this.key);

  factory MacBluetoothAddress.parse(String input) {
    final value = input.trim();
    final compact = switch (value) {
      _ when RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(value) => value,
      _
          when RegExp(r'^(?:[0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2}$')
              .hasMatch(value) =>
        value.replaceAll('-', ''),
      _
          when RegExp(r'^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$')
              .hasMatch(value) =>
        value.replaceAll(':', ''),
      _ => throw const FormatException(
          '经典蓝牙地址必须是 12 位十六进制，可使用连字符或冒号分隔。',
        ),
    };
    return MacBluetoothAddress._(compact.toUpperCase());
  }

  static MacBluetoothAddress? tryParse(String input) {
    try {
      return MacBluetoothAddress.parse(input);
    } on FormatException {
      return null;
    }
  }

  /// Twelve uppercase hexadecimal digits, used for identity and de-duplication.
  final String key;

  String get display => [
        for (var offset = 0; offset < key.length; offset += 2)
          key.substring(offset, offset + 2),
      ].join('-');

  @override
  bool operator ==(Object other) =>
      other is MacBluetoothAddress && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => display;
}

enum MacBluetoothDeviceSource { inquiry, paired, manual }

/// A macOS classic-Bluetooth target whose identity comes from
/// `IOBluetoothDevice.addressString`.
final class MacBluetoothDevice {
  MacBluetoothDevice({
    required String address,
    required this.name,
    this.rssi,
    this.paired = false,
    this.source = MacBluetoothDeviceSource.manual,
  }) : bluetoothAddress = MacBluetoothAddress.parse(address);

  MacBluetoothDevice.fromBluetoothAddress({
    required this.bluetoothAddress,
    required this.name,
    this.rssi,
    this.paired = false,
    this.source = MacBluetoothDeviceSource.manual,
  });

  final MacBluetoothAddress bluetoothAddress;
  final String name;
  final int? rssi;
  final bool paired;
  final MacBluetoothDeviceSource source;

  String get address => bluetoothAddress.display;
  String get addressKey => bluetoothAddress.key;

  MacBluetoothDevice merge(MacBluetoothDevice other) {
    if (addressKey != other.addressKey) {
      throw ArgumentError('不能合并不同经典蓝牙地址的设备。');
    }
    return MacBluetoothDevice.fromBluetoothAddress(
      bluetoothAddress: bluetoothAddress,
      name: other.name.trim().isNotEmpty ? other.name : name,
      rssi: other.rssi ?? rssi,
      paired: paired || other.paired,
      source: other.paired ? other.source : source,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MacBluetoothDevice && other.addressKey == addressKey;

  @override
  int get hashCode => addressKey.hashCode;
}

enum MacBluetoothHelperState { stopped, starting, ready, failed, disposed }

class MacBluetoothTransportSnapshot {
  const MacBluetoothTransportSnapshot({
    required this.helperState,
    required this.scanning,
    required this.connected,
    this.message,
  });

  const MacBluetoothTransportSnapshot.stopped()
      : this(
          helperState: MacBluetoothHelperState.stopped,
          scanning: false,
          connected: false,
        );

  final MacBluetoothHelperState helperState;
  final bool scanning;
  final bool connected;
  final String? message;
}

/// Native boundary used by the pure-Dart installer backend.
///
/// Implementations must serialize every [write] in invocation order. A
/// completed write only means the bytes were submitted to RFCOMM; protocol ACKs
/// and business completion events remain the install backend's responsibility.
/// A successful [connect] future completes only after the native bridge has
/// emitted `connect.done` for a newly opened physical RFCOMM channel. That
/// completion is the sole boundary at which the backend may create a fresh
/// SPP sequence allocator. A logical auth/session epoch must never reset the
/// allocator while the same physical byte stream can still deliver bytes.
abstract interface class MacBluetoothTransport {
  Stream<Uint8List> get input;
  Stream<Object> get errors;
  Stream<MacBluetoothDevice> get discoveries;
  Stream<MacBluetoothTransportSnapshot> get snapshots;

  MacBluetoothTransportSnapshot get snapshot;

  Future<void> start();
  Future<List<MacBluetoothDevice>> listPairedDevices();
  Future<void> startScan({Duration duration = const Duration(seconds: 10)});
  Future<void> stopScan();
  Future<void> connect(
    MacBluetoothDevice device, {
    String serviceUuid = '00001101-0000-1000-8000-00805f9b34fb',
  });
  Future<void> write(List<int> bytes);
  Future<void> disconnect();
  Future<void> dispose();
}
