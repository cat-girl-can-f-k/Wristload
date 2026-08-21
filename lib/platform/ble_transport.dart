import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../domain/protocol/transport_constants.dart';
import '../application/diagnostic_log_service.dart';

/// macOS CoreBluetooth/TCC authorization as reported by the native bridge.
///
/// This is deliberately separate from [BluetoothLowEnergyState]: adapter
/// power is a CoreBluetooth manager state, while TCC authorization determines
/// whether the app may use that manager at all.
enum BluetoothAuthorizationStatus {
  unknown,
  notDetermined,
  authorized,
  denied,
  restricted,
}

extension BluetoothAuthorizationStatusX on BluetoothAuthorizationStatus {
  bool get isAuthorized => this == BluetoothAuthorizationStatus.authorized;

  bool get needsSettings =>
      this == BluetoothAuthorizationStatus.denied ||
      this == BluetoothAuthorizationStatus.restricted;
}

/// A native RFCOMM payload paired with the CoreBluetooth identity that owns
/// the channel. macOS uses this tag to keep one watch's protocol frames out of
/// another watch's authenticated session.
class RfcommDataEvent {
  const RfcommDataEvent({
    required this.data,
    this.peripheralId,
    this.generation,
  });

  final Uint8List data;
  final String? peripheralId;
  final int? generation;
}

/// A per-device RFCOMM close notification from the macOS native bridge.
class RfcommClosedEvent {
  const RfcommClosedEvent({
    required this.peripheralId,
    required this.code,
    required this.message,
    this.generation,
  });

  final String peripheralId;
  final String? code;
  final String? message;
  final int? generation;
}

/// Cross-platform BLE central wrapper plus the verified RFCOMM bridges.
///
/// Darwin's CoreBluetooth identifier is deliberately kept opaque: it is not a
/// Bluetooth MAC address. The macOS RFCOMM bridge therefore receives the full
/// CoreBluetooth peripheral identifier and advertised name, then resolves the
/// paired classic device natively.
class BleTransport {
  BleTransport({DiagnosticLogService? logger}) : _logger = logger ?? appLogger;

  final DiagnosticLogService _logger;

  void _trace(String message, {Map<String, Object?> fields = const {}}) =>
      _logger.trace(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.BluetoothPlatform',
        fields: fields,
      );

  void _debug(String message, {Map<String, Object?> fields = const {}}) =>
      _logger.debug(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.BluetoothPlatform',
        fields: fields,
      );

  void _info(String message, {Map<String, Object?> fields = const {}}) =>
      _logger.info(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.BluetoothPlatform',
        fields: fields,
      );

  void _warning(String message, {Map<String, Object?> fields = const {}}) =>
      _logger.warning(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.BluetoothPlatform',
        fields: fields,
      );

  void _error(String message, {Map<String, Object?> fields = const {}}) =>
      _logger.error(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.BluetoothPlatform',
        fields: fields,
      );

  // Creating the platform channel is deferred until a BLE operation is used.
  // This keeps presentation-only consumers independent from native Bluetooth.
  late final CentralManager _central = CentralManager();

  /// 服务发现重试次数（Windows BLE 首次连接后 GATT 事务可能未就绪，
  /// 且手环 9 的特征枚举偶发失败/为空——实测需多次重连才成功）。
  static const int discoverAttempts = 8;

  Stream<DiscoveredEventArgs> get discoveries => _central.discovered;

  /// Current adapter/permission state used by the scan UI. Keeping this at
  /// the transport boundary avoids coupling the controller to platform
  /// channels and does not affect RFCOMM or GATT operations.
  BluetoothLowEnergyState get bluetoothState => _central.state;

  /// Emits every adapter state transition (powered off/on, authorization,
  /// unsupported, or unknown).
  Stream<BluetoothLowEnergyStateChangedEventArgs> get bluetoothStateChanged =>
      _central.stateChanged;

  /// Requests runtime Bluetooth permission where the platform supports it.
  /// The Android app bridge owns the RFCOMM permission dialog; the plugin
  /// authorization call then refreshes the BLE manager's authorization state.
  /// Desktop platforms only expose the current state and never send a
  /// protocol frame from this method.
  Future<bool> requestBluetoothAuthorization() async {
    if (_isAndroid) {
      await _androidMethods.invokeMethod<void>('ensurePermissions');
      return _central.authorize();
    }
    if (_isMacOS) {
      return (await requestMacOSBluetoothAuthorization()).isAuthorized;
    }
    return _central.state == BluetoothLowEnergyState.poweredOn;
  }

