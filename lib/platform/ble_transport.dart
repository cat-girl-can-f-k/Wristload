import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/services.dart';

import '../domain/protocol/l1_l2_frame.dart';

/// Windows-first BLE central wrapper. The plugin maps to native Windows BLE;
/// its Android and Linux backends keep this boundary portable.
class BleTransport {
  BleTransport() : _central = CentralManager();

  final CentralManager _central;

  /// 服务发现重试次数（Windows BLE 首次连接后 GATT 事务可能未就绪，
  /// 且手环 9 的特征枚举偶发失败/为空——实测需多次重连才成功）。
  static const int discoverAttempts = 8;

  Stream<DiscoveredEventArgs> get discoveries => _central.discovered;

  Future<void> startScan() => _central.startDiscovery();

  Future<void> stopScan() => _central.stopDiscovery();

  /// 连接并枚举 GATT 服务。成功判定：**MI Wear 服务（fe95）必须存在且包含
  /// 版本/写/通知三个特征**（00000050 / 0000005f / 0000005e）。
  ///
  /// 每次失败会**断开连接后重新连接**再枚举（Windows 侧残留状态会污染
  /// 下次枚举，重连能刷新），最多 [discoverAttempts] 轮。
  Future<List<GATTService>> connectAndDiscover(Peripheral peripheral) async {
    Object? lastError;
    for (var attempt = 1; attempt <= discoverAttempts; attempt++) {
      try {
        await _central.connect(peripheral);
        final services = await _central.discoverGATT(peripheral);
        if (_hasFullMiWearService(services)) {
          return services;
        }
        lastError = 'MI Wear 服务 fe95 缺失或特征不全（尝试 $attempt）';
      } catch (exception) {
        lastError = exception;
      }
      if (attempt < discoverAttempts) {
        try {
          await _central.disconnect(peripheral);
        } catch (_) {
          // 忽略断开失败，继续重试。
        }
        await Future.delayed(Duration(milliseconds: 600 * attempt));
      }
    }
    throw Exception('GATT 服务发现失败（重试 $discoverAttempts 轮）：$lastError');
  }

