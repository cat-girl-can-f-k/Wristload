import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/protocol/transport_constants.dart';

/// Windows-first BLE central wrapper. The plugin maps to native Windows BLE;
/// its Android and Linux backends keep this boundary portable.
class BleTransport {
  BleTransport();

  // Creating the platform channel is deferred until a BLE operation is used.
  // This keeps presentation-only consumers independent from native Bluetooth.
  late final CentralManager _central = CentralManager();

  /// 服务发现重试次数（Windows BLE 首次连接后 GATT 事务可能未就绪，
  /// 且手环 9 的特征枚举偶发失败/为空——实测需多次重连才成功）。
  static const int discoverAttempts = 8;

  Stream<DiscoveredEventArgs> get discoveries => _central.discovered;

  Future<void> startScan() async {
    if (_isAndroid) {
      await _androidMethods.invokeMethod<void>('ensurePermissions');
    }
    await _central.startDiscovery();
  }

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

  Future<void> disconnect(Peripheral peripheral) =>
      _central.disconnect(peripheral);

  /// 触发 Windows 系统配对（bonding）。手环 9 的写入特征要求加密连接：
  /// 未配对时直接写入会被设备静默丢弃（read 正常、write 无回包——正是
  /// b8/b9 实测现象）。等价 Android 端首次连接的系统"绑定"确认。
  ///
  /// 直接走插件 Pigeon 通道（platform_interface 的 [CentralManager] 未暴露
  /// pairing API，这里直连 Windows 实现的 pair 通道）。仅 Windows 可用。
  /// [uuid] 末 6 字节即 Windows 蓝牙地址（48-bit MAC）。
  Future<void> pairDevice(UUID uuid) async {
    if (_isAndroid) {
      await _androidMethods.invokeMethod<void>('ensurePermissions');
      await _androidMethods.invokeMethod<void>('pair', _androidAddress(uuid));
      return;
    }
    _requireWindowsOrAndroid();
    final hex = uuid.toString().replaceAll('-', '');
    final address = int.parse(hex.substring(hex.length - 12), radix: 16);
    // Pigeon 通道消息体直接是 args 列表（BasicMessageChannel，非 MethodChannel）。
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerHostApi.pair',
      StandardMessageCodec(),
    );
    final reply = await channel.send(<Object?>[address]);
    _throwIfPigeonError(reply, 'pair');
  }

  /// Windows 上若发现现存系统配对，则删除该配对记录并返回 true。
  /// Android 的公开 SDK 不允许应用静默 removeBond，因此保持 false。
  Future<bool> unpairIfPaired(UUID uuid) async {
    if (_isAndroid) return false;
    _requireWindowsOrAndroid();
    final hex = uuid.toString().replaceAll('-', '');
    final address = int.parse(hex.substring(hex.length - 12), radix: 16);
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerHostApi.unpairIfPaired',
      StandardMessageCodec(),
    );
    final reply = await channel.send(<Object?>[address]);
    _throwIfPigeonError(reply, 'unpairIfPaired');
    final value = (reply as List<Object?>).firstOrNull;
    if (value is! bool) {
      throw PlatformException(
        code: 'pigeon_invalid_reply',
        message: 'unpairIfPaired did not return a boolean result.',
      );
    }
    return value;
  }

  /// 经典蓝牙（BR/EDR）RFCOMM 串口连接（手环 9 系主通道）。
  /// [serviceUuid] 为 RFCOMM 服务 UUID（默认 SPP `00001101-...`）。
  /// 返回后连接即建立，数据经 [rfcommData] 流推送。
  Future<void> connectRfcomm(UUID uuid, {String? serviceUuid}) async {
    if (_isAndroid) {
      await _androidMethods.invokeMethod<void>('ensurePermissions');
      await _androidMethods.invokeMethod<void>('connect', {
        'address': _androidAddress(uuid),
        'serviceUuid': serviceUuid ?? '00001101-0000-1000-8000-00805f9b34fb',
      });
      return;
    }
    _requireWindowsOrAndroid();
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

  // StreamSocket.OutputStream only supports one pending write. ACK and the
  // following command can be scheduled from the same inbound callback, so all
  // platforms share this small FIFO instead of racing two native DataWriters.
  Future<void> _rfcommWriteTail = Future<void>.value();

  /// 写 RFCOMM 数据（严格串行）。
  Future<void> rfcommWrite(UUID uuid, List<int> data) {
    final operation = _rfcommWriteTail.then(
      (_) => _rfcommWriteDirect(uuid, List<int>.from(data)),
    );
    // A failed packet is reported to its caller but must not poison the queue.
    _rfcommWriteTail = operation.then<void>((_) {}, onError: (_) {});
    return operation;
  }

  Future<void> _rfcommWriteDirect(UUID uuid, List<int> data) async {
    if (_isAndroid) {
      await _androidMethods.invokeMethod<void>(
          'write', Uint8List.fromList(data));
      return;
    }
    _requireWindowsOrAndroid();
    final hex = uuid.toString().replaceAll('-', '');
    final address = int.parse(hex.substring(hex.length - 12), radix: 16);
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerHostApi.rfcommWrite',
      StandardMessageCodec(),
    );
    final reply =
        await channel.send(<Object?>[address, Uint8List.fromList(data)]);
    _throwIfPigeonError(reply, 'rfcommWrite');
  }

  /// 断开 RFCOMM。
  Future<void> disconnectRfcomm(UUID uuid) async {
    if (_isAndroid) {
      await _androidMethods.invokeMethod<void>('disconnect');
      return;
    }
    _requireWindowsOrAndroid();
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
  StreamSubscription<dynamic>? _androidRfcommSubscription;
  Stream<Uint8List> get rfcommData => _rfcommDataController.stream;

  static const _androidMethods = MethodChannel('miwearable/rfcomm');
  static const _androidEvents = EventChannel('miwearable/rfcomm/events');
  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  void _requireWindowsOrAndroid() {
    if (defaultTargetPlatform != TargetPlatform.windows) {
      throw UnsupportedError('本版本 Linux 尚未实现 RFCOMM 真实安装传输。');
    }
  }

  String _androidAddress(UUID uuid) {
    final hex = uuid.toString().replaceAll('-', '');
    final mac = hex.substring(hex.length - 12).toUpperCase();
    return List.generate(6, (index) => mac.substring(index * 2, index * 2 + 2))
        .join(':');
  }

  /// 注册 RFCOMM 数据回调（监听 C++ 侧 Pigeon FlutterApi `onRfcommData`）。
  void listenRfcommData() {
    if (_isAndroid) {
      _androidRfcommSubscription ??=
          _androidEvents.receiveBroadcastStream().listen(
        (Object? value) {
          if (value is Uint8List && !_rfcommDataController.isClosed) {
            _rfcommDataController.add(value);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!_rfcommDataController.isClosed) {
            _rfcommDataController.addError(error, stackTrace);
          }
        },
      );
      return;
    }
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerFlutterApi.onRfcommData',
      StandardMessageCodec(),
    );
    channel.setMessageHandler((message) async {
      final args = message as List<Object?>?;
      if (args == null || args.length < 2) return null;
      final data = args[1];
      if (data is Uint8List && !_rfcommDataController.isClosed) {
        _rfcommDataController.add(data);
      }
      return null;
    });
  }

  Future<void> disposeRfcommStream() async {
    await _androidRfcommSubscription?.cancel();
    _androidRfcommSubscription = null;
    if (!_isAndroid) {
      const channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerFlutterApi.onRfcommData',
        StandardMessageCodec(),
      );
      channel.setMessageHandler(null);
    }
    if (!_rfcommDataController.isClosed) {
      await _rfcommDataController.close();
    }
  }

  /// 读取特征值（只读操作，用于版本特征等被动读取，不发送任何写帧）。
  Future<Uint8List> readCharacteristic(
    Peripheral peripheral,
    GATTCharacteristic characteristic,
  ) =>
      _central.readCharacteristic(peripheral, characteristic);
}
