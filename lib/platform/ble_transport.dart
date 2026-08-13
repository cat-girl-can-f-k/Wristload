import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/protocol/transport_constants.dart';

/// Cross-platform BLE central wrapper plus the verified RFCOMM bridges.
///
/// Darwin's CoreBluetooth identifier is deliberately kept opaque: it is not a
/// Bluetooth MAC address. The macOS RFCOMM bridge therefore receives the full
/// CoreBluetooth peripheral identifier and advertised name, then resolves the
/// paired classic device natively.
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
      try {
        await _central.disconnect(peripheral);
      } catch (_) {
        // 保留发现失败作为主错误；断开是每轮失败后的 best-effort 清理。
      }
      if (attempt < discoverAttempts) {
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

  /// 触发系统经典蓝牙配对（bonding）。手环 9 的写入特征要求加密连接：
  /// 未配对时直接写入会被设备静默丢弃（read 正常、write 无回包——正是
  /// b8/b9 实测现象）。等价 Android 端首次连接的系统"绑定"确认。
  ///
  /// 直接走插件 Pigeon 通道（platform_interface 的 [CentralManager] 未暴露
  /// pairing API，这里直连 Windows 实现的 pair 通道）。
  ///
  /// On macOS, [advertisedName] is required alongside the opaque CoreBluetooth
  /// [uuid]. The native bridge uses that identity to resolve the paired classic
  /// Bluetooth device and returns its real address when available.
  Future<String?> pairDevice(UUID uuid, {String? advertisedName}) async {
    if (_isAndroid) {
      await _androidMethods.invokeMethod<void>('ensurePermissions');
      await _androidMethods.invokeMethod<void>('pair', _androidAddress(uuid));
      return _androidAddress(uuid);
    }
    if (_isMacOS) {
      final reply = await _macosMethods.invokeMethod<Object?>('pair',
          _macosIdentity(uuid, advertisedName));
      return _macosAddress(reply, 'pair');
    }
    _requireRfcommPlatform();
    final hex = uuid.toString().replaceAll('-', '');
    final address = int.parse(hex.substring(hex.length - 12), radix: 16);
    // Pigeon 通道消息体直接是 args 列表（BasicMessageChannel，非 MethodChannel）。
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerHostApi.pair',
      StandardMessageCodec(),
    );
    final reply = await channel.send(<Object?>[address]);
    _throwIfPigeonError(reply, 'pair');
    return _formatBluetoothAddress(address);
  }

  /// Persist the macOS CoreBluetooth-to-classic-device association only after
  /// the application-layer authkey handshake has authenticated the device.
  Future<void> confirmRfcommIdentity(
    UUID uuid, {
    String? advertisedName,
  }) async {
    if (!_isMacOS) return;
    await _macosMethods.invokeMethod<void>(
      'confirmIdentity',
      _macosIdentity(uuid, advertisedName),
    );
  }

  /// Windows 上若发现现存系统配对，则删除该配对记录并返回 true。
  /// Android 的公开 SDK 不允许应用静默 removeBond，因此保持 false。
  Future<bool> unpairIfPaired(UUID uuid) async {
    if (_isAndroid) return false;
    if (_isMacOS) return false;
    _requireRfcommPlatform();
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
  Future<String?> connectRfcomm(
    UUID uuid, {
    String? serviceUuid,
    String? advertisedName,
  }) async {
    _beginRfcommEpoch();
    if (_isAndroid) {
      await _androidMethods.invokeMethod<void>('ensurePermissions');
      await _androidMethods.invokeMethod<void>('connect', {
        'address': _androidAddress(uuid),
        'serviceUuid': serviceUuid ?? '00001101-0000-1000-8000-00805f9b34fb',
      });
      return _androidAddress(uuid);
    }
    if (_isMacOS) {
      // The Swift bridge resolves RFCOMM from peripheralId + advertised name;
      // never reinterpret a Darwin UUID as a MAC address.
      final reply = await _macosMethods.invokeMethod<Object?>(
        'connect',
        _macosIdentity(uuid, advertisedName),
      );
      return _macosAddress(reply, 'connect');
    }
    _requireRfcommPlatform();
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
    return _formatBluetoothAddress(address);
  }

  // StreamSocket.OutputStream only supports one pending write. ACK and the
  // following command can be scheduled from the same inbound callback, so all
  // platforms share this small FIFO instead of racing two native DataWriters.
  Future<void> _rfcommWriteTail = Future<void>.value();
  int _rfcommWriteEpoch = 0;

  int _beginRfcommEpoch() {
    _rfcommWriteEpoch++;
    _rfcommWriteTail = Future<void>.value();
    return _rfcommWriteEpoch;
  }

  /// 写 RFCOMM 数据（严格串行）。
  Future<void> rfcommWrite(UUID uuid, List<int> data) {
    final epoch = _rfcommWriteEpoch;
    final operation = _rfcommWriteTail.then(
      (_) async {
        if (epoch != _rfcommWriteEpoch) {
          throw StateError('RFCOMM connection changed while writing.');
        }
        await _rfcommWriteDirect(uuid, List<int>.from(data));
        if (epoch != _rfcommWriteEpoch) {
          throw StateError('RFCOMM connection changed while writing.');
        }
      },
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
    if (_isMacOS) {
      await _macosMethods.invokeMethod<void>(
        'write',
        Uint8List.fromList(data),
      );
      return;
    }
    _requireRfcommPlatform();
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
    final epoch = _beginRfcommEpoch();
    try {
      if (_isAndroid) {
        await _androidMethods.invokeMethod<void>('disconnect');
        return;
      }
      if (_isMacOS) {
        await _macosMethods.invokeMethod<void>('disconnect');
        return;
      }
      _requireRfcommPlatform();
      final hex = uuid.toString().replaceAll('-', '');
      final address = int.parse(hex.substring(hex.length - 12), radix: 16);
      const channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerHostApi.disconnectRfcomm',
        StandardMessageCodec(),
      );
      final reply = await channel.send(<Object?>[address]);
      _throwIfPigeonError(reply, 'disconnectRfcomm');
    } finally {
      if (epoch == _rfcommWriteEpoch) {
        _rfcommWriteTail = Future<void>.value();
      }
    }
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
  StreamSubscription<dynamic>? _macosRfcommSubscription;
  Stream<Uint8List> get rfcommData => _rfcommDataController.stream;

  static const _androidMethods = MethodChannel('wristload/rfcomm');
  static const _androidEvents = EventChannel('wristload/rfcomm/events');
  static const _macosMethods = MethodChannel('wristload/rfcomm');
  static const _macosEvents = EventChannel('wristload/rfcomm/events');
  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  bool get _isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

  void _requireRfcommPlatform() {
    if (defaultTargetPlatform != TargetPlatform.windows &&
        !_isAndroid &&
        !_isMacOS) {
      throw UnsupportedError(
          '当前平台尚未实现 RFCOMM 真实安装传输（Linux 仅支持 BLE 诊断）。');
    }
  }

  String _formatBluetoothAddress(int address) {
    final hex = address.toRadixString(16).padLeft(12, '0').toUpperCase();
    return List.generate(6, (index) => hex.substring(index * 2, index * 2 + 2))
        .join(':');
  }

  Map<String, Object> _macosIdentity(UUID uuid, String? advertisedName) {
    final name = advertisedName?.trim();
    if (name == null || name.isEmpty) {
      throw ArgumentError.value(
        advertisedName,
        'advertisedName',
        'macOS RFCOMM requires the non-empty advertised device name.',
      );
    }
    return <String, Object>{
      'peripheralId': uuid.toString(),
      // MacOSPlatformBridge.swift names this field `name`; keep the payload
      // explicit so a CoreBluetooth UUID can never be mistaken for a MAC.
      'name': name,
    };
  }

  String? _macosAddress(Object? reply, String operation) {
    if (reply == null) return null;
    if (reply is Map) {
      final address = reply['address'];
      if (address == null) return null;
      if (address is String && address.trim().isNotEmpty) {
        return address.trim();
      }
    }
    throw PlatformException(
      code: 'rfcomm_invalid_reply',
      message: 'macOS $operation returned an invalid classic Bluetooth identity.',
      details: reply,
    );
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
    if (_isMacOS) {
      _macosRfcommSubscription ??= _macosEvents
          .receiveBroadcastStream()
          .listen(
        (Object? value) {
          if (value is Uint8List && !_rfcommDataController.isClosed) {
            _rfcommDataController.add(value);
          } else if (value is List<int> && !_rfcommDataController.isClosed) {
            _rfcommDataController.add(Uint8List.fromList(value));
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
    await _macosRfcommSubscription?.cancel();
    _macosRfcommSubscription = null;
    if (!_isAndroid) {
      if (_isMacOS) {
        // EventChannel subscriptions are cancelled above; there is no Pigeon
        // handler to clear on Darwin.
      } else {
        const channel = BasicMessageChannel<Object?>(
          'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerFlutterApi.onRfcommData',
          StandardMessageCodec(),
        );
        channel.setMessageHandler(null);
      }
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
