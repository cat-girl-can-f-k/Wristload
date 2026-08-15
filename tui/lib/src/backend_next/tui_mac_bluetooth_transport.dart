/// TUI-owned transport boundary for macOS classic Bluetooth.
///
/// This file intentionally contains only immutable transport DTOs and the
/// narrow operations the standalone TUI needs. JSONL/native details live in a
/// separate bridge implementation and never leak into the application layer.
library;

import 'dart:typed_data';

final class TuiBluetoothAddress {
  TuiBluetoothAddress._(this.key);

  factory TuiBluetoothAddress.parse(String value) {
    final input = value.trim();
    final compact = switch (input) {
      _ when RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(input) => input,
      _
          when RegExp(r'^(?:[0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2}$')
              .hasMatch(input) =>
        input.replaceAll('-', ''),
      _
          when RegExp(r'^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$')
              .hasMatch(input) =>
        input.replaceAll(':', ''),
      _ => throw const FormatException('经典蓝牙地址必须是 12 位十六进制，可使用连字符或冒号分隔。'),
    };
    return TuiBluetoothAddress._(compact.toUpperCase());
  }

  final String key;

  String get display => [
        for (var offset = 0; offset < key.length; offset += 2)
          key.substring(offset, offset + 2),
      ].join('-');

  @override
  bool operator ==(Object other) =>
      other is TuiBluetoothAddress && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

enum TuiTransportDeviceSource { inquiry, paired, manual }

final class TuiTransportDevice {
  TuiTransportDevice({
    required String address,
    required this.name,
    this.rssi,
    this.paired = false,
    this.source = TuiTransportDeviceSource.manual,
  }) : bluetoothAddress = TuiBluetoothAddress.parse(address);

  TuiTransportDevice.fromAddress({
    required this.bluetoothAddress,
    required this.name,
    this.rssi,
    this.paired = false,
    this.source = TuiTransportDeviceSource.manual,
  });

  final TuiBluetoothAddress bluetoothAddress;
  final String name;
  final int? rssi;
  final bool paired;
  final TuiTransportDeviceSource source;

  String get address => bluetoothAddress.display;
  String get addressKey => bluetoothAddress.key;

  TuiTransportDevice merge(TuiTransportDevice other) {
    if (addressKey != other.addressKey) {
      throw ArgumentError('不能合并不同经典蓝牙地址的设备。');
    }
    return TuiTransportDevice.fromAddress(
      bluetoothAddress: bluetoothAddress,
      name: other.name.trim().isNotEmpty ? other.name : name,
      rssi: other.rssi ?? rssi,
      paired: paired || other.paired,
      source: other.paired ? other.source : source,
    );
  }
}

enum TuiMacHelperState { stopped, starting, ready, failed, disposed }

final class TuiMacTransportSnapshot {
  const TuiMacTransportSnapshot({
    required this.helperState,
    required this.scanning,
    required this.connected,
    this.message,
  });

  const TuiMacTransportSnapshot.stopped()
      : this(
          helperState: TuiMacHelperState.stopped,
          scanning: false,
          connected: false,
        );

  final TuiMacHelperState helperState;
  final bool scanning;
  final bool connected;
  final String? message;
}

abstract interface class TuiMacBluetoothTransport {
  Stream<Uint8List> get input;
  Stream<Object> get errors;
  Stream<TuiTransportDevice> get discoveries;
  Stream<TuiMacTransportSnapshot> get snapshots;

  TuiMacTransportSnapshot get snapshot;

  Future<void> start();
  Future<List<TuiTransportDevice>> listPairedDevices();
  Future<void> startScan({Duration duration = const Duration(seconds: 10)});
  Future<void> stopScan();
  Future<void> connect(
    TuiTransportDevice device, {
    String serviceUuid = '00001101-0000-1000-8000-00805f9b34fb',
  });
  Future<void> write(List<int> bytes);
  Future<void> disconnect();
  Future<void> dispose();
}

final class TuiNativeTransportException implements Exception {
  const TuiNativeTransportException(this.code, this.message);

  factory TuiNativeTransportException.fromJson(Map<String, Object?> value) =>
      TuiNativeTransportException(
        value['code'] is String ? value['code']! as String : 'native_error',
        value['message'] is String
            ? value['message']! as String
            : '原生 helper 错误',
      );

  final String code;
  final String message;

  @override
  String toString() => 'TuiNativeTransportException($code): $message';
}

final class TuiTransportProtocolException implements Exception {
  const TuiTransportProtocolException(this.message);

  final String message;

  @override
  String toString() => 'TuiTransportProtocolException: $message';
}