  /// Triggers macOS's first CoreBluetooth authorization evaluation.
  ///
  /// macOS only presents its consent prompt while authorization is
  /// [BluetoothAuthorizationStatus.notDetermined]. Once a user has denied it,
  /// TCC does not expose a public API to force the prompt again; callers must
  /// inspect the returned status and offer the system Settings route instead.
  Future<BluetoothAuthorizationStatus>
  requestMacOSBluetoothAuthorization() async {
    if (!_isMacOS) return BluetoothAuthorizationStatus.unknown;
    final reply = await _macosBluetoothPermissionMethods.invokeMethod<Object?>(
      'requestBluetoothAuthorization',
    );
    final status = _parseMacOSBluetoothAuthorization(reply);
    _trace(
      'macOS 蓝牙授权请求完成',
      fields: <String, Object?>{'authorization': status.name},
    );
    return status;
  }

  /// Reads the current macOS Bluetooth privacy state without attempting to
  /// display a consent prompt.
  Future<BluetoothAuthorizationStatus>
  getMacOSBluetoothAuthorizationStatus() async {
    if (!_isMacOS) return BluetoothAuthorizationStatus.unknown;
    final reply = await _macosBluetoothPermissionMethods.invokeMethod<Object?>(
      'getBluetoothAuthorizationStatus',
    );
    final status = _parseMacOSBluetoothAuthorization(reply);
    _trace(
      'macOS 蓝牙授权状态已读取',
      fields: <String, Object?>{'authorization': status.name},
    );
    return status;
  }

  /// Opens macOS Bluetooth privacy settings after a denied or restricted TCC
  /// decision. Returns whether the native bridge accepted the request.
  Future<bool> openMacOSBluetoothPrivacySettings() async {
    if (!_isMacOS) return false;
    final reply = await _macosBluetoothPermissionMethods.invokeMethod<Object?>(
      'openBluetoothPrivacySettings',
    );
    if (reply == null) return true;
    if (reply is bool) return reply;
    throw PlatformException(
      code: 'bluetooth_permission_invalid_reply',
      message: 'macOS Bluetooth privacy settings returned an invalid result.',
      details: reply,
    );
  }