  /// fe95 服务存在且含版本(50)/通知(5e)/写(5f)三特征。
  bool _hasFullMiWearService(List<GATTService> services) {
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() != SarGatt.serviceUuid) {
        continue;
      }
      final uuids = service.characteristics
          .map((c) => c.uuid.toString().toLowerCase())
          .toSet();
      return uuids.contains(SarGatt.versionUuid) &&
          uuids.contains(SarGatt.notifyUuid) &&
          uuids.contains(SarGatt.writeUuid);
    }
    return false;
  }

  Future<void> disconnect(Peripheral peripheral) => _central.disconnect(peripheral);

  /// 触发 Windows 系统配对（bonding）。手环 9 的写入特征要求加密连接：
  /// 未配对时直接写入会被设备静默丢弃（read 正常、write 无回包——正是
  /// b8/b9 实测现象）。等价 Android 端首次连接的系统"绑定"确认。
  ///
  /// 直接走插件 Pigeon 通道（platform_interface 的 [CentralManager] 未暴露
  /// pairing API，这里直连 Windows 实现的 pair 通道）。仅 Windows 可用。
  /// [uuid] 末 6 字节即 Windows 蓝牙地址（48-bit MAC）。
  Future<void> pairDevice(UUID uuid) async {
    final hex = uuid.toString().replaceAll('-', '');
    final address = int.parse(hex.substring(hex.length - 12), radix: 16);
    // Pigeon 通道消息体直接是 args 列表（BasicMessageChannel，非 MethodChannel）。
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerHostApi.pair',
      StandardMessageCodec(),
    );
    await channel.send(<Object?>[address]);
  }

  /// 经典蓝牙（BR/EDR）RFCOMM 串口连接（手环 9 系主通道）。
  /// [serviceUuid] 为 RFCOMM 服务 UUID（默认 SPP `00001101-...`）。
  /// 返回后连接即建立，数据经 [rfcommData] 流推送。
  Future<void> connectRfcomm(UUID uuid, {String? serviceUuid}) async {
    final hex = uuid.toString().replaceAll('-', '');
    final address = int.parse(hex.substring(hex.length - 12), radix: 16);
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerHostApi.connectRfcomm',
      StandardMessageCodec(),
    );
    final reply = await channel.send(<Object?>[
      address,
      serviceUuid ?? '00001101-0000-1000-8000-00805f9b34fb',
    ]);
    _throwIfPigeonError(reply, 'connectRfcomm');
  }

  /// 写 RFCOMM 数据。
  Future<void> rfcommWrite(UUID uuid, List<int> data) async {
    final hex = uuid.toString().replaceAll('-', '');
    final address = int.parse(hex.substring(hex.length - 12), radix: 16);
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerHostApi.rfcommWrite',
      StandardMessageCodec(),
    );
    final reply = await channel.send(<Object?>[address, Uint8List.fromList(data)]);
    _throwIfPigeonError(reply, 'rfcommWrite');
  }

  /// 断开 RFCOMM。
  Future<void> disconnectRfcomm(UUID uuid) async {
    final hex = uuid.toString().replaceAll('-', '');
    final address = int.parse(hex.substring(hex.length - 12), radix: 16);
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerHostApi.disconnectRfcomm',
      StandardMessageCodec(),
    );
    final reply = await channel.send(<Object?>[address]);
    _throwIfPigeonError(reply, 'disconnectRfcomm');
  }

  /// The Windows plugin exposes the RFCOMM additions through Pigeon channels.
  /// A raw [BasicMessageChannel] does not throw for a native error by itself:
  /// Pigeon returns `[code, message, details]`. Decode that envelope here so
  /// callers never report a successful connection/write when Windows rejected it.
  void _throwIfPigeonError(Object? reply, String operation) {
    if (reply is! List<Object?> || reply.isEmpty) {
      throw PlatformException(
        code: 'pigeon_no_reply',
        message: '$operation did not return a valid native reply.',
      );
    }
    if (reply.length > 1) {
      throw PlatformException(
        code: reply[0]?.toString() ?? 'native_error',
        message: reply[1]?.toString() ?? '$operation failed.',
        details: reply.length > 2 ? reply[2] : null,
      );
    }
  }

  final StreamController<Uint8List> _rfcommDataController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get rfcommData => _rfcommDataController.stream;

  /// 注册 RFCOMM 数据回调（监听 C++ 侧 Pigeon FlutterApi `onRfcommData`）。
  void listenRfcommData() {
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerFlutterApi.onRfcommData',
      StandardMessageCodec(),
    );
    channel.setMessageHandler((message) async {
      final args = message as List<Object?>?;
      if (args == null || args.length < 2) return null;
      final data = args[1];
      if (data is Uint8List) {
        _rfcommDataController.add(data);
      }
      return null;
    });
  }

  void disposeRfcommStream() {
    _rfcommDataController.close();
  }

  /// 读取特征值（只读操作，用于版本特征等被动读取，不发送任何写帧）。
  Future<Uint8List> readCharacteristic(
    Peripheral peripheral,
    GATTCharacteristic characteristic,
  ) => _central.readCharacteristic(peripheral, characteristic);

  /// 写入特征值。优先 [withResponse]；若失败（手环 5f 特征可能只支持
  /// write-without-response），自动切换另一 write type 重试一次。
  Future<void> write(
    Peripheral peripheral,
    GATTCharacteristic characteristic,
    List<int> value, {
    bool withResponse = true,
  }) async {
    final valueBytes = Uint8List.fromList(value);
    try {
      await _central.writeCharacteristic(
        peripheral,
        characteristic,
        value: valueBytes,
        type: withResponse
            ? GATTCharacteristicWriteType.withResponse
            : GATTCharacteristicWriteType.withoutResponse,
      );
      return;
    } on PlatformException {
      final fallback = !withResponse;
      try {
        await _central.writeCharacteristic(
          peripheral,
          characteristic,
          value: valueBytes,
          type: fallback
              ? GATTCharacteristicWriteType.withResponse
              : GATTCharacteristicWriteType.withoutResponse,
        );
        return;
      } on PlatformException {
        // 两种 write type 都失败，抛出原始错误。
        rethrow;
      }
    }
  }

  /// 开启/关闭特征通知。
  Future<void> setNotify(
    Peripheral peripheral,
    GATTCharacteristic characteristic, {
    required bool state,
  }) => _central.setCharacteristicNotifyState(
        peripheral,
        characteristic,
        state: state,
      );

  /// 特征通知值流。
  Stream<GATTCharacteristicNotifiedEventArgs> get characteristicNotified =>
      _central.characteristicNotified;
}