  Future<void> startScan() async {
    _trace(
      'BLE 扫描开始',
      fields: <String, Object?>{'platform': defaultTargetPlatform.name},
    );
    try {
      if (_isAndroid) {
        await _androidMethods.invokeMethod<void>('ensurePermissions');
      }
      await _central.startDiscovery();
      _info('BLE 扫描已启动');
    } on Object catch (error) {
      _error(
        'BLE 扫描启动失败：$error',
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      rethrow;
    }
  }

  Future<void> stopScan() async {
    _trace('BLE 扫描停止请求');
    try {
      await _central.stopDiscovery();
      _info('BLE 扫描已停止');
    } on Object catch (error) {
      _error(
        'BLE 扫描停止失败：$error',
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      rethrow;
    }
  }

  /// 连接并枚举 GATT 服务。成功判定：**MI Wear 服务（fe95）必须存在且包含
  /// 版本/写/通知三个特征**（00000050 / 0000005f / 0000005e）。
  ///
  /// 每次失败会**断开连接后重新连接**再枚举（Windows 侧残留状态会污染
  /// 下次枚举，重连能刷新），最多 [discoverAttempts] 轮。
  Future<List<GATTService>> connectAndDiscover(Peripheral peripheral) async {
    final peripheralId = peripheral.uuid.toString();
    _trace(
      'GATT 连接与服务发现开始',
      fields: <String, Object?>{
        'peripheral': peripheralId,
        'maxAttempts': discoverAttempts,
      },
    );
    Object? lastError;
    for (var attempt = 1; attempt <= discoverAttempts; attempt++) {
      try {
        _trace(
          'GATT 连接尝试',
          fields: <String, Object?>{
            'peripheral': peripheralId,
            'attempt': attempt,
          },
        );
        await _central.connect(peripheral);
        final services = await _central.discoverGATT(peripheral);
        _trace(
          'GATT 服务发现返回',
          fields: <String, Object?>{
            'peripheral': peripheralId,
            'attempt': attempt,
            'serviceCount': services.length,
          },
        );
        if (_hasFullMiWearService(services)) {
          _info(
            'GATT 服务发现成功',
            fields: <String, Object?>{
              'peripheral': peripheralId,
              'attempt': attempt,
              'serviceCount': services.length,
            },
          );
          return services;
        }
        lastError = 'MI Wear 服务 fe95 缺失或特征不全（尝试 $attempt）';
        _warning(
          lastError.toString(),
          fields: <String, Object?>{
            'peripheral': peripheralId,
            'attempt': attempt,
          },
        );
      } catch (exception) {
        lastError = exception;
        _warning(
          'GATT 连接或服务发现尝试失败：$exception',
          fields: <String, Object?>{
            'peripheral': peripheralId,
            'attempt': attempt,
            'errorType': exception.runtimeType.toString(),
          },
        );
      }
      try {
        await _central.disconnect(peripheral);
      } catch (_) {
        _debug(
          'GATT 失败后的断开清理失败',
          fields: <String, Object?>{
            'peripheral': peripheralId,
            'attempt': attempt,
          },
        );
        // 保留发现失败作为主错误；断开是每轮失败后的 best-effort 清理。
      }
      if (attempt < discoverAttempts) {
        _trace(
          'GATT 服务发现等待重试',
          fields: <String, Object?>{
            'peripheral': peripheralId,
            'attempt': attempt,
            'delayMs': 600 * attempt,
          },
        );
        await Future.delayed(Duration(milliseconds: 600 * attempt));
      }
    }
    _error(
      'GATT 服务发现最终失败：$lastError',
      fields: <String, Object?>{
        'peripheral': peripheralId,
        'attempts': discoverAttempts,
      },
    );
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

  Future<void> disconnect(Peripheral peripheral) async {
    final peripheralId = peripheral.uuid.toString();
    _trace('GATT 断开请求', fields: <String, Object?>{'peripheral': peripheralId});
    try {
      await _central.disconnect(peripheral);
      _info('GATT 已断开', fields: <String, Object?>{'peripheral': peripheralId});
    } on Object catch (error) {
      _error(
        'GATT 断开失败：$error',
        fields: <String, Object?>{
          'peripheral': peripheralId,
          'errorType': error.runtimeType.toString(),
        },
      );
      rethrow;
    }
  }

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
    final peripheralId = uuid.toString();
    _trace(
      '经典蓝牙配对请求',
      fields: <String, Object?>{
        'peripheral': peripheralId,
        'platform': defaultTargetPlatform.name,
        'hasAdvertisedName': advertisedName?.trim().isNotEmpty == true,
      },
    );
    try {
      if (_isAndroid) {
        await _androidMethods.invokeMethod<void>('ensurePermissions');
        await _androidMethods.invokeMethod<void>('pair', _androidAddress(uuid));
        final address = _androidAddress(uuid);
        _info(
          '经典蓝牙配对完成',
          fields: <String, Object?>{'peripheral': peripheralId},
        );
        return address;
      }
      if (_isMacOS) {
        final reply = await _macosMethods.invokeMethod<Object?>(
          'pair',
          _macosIdentity(uuid, advertisedName),
        );
        final address = _macosAddress(reply, 'pair');
        _info(
          '经典蓝牙配对完成',
          fields: <String, Object?>{
            'peripheral': peripheralId,
            'hasAddress': address != null,
          },
        );
        return address;
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
      final formatted = _formatBluetoothAddress(address);
      _info('经典蓝牙配对完成', fields: <String, Object?>{'peripheral': peripheralId});
      return formatted;
    } on Object catch (error) {
      _error(
        '经典蓝牙配对失败：$error',
        fields: <String, Object?>{
          'peripheral': peripheralId,
          'errorType': error.runtimeType.toString(),
        },
      );
      rethrow;
    }
  }

  /// Persist the macOS CoreBluetooth-to-classic-device association only after
  /// the application-layer authkey handshake has authenticated the device.
  Future<void> confirmRfcommIdentity(
    UUID uuid, {
    String? advertisedName,
  }) async {
    if (!_isMacOS) return;
    _trace(
      'macOS 经典蓝牙身份确认请求',
      fields: <String, Object?>{'peripheral': uuid.toString()},
    );
    await _macosMethods.invokeMethod<void>(
      'confirmIdentity',
      _macosIdentity(uuid, advertisedName),
    );
    _info(
      'macOS 经典蓝牙身份已确认',
      fields: <String, Object?>{'peripheral': uuid.toString()},
    );
  }

  /// Removes only macOS's local CoreBluetooth-to-classic-device association.
  /// It intentionally leaves the system Bluetooth pairing and any active
  /// RFCOMM connection untouched.
  Future<void> forgetRfcommIdentity(UUID uuid) async {
    if (!_isMacOS) return;
    final peripheralId = uuid.toString();
    _trace(
      'macOS 经典蓝牙身份关联删除请求',
      fields: <String, Object?>{'peripheral': peripheralId},
    );
    try {
      await _macosMethods.invokeMethod<void>('forgetIdentity', <String, Object>{
        'peripheralId': peripheralId,
      });
      _info(
        'macOS 经典蓝牙身份关联已删除',
        fields: <String, Object?>{'peripheral': peripheralId},
      );
    } on Object catch (error) {
      _error(
        'macOS 经典蓝牙身份关联删除失败：$error',
        fields: <String, Object?>{
          'peripheral': peripheralId,
          'errorType': error.runtimeType.toString(),
        },
      );
      rethrow;
    }
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
    final peripheralId = uuid.toString();
    final epoch = _beginRfcommEpoch(uuid);
    final lane = _rfcommWriteLane(uuid);
    if (_isMacOS) lane.awaitingMacOSGeneration = true;
    _trace(
      'RFCOMM 连接开始',
      fields: <String, Object?>{
        'peripheral': peripheralId,
        'epoch': epoch,
        'serviceUuid': serviceUuid ?? '00001101-0000-1000-8000-00805f9b34fb',
        'platform': defaultTargetPlatform.name,
      },
    );
    try {
      if (_isAndroid) {
        await _androidMethods.invokeMethod<void>('ensurePermissions');
        await _androidMethods.invokeMethod<void>('connect', {
          'address': _androidAddress(uuid),
          'serviceUuid': serviceUuid ?? '00001101-0000-1000-8000-00805f9b34fb',
        });
        final address = _androidAddress(uuid);
        _info(
          'RFCOMM 连接成功',
          fields: <String, Object?>{'peripheral': peripheralId, 'epoch': epoch},
        );
        return address;
      }
      if (_isMacOS) {
        // The Swift bridge resolves RFCOMM from peripheralId + advertised name;
        // never reinterpret a Darwin UUID as a MAC address.
        final reply = await _macosMethods.invokeMethod<Object?>(
          'connect',
          _macosIdentity(uuid, advertisedName),
        );
        final address = _macosAddress(reply, 'connect');
        final nativeGeneration = _macosConnectionGeneration(reply);
        _acceptMacOSConnectionGeneration(
          uuid,
          dartEpoch: epoch,
          nativeGeneration: nativeGeneration,
        );
        _info(
          'RFCOMM 连接成功',
          fields: <String, Object?>{
            'peripheral': peripheralId,
            'epoch': epoch,
            'nativeGeneration': nativeGeneration,
            'hasAddress': address != null,
          },
        );
        return address;
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
      final formatted = _formatBluetoothAddress(address);
      _info(
        'RFCOMM 连接成功',
        fields: <String, Object?>{'peripheral': peripheralId, 'epoch': epoch},
      );
      return formatted;
    } on Object catch (error) {
      if (_isMacOS && lane.epoch == epoch) {
        lane.awaitingMacOSGeneration = false;
        lane.activeMacOSGeneration = null;
      }
      _error(
        'RFCOMM 连接失败：$error',
        fields: <String, Object?>{
          'peripheral': peripheralId,
          'epoch': epoch,
          'errorType': error.runtimeType.toString(),
        },
      );
      rethrow;
    }
  }

  // A native RFCOMM channel permits only one pending write, but that limit is
  // per channel. A reconnect of device A must never cancel an in-flight write
  // to device B, so every device gets its own FIFO and epoch. The FIFO itself
  // remains intact across A's reconnect: the next generation must not issue a
  // native write while an old write is still executing against A's channel.
  final Map<String, _RfcommWriteLane> _rfcommWriteLanes =
      <String, _RfcommWriteLane>{};

  _RfcommWriteLane _rfcommWriteLane(UUID uuid) => _rfcommWriteLanes.putIfAbsent(
    uuid.toString().toLowerCase(),
    _RfcommWriteLane.new,
  );

  int _beginRfcommEpoch(UUID uuid) {
    final lane = _rfcommWriteLane(uuid);
    lane.epoch++;
    if (_isMacOS) {
      // Do not route an old native channel while a new Dart session is being
      // established. The current generation is adopted from `sdp_started` or
      // the connect reply before any application bytes are accepted.
      lane.activeMacOSGeneration = null;
      lane.awaitingMacOSGeneration = false;
    } else {
      // Preserve the established Android/Windows reconnection behavior. The
      // per-device native generation contract exists only on macOS.
      lane.tail = Future<void>.value();
    }
    return lane.epoch;
  }

  int _macosConnectionGeneration(Object? reply) {
    final raw = reply is Map ? reply['generation'] : null;
    final generation = _macosGeneration(raw);
    if (generation != null) return generation;
    throw PlatformException(
      code: 'rfcomm_invalid_reply',
      message: 'macOS RFCOMM connect did not return a session generation.',
      details: reply,
    );
  }

  int? _macosGeneration(Object? value) {
    final parsed = switch (value) {
      int number => number,
      num number => number.toInt(),
      String text => int.tryParse(text.trim()),
      _ => null,
    };
    return parsed != null && parsed > 0 ? parsed : null;
  }

  void _acceptMacOSConnectionGeneration(
    UUID uuid, {
    required int dartEpoch,
    required int nativeGeneration,
  }) {
    final lane = _rfcommWriteLane(uuid);
    // A stale method result must never re-enable packets for a newer Dart
    // connection attempt. Native generations are monotonic per peripheral.
    if (lane.epoch != dartEpoch) return;
    final highest = lane.highestMacOSGeneration;
    if (highest != null && nativeGeneration < highest) {
      throw PlatformException(
        code: 'rfcomm_generation_regressed',
        message: 'macOS RFCOMM returned an older session generation.',
        details: <String, Object?>{
          'peripheral': uuid.toString(),
          'nativeGeneration': nativeGeneration,
          'highestGeneration': highest,
        },
      );
    }
    lane
      ..highestMacOSGeneration = highest == null
          ? nativeGeneration
          : nativeGeneration > highest
          ? nativeGeneration
          : highest
      ..activeMacOSGeneration = nativeGeneration
      ..awaitingMacOSGeneration = false;
  }

  void _observeMacOSConnectionGeneration(
    String peripheralId,
    String eventName,
    Object? generationValue,
  ) {
    // `sdp_started` is emitted immediately after native allocates a distinct
    // per-device session. `opened` is retained as a fallback in case an SDK
    // delivers only the later lifecycle event. Never learn a generation from
    // raw traffic or a close event.
    if (eventName != 'sdp_started' && eventName != 'opened') return;
    final generation = _macosGeneration(generationValue);
    if (generation == null) return;
    final key = peripheralId.trim().toLowerCase();
    final lane = _rfcommWriteLanes[key];
    if (lane == null || !lane.awaitingMacOSGeneration) return;
    final highest = lane.highestMacOSGeneration;
    // A late event from a retired connection cannot satisfy a newer attempt.
    if (highest != null && generation <= highest) return;
    lane
      ..highestMacOSGeneration = generation
      ..activeMacOSGeneration = generation
      ..awaitingMacOSGeneration = false;
  }

  bool _isActiveMacOSGeneration(String peripheralId, int? generation) {
    if (generation == null) return false;
    final lane = _rfcommWriteLanes[peripheralId.trim().toLowerCase()];
    return lane != null &&
        !lane.awaitingMacOSGeneration &&
        lane.activeMacOSGeneration == generation;
  }

  /// 写 RFCOMM 数据（严格串行）。
  Future<void> rfcommWrite(UUID uuid, List<int> data) {
    final lane = _rfcommWriteLane(uuid);
    final epoch = lane.epoch;
    _trace(
      'RFCOMM 写入排队',
      fields: <String, Object?>{
        'peripheral': uuid.toString(),
        'epoch': epoch,
        'bytes': data.length,
        'direction': 'TX',
        'wireHex': _wireHex(data),
      },
    );
    final operation = lane.tail.then((_) async {
      if (epoch != lane.epoch) {
        throw StateError('RFCOMM connection changed while writing.');
      }
      await _rfcommWriteDirect(uuid, List<int>.from(data));
      if (epoch != lane.epoch) {
        throw StateError('RFCOMM connection changed while writing.');
      }
      _trace(
        'RFCOMM 写入完成',
        fields: <String, Object?>{
          'peripheral': uuid.toString(),
          'epoch': epoch,
          'bytes': data.length,
          'direction': 'TX',
          'wireHex': _wireHex(data),
        },
      );
    });
    // A failed packet is reported to its caller but must not poison the queue.
    lane.tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _error(
          'RFCOMM 写入失败：$error',
          fields: <String, Object?>{
            'peripheral': uuid.toString(),
            'epoch': epoch,
            'bytes': data.length,
            'direction': 'TX',
            'wireHex': _wireHex(data),
            'errorType': error.runtimeType.toString(),
          },
        );
      },
    );
    return operation;
  }

  String _wireHex(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  Uint8List? _decodeWireHex(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return Uint8List(0);
    final tokens = trimmed.split(RegExp(r'\s+'));
    final bytes = <int>[];
    for (final token in tokens) {
      if (!RegExp(r'^[0-9a-fA-F]{2}$').hasMatch(token)) return null;
      bytes.add(int.parse(token, radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  Future<void> _rfcommWriteDirect(UUID uuid, List<int> data) async {
    if (_isAndroid) {
      await _androidMethods.invokeMethod<void>(
        'write',
        Uint8List.fromList(data),
      );
      return;
    }
    if (_isMacOS) {
      await _macosMethods.invokeMethod<void>('write', <String, Object>{
        'peripheralId': uuid.toString(),
        'data': Uint8List.fromList(data),
      });
      return;
    }
    _requireRfcommPlatform();
    final hex = uuid.toString().replaceAll('-', '');
    final address = int.parse(hex.substring(hex.length - 12), radix: 16);
    const channel = BasicMessageChannel<Object?>(
      'dev.flutter.pigeon.bluetooth_low_energy_windows.CentralManagerHostApi.rfcommWrite',
      StandardMessageCodec(),
    );
    final reply = await channel.send(<Object?>[
      address,
      Uint8List.fromList(data),
    ]);
    _throwIfPigeonError(reply, 'rfcommWrite');
  }

  /// 断开 RFCOMM。
  Future<void> disconnectRfcomm(UUID uuid) async {
    final epoch = _beginRfcommEpoch(uuid);
    _trace(
      'RFCOMM 断开请求',
      fields: <String, Object?>{'peripheral': uuid.toString(), 'epoch': epoch},
    );
    try {
      if (_isAndroid) {
        await _androidMethods.invokeMethod<void>('disconnect');
        return;
      }
      if (_isMacOS) {
        await _macosMethods.invokeMethod<void>('disconnect', <String, Object>{
          'peripheralId': uuid.toString(),
        });
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
      _info(
        'RFCOMM 已断开',
        fields: <String, Object?>{
          'peripheral': uuid.toString(),
          'epoch': epoch,
        },
      );
    } on Object catch (error) {
      _error(
        'RFCOMM 断开失败：$error',
        fields: <String, Object?>{
          'peripheral': uuid.toString(),
          'epoch': epoch,
          'errorType': error.runtimeType.toString(),
        },
      );
      rethrow;
    } finally {
      if (!_isMacOS) {
        final lane = _rfcommWriteLane(uuid);
        if (epoch == lane.epoch) {
          lane.tail = Future<void>.value();
        }
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
  final StreamController<RfcommDataEvent> _rfcommDataEventController =
      StreamController<RfcommDataEvent>.broadcast();
  final StreamController<RfcommClosedEvent> _rfcommClosedEventController =
      StreamController<RfcommClosedEvent>.broadcast();
  StreamSubscription<dynamic>? _androidRfcommSubscription;
  StreamSubscription<dynamic>? _macosRfcommSubscription;
  Stream<Uint8List> get rfcommData => _rfcommDataController.stream;

  /// Tagged packets emitted by the macOS native RFCOMM connection pool.
  Stream<RfcommDataEvent> get rfcommDataEvents =>
      _rfcommDataEventController.stream;

  /// Device-scoped remote-close events from the macOS native bridge.
  Stream<RfcommClosedEvent> get rfcommClosedEvents =>
      _rfcommClosedEventController.stream;

  /// Selects exactly one macOS RFCOMM channel. The macOS native bridge always
  /// tags its events with the owning CoreBluetooth identity. Keep that routing
  /// contract stable from subscription time: falling back to [rfcommData]
  /// before the EventChannel has started would let a later second device's
  /// packet enter the first device's authenticated session.
  ///
  /// Other platforms retain their established single-stream behavior until
  /// their native transports expose a comparable device identity.
  Stream<Uint8List> rfcommDataFor(UUID uuid) {
    if (!_isMacOS) return rfcommData;
    final requested = uuid.toString().trim().toLowerCase();
    return _rfcommDataEventController.stream
        .where(
          (event) =>
              event.peripheralId?.trim().toLowerCase() == requested &&
              _isActiveMacOSGeneration(
                event.peripheralId ?? '',
                event.generation,
              ),
        )
        .map((event) => event.data);
  }

  Stream<RfcommClosedEvent> rfcommClosedFor(UUID uuid) {
    if (!_isMacOS) {
      return const Stream<RfcommClosedEvent>.empty();
    }
    final requested = uuid.toString().trim().toLowerCase();
    return _rfcommClosedEventController.stream.where(
      (event) =>
          event.peripheralId.trim().toLowerCase() == requested &&
          _isActiveMacOSGeneration(event.peripheralId, event.generation),
    );
  }

  static const _androidMethods = MethodChannel('wristload/rfcomm');
  static const _androidEvents = EventChannel('wristload/rfcomm/events');
  static const _macosMethods = MethodChannel('wristload/rfcomm');
  static const _macosEvents = EventChannel('wristload/rfcomm/events');
  static const _macosBluetoothPermissionMethods = MethodChannel(
    'wristload/bluetooth_permission',
  );
  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  bool get _isMacOS => defaultTargetPlatform == TargetPlatform.macOS;

  BluetoothAuthorizationStatus _parseMacOSBluetoothAuthorization(
    Object? reply,
  ) {
    final rawStatus = switch (reply) {
      String value => value,
      Map<Object?, Object?> value => value['status']?.toString(),
      _ => null,
    };
    return switch (rawStatus?.trim().toLowerCase()) {
      'notdetermined' ||
      'not_determined' => BluetoothAuthorizationStatus.notDetermined,
      'authorized' ||
      'allowedalways' ||
      'allowed_always' => BluetoothAuthorizationStatus.authorized,
      'denied' => BluetoothAuthorizationStatus.denied,
      'restricted' => BluetoothAuthorizationStatus.restricted,
      'unknown' || null => BluetoothAuthorizationStatus.unknown,
      final invalid => throw PlatformException(
        code: 'bluetooth_permission_invalid_reply',
        message: 'macOS Bluetooth authorization returned an invalid status.',
        details: <String, Object?>{'status': invalid, 'reply': reply},
      ),
    };
  }

  void _requireRfcommPlatform() {
    if (defaultTargetPlatform != TargetPlatform.windows &&
        !_isAndroid &&
        !_isMacOS) {
      throw UnsupportedError('当前平台尚未实现 RFCOMM 真实安装传输（Linux 仅支持 BLE 诊断）。');
    }
  }

  String _formatBluetoothAddress(int address) {
    final hex = address.toRadixString(16).padLeft(12, '0').toUpperCase();
    return List.generate(
      6,
      (index) => hex.substring(index * 2, index * 2 + 2),
    ).join(':');
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
      message:
          'macOS $operation returned an invalid classic Bluetooth identity.',
      details: reply,
    );
  }

  String _androidAddress(UUID uuid) {
    final hex = uuid.toString().replaceAll('-', '');
    final mac = hex.substring(hex.length - 12).toUpperCase();
    return List.generate(
      6,
      (index) => mac.substring(index * 2, index * 2 + 2),
    ).join(':');
  }

  DiagnosticLogLevel _macosNativeEventLevel(String eventName) {
    // Pairing failures used to arrive as trace-only native events, which made
    // a system rejection look unrelated to the user-visible MethodChannel
    // error. Keep the low-level event and make its severity actionable.
    if (const <String>{
      'error',
      'pairing_failed',
      'pairing_start_failed',
      'pairing_timeout',
      'pairing_user_input_unavailable',
      'pairing_user_input_invalid',
    }.contains(eventName)) {
      return DiagnosticLogLevel.error;
    }
    if (const <String>{
      'pairing_cancelled',
      'pairing_rejected',
    }.contains(eventName)) {
      return DiagnosticLogLevel.warning;
    }
    return DiagnosticLogLevel.trace;
  }

  /// 注册 RFCOMM 数据回调（监听 C++ 侧 Pigeon FlutterApi `onRfcommData`）。
  void listenRfcommData() {
    _trace(
      'RFCOMM 数据监听注册',
      fields: <String, Object?>{'platform': defaultTargetPlatform.name},
    );
    if (_isAndroid) {
      _androidRfcommSubscription ??= _androidEvents
          .receiveBroadcastStream()
          .listen(
            (Object? value) {
              if (value is Uint8List && !_rfcommDataController.isClosed) {
                _trace(
                  'RFCOMM RX',
                  fields: <String, Object?>{
                    'bytes': value.length,
                    'platform': 'android',
                    'transport': 'RFCOMM/SPP',
                    'direction': 'RX',
                    'wireHex': _wireHex(value),
                  },
                );
                _rfcommDataController.add(value);
                if (!_rfcommDataEventController.isClosed) {
                  _rfcommDataEventController.add(RfcommDataEvent(data: value));
                }
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              _error(
                'RFCOMM 数据流错误：$error',
                fields: <String, Object?>{
                  'platform': 'android',
                  'errorType': error.runtimeType.toString(),
                },
              );
              if (!_rfcommDataController.isClosed) {
                _rfcommDataController.addError(error, stackTrace);
              }
            },
          );
      return;
    }
    if (_isMacOS) {
      _macosRfcommSubscription ??= _macosEvents.receiveBroadcastStream().listen(
        (Object? value) {
          if (value is Map) {
            final event = <String, Object?>{
              for (final entry in value.entries)
                entry.key.toString(): entry.value,
            };
            final eventName = event['event']?.toString() ?? 'native';
            final level = _macosNativeEventLevel(eventName);
            final fields = <String, Object?>{
              'platform': 'macos',
              'transport': 'RFCOMM/SPP',
              'nativeEvent': eventName,
              ...event,
            };
            final peripheral = event['peripheral']?.toString().trim();
            final generation = _macosGeneration(event['generation']);
            if (event['kind'] == 'native' &&
                peripheral != null &&
                peripheral.isNotEmpty) {
              _observeMacOSConnectionGeneration(
                peripheral,
                eventName,
                event['generation'],
              );
            }
            switch (level) {
              case DiagnosticLogLevel.error:
                _logger.error(
                  'macOS RFCOMM $eventName',
                  category: DiagnosticLogCategory.communication,
                  component: 'wristload.RfcommDriver',
                  event: eventName,
                  fields: fields,
                );
              default:
                _logger.trace(
                  'macOS RFCOMM $eventName',
                  category: DiagnosticLogCategory.communication,
                  component: 'wristload.RfcommDriver',
                  event: eventName,
                  fields: fields,
                );
            }
            // Keep the native event in the same visible journal used by the
            // diagnostic window; the byte stream is handled below.
            if (event['kind'] == 'data' && event['wireHex'] is String) {
              final bytes = _decodeWireHex(event['wireHex']!.toString());
              if (bytes != null &&
                  peripheral != null &&
                  peripheral.isNotEmpty &&
                  _isActiveMacOSGeneration(peripheral, generation)) {
                if (!_rfcommDataController.isClosed) {
                  _rfcommDataController.add(bytes);
                }
                if (!_rfcommDataEventController.isClosed) {
                  _rfcommDataEventController.add(
                    RfcommDataEvent(
                      data: bytes,
                      peripheralId: peripheral,
                      generation: generation,
                    ),
                  );
                }
              } else if (bytes != null) {
                _error(
                  'macOS RFCOMM 数据不属于当前设备会话，已拒绝路由。',
                  fields: <String, Object?>{
                    'platform': 'macos',
                    'nativeEvent': eventName,
                    'hasPeripheral': peripheral?.isNotEmpty == true,
                    'generation': generation,
                  },
                );
              }
            }
            if (event['kind'] == 'closed') {
              if (peripheral != null &&
                  peripheral.isNotEmpty &&
                  _isActiveMacOSGeneration(peripheral, generation) &&
                  !_rfcommClosedEventController.isClosed) {
                _rfcommClosedEventController.add(
                  RfcommClosedEvent(
                    peripheralId: peripheral,
                    code: event['code']?.toString(),
                    message: event['message']?.toString(),
                    generation: generation,
                  ),
                );
              } else if (peripheral != null && peripheral.isNotEmpty) {
                _trace(
                  'macOS RFCOMM 关闭事件不属于当前设备会话，已忽略。',
                  fields: <String, Object?>{
                    'peripheral': peripheral,
                    'generation': generation,
                  },
                );
              }
            }
            // `entry` is intentionally retained through the logger; no extra
            // controller-side history exists in this transport wrapper.
            return;
          }
          if (value is Uint8List || value is List<int>) {
            // macOS's multi-session bridge must always label a live packet
            // with both CoreBluetooth identity and native generation. Accepting
            // legacy bare bytes here could let one watch's old channel mutate
            // another session after an EventChannel resubscription.
            _error(
              'macOS RFCOMM 收到未标记数据，已拒绝路由。',
              fields: <String, Object?>{'platform': 'macos'},
            );
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          _error(
            'RFCOMM 数据流错误：$error',
            fields: <String, Object?>{
              'platform': 'macos',
              'errorType': error.runtimeType.toString(),
            },
          );
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
        _trace(
          'RFCOMM RX',
          fields: <String, Object?>{
            'bytes': data.length,
            'platform': 'windows',
            'transport': 'RFCOMM/SPP',
            'direction': 'RX',
            'wireHex': _wireHex(data),
          },
        );
        _rfcommDataController.add(data);
        if (!_rfcommDataEventController.isClosed) {
          _rfcommDataEventController.add(RfcommDataEvent(data: data));
        }
      }
      return null;
    });
  }

  Future<void> disposeRfcommStream() async {
    _trace('RFCOMM 数据监听释放');
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
    if (!_rfcommDataEventController.isClosed) {
      await _rfcommDataEventController.close();
    }
    if (!_rfcommClosedEventController.isClosed) {
      await _rfcommClosedEventController.close();
    }
    _info('RFCOMM 数据监听已释放');
  }

  /// 读取特征值（只读操作，用于版本特征等被动读取，不发送任何写帧）。
  Future<Uint8List> readCharacteristic(
    Peripheral peripheral,
    GATTCharacteristic characteristic,
  ) async {
    _trace(
      'GATT 特征读取开始',
      fields: <String, Object?>{
        'peripheral': peripheral.uuid.toString(),
        'characteristic': characteristic.uuid.toString(),
      },
    );
    try {
      final value = await _central.readCharacteristic(
        peripheral,
        characteristic,
      );
      _trace(
        'GATT 特征读取完成',
        fields: <String, Object?>{
          'peripheral': peripheral.uuid.toString(),
          'characteristic': characteristic.uuid.toString(),
          'bytes': value.length,
        },
      );
      return value;
    } on Object catch (error) {
      _error(
        'GATT 特征读取失败：$error',
        fields: <String, Object?>{
          'peripheral': peripheral.uuid.toString(),
          'characteristic': characteristic.uuid.toString(),
          'errorType': error.runtimeType.toString(),
        },
      );
      rethrow;
    }
  }
}

/// One FIFO/write generation per physical RFCOMM endpoint.
///
/// The native macOS transport owns a distinct RFCOMM channel for each
/// peripheral. Keeping the Dart queue at the same granularity prevents a
/// reconnect or teardown for device A from invalidating writes already queued
/// for device B.
class _RfcommWriteLane {
  int epoch = 0;
  Future<void> tail = Future<void>.value();
  int? activeMacOSGeneration;
  int? highestMacOSGeneration;
  bool awaitingMacOSGeneration = false;
}
