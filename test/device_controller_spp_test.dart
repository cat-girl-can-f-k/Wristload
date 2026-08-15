import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/application/device_controller.dart';
import 'package:wristload/domain/connection_issue.dart';
import 'package:wristload/domain/protocol/auth_handshake.dart';
import 'package:wristload/domain/protocol/proto_wire.dart';
import 'package:wristload/domain/protocol/session_cipher.dart';
import 'package:wristload/domain/protocol/spp_protocol.dart';
import 'package:wristload/domain/protocol/zau.dart';
import 'package:wristload/domain/watch_app.dart';
import 'package:wristload/platform/ble_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('RFCOMM connect failure is cleaned before becoming retryable', () async {
    final transport = _FakeBleTransport(
      connectError: StateError('connect failed'),
    );
    final controller = _controllerWithDevice(transport);

    await controller.connectSpp();

    expect(transport.calls, ['listen', 'connect', 'disconnect']);
    expect(controller.sppConnecting, isFalse);
    expect(controller.sessionReady, isFalse);
  });

  test('RFCOMM connect timeout publishes the two-second connection issue',
      () async {
    final transport = _FakeBleTransport(
      connectDelay: const Duration(seconds: 3),
    );
    final controller = _controllerWithDevice(transport);

    await controller.connectSpp();

    expect(controller.pendingConnectionIssue?.kind,
        ConnectionIssueKind.rfcommTimeout);
    expect(controller.sppConnecting, isFalse);
    expect(transport.calls, contains('disconnect'));
  });

  test('L1START write failure closes the connected RFCOMM channel', () async {
    final transport = _FakeBleTransport(writeError: StateError('write failed'));
    final controller = _controllerWithDevice(transport);

    await controller.connectSpp();

    expect(transport.calls, ['listen', 'connect', 'write', 'disconnect']);
    expect(controller.sppConnecting, isFalse);
    expect(controller.sessionReady, isFalse);
  });

  test(
    'a failed connection stays busy until native disconnect completes',
    () async {
      final disconnectGate = Completer<void>();
      final transport = _FakeBleTransport(
        connectError: StateError('connect failed'),
        disconnectGate: disconnectGate,
      );
      final controller = _controllerWithDevice(transport);
      var completed = false;

      final first = controller.connectSpp()
        ..whenComplete(() => completed = true);
      await _waitForCall(transport, 'disconnect');

      expect(controller.sppConnecting, isTrue);
      expect(completed, isFalse);
      await controller.connectSpp();
      expect(transport.calls.where((call) => call == 'connect'), hasLength(1));

      disconnectGate.complete();
      await first;
      expect(completed, isTrue);
      expect(controller.sppConnecting, isFalse);
    },
  );

  test(
    'late RFCOMM data is ignored while failed connection is closing',
    () async {
      final disconnectGate = Completer<void>();
      final transport = _FakeBleTransport(
        connectError: StateError('connect failed'),
        disconnectGate: disconnectGate,
      );
      final controller = _controllerWithDevice(transport);

      final attempt = controller.connectSpp();
      await _waitForCall(transport, 'disconnect');
      transport.emit(
        SppProtocol.encodeCmd(SppProtocol.cmdL1StartRsp, const []),
      );
      await _flushAsyncEvents();

      expect(transport.calls.where((call) => call == 'write'), isEmpty);

      disconnectGate.complete();
      await attempt;
    },
  );

  test('duplicate watch nonce schedules only one auth confirmation', () async {
    final secretKey = List<int>.generate(16, (index) => index);
    final transport = _FakeBleTransport();
    final controller = _controllerWithAuthKey(transport, secretKey);
    await _beginAuthConfirmation(
      controller,
      transport,
      secretKey,
      duplicateWatchNonce: true,
    );

    await _flushAsyncEvents();

    final dataWrites = transport.writes
        .map(_parseSingleFrame)
        .where((packet) => packet.type == SppProtocol.typeData);
    expect(dataWrites, hasLength(2));
  });

  test('unsolicited f=27 success cannot authenticate a connection', () async {
    final transport = _FakeBleTransport();
    final controller = _controllerWithDevice(transport);

    await controller.connectSpp();
    transport.emit(_authConfirmResponse(authStatus: 1));
    await _flushAsyncEvents();

    expect(controller.sessionReady, isFalse);
    expect(controller.sppConnecting, isTrue);
  });

  test('f=27 requires the current plain PB WRITE handshake', () async {
    final secretKey = List<int>.generate(16, (index) => index);
    final transport = _FakeBleTransport();
    final controller = _controllerWithAuthKey(transport, secretKey);
    await _beginAuthConfirmation(controller, transport, secretKey);

    transport.emit(
      _authConfirmResponse(
        authStatus: 1,
        commandType: XiaomiAuth.commandType + 1,
        seq: 8,
      ),
    );
    await _flushAsyncEvents();
    expect(controller.sessionReady, isFalse);
    expect(controller.sppConnecting, isTrue);

    transport.emit(
      _authConfirmResponse(
        authStatus: 1,
        channel: SppProtocol.channelMass,
        seq: 9,
      ),
    );
    await _flushAsyncEvents();
    expect(controller.sessionReady, isFalse);
    expect(controller.sppConnecting, isTrue);

    transport.emit(_authConfirmResponse(authStatus: 1, opCode: 0x7f, seq: 10));
    await _flushAsyncEvents();
    expect(controller.sessionReady, isFalse);
    expect(controller.sppConnecting, isTrue);

    transport.emit(_authConfirmResponse(seq: 11));
    await _flushAsyncEvents();
    expect(controller.sessionReady, isFalse);
    expect(controller.sppConnecting, isTrue);

    final success = _authConfirmResponse(authStatus: 1, seq: 12);
    transport
      ..emit(success)
      ..emit(success);
    await _flushAsyncEvents();

    expect(controller.sessionReady, isTrue);
    expect(controller.sppConnecting, isFalse);
    expect(
      controller.logs.where((entry) => entry.contains('f=27 设备响应')).length,
      1,
    );
  });

  test(
    'failed f=27 consumes the handshake and late success is ignored',
    () async {
      final secretKey = List<int>.generate(16, (index) => index);
      final transport = _FakeBleTransport();
      final controller = _controllerWithAuthKey(transport, secretKey);
      await _beginAuthConfirmation(controller, transport, secretKey);

      transport.emit(_authConfirmResponse(authStatus: 0, seq: 8));
      await _flushAsyncEvents();
      expect(controller.sessionReady, isFalse);
      expect(controller.sppConnecting, isFalse);

      transport.emit(_authConfirmResponse(authStatus: 1, seq: 9));
      await _flushAsyncEvents();
      expect(controller.sessionReady, isFalse);
      expect(
        controller.logs.where((entry) => entry.contains('f=27 设备响应')).length,
        1,
      );
    },
  );

  test(
    'f=27 success from a previous connection cannot ready a new one',
    () async {
      final secretKey = List<int>.generate(16, (index) => index);
      final transport = _FakeBleTransport();
      final controller = _controllerWithAuthKey(transport, secretKey);
      final oldSuccess = await _beginAuthConfirmation(
        controller,
        transport,
        secretKey,
      );

      await controller.disconnect();
      controller
        ..connectedDevice = _testPeripheral()
        ..connectedDeviceName = 'Xiaomi Smart Band 9';
      await controller.connectSpp();
      transport.emit(oldSuccess);
      await _flushAsyncEvents();

      expect(controller.sessionReady, isFalse);
      expect(controller.sppConnecting, isTrue);
    },
  );

  test('an old failed write cannot close a newer RFCOMM connection', () async {
    final firstWrite = Completer<void>();
    final transport = _FakeBleTransport(writeResults: [firstWrite.future]);
    final controller = _controllerWithDevice(transport);

    final oldAttempt = controller.connectSpp();
    await _waitForCallCount(transport, 'write', 1);
    await controller.disconnect();

    controller
      ..connectedDevice = _TestPeripheral(
        UUID.fromString('12345678-90ab-cdef-1234-567890abcdef'),
      )
      ..connectedDeviceName = 'Xiaomi Smart Band 9';
    await controller.connectSpp();
    expect(transport.calls.where((call) => call == 'write'), hasLength(2));

    firstWrite.completeError(StateError('stale write failed'));
    await oldAttempt;

    expect(transport.calls.where((call) => call == 'disconnect'), hasLength(1));
    expect(controller.sppConnecting, isTrue);
  });

  test(
    'quick-app uninstall completes from RFCOMM ACK without a 20/3 response',
    () async {
      final secretKey = List<int>.generate(16, (index) => index);
      final transport = _FakeBleTransport();
      final controller = _controllerWithAuthKey(transport, secretKey);
      final authResponse = await _beginAuthConfirmation(
        controller,
        transport,
        secretKey,
      );

      final authRequest = transport.writes
          .map(_parseSingleFrame)
          .firstWhere((packet) => packet.type == SppProtocol.typeData);
      final phoneNonce = XiaomiAuth.parse(
        authRequest.payload.sublist(2),
      )!.appNonce!;
      final watchNonce = List<int>.generate(16, (index) => 0x20 + index);
      final cipher = SessionCipher(
        SessionKeys.fromHkdf(
          XiaomiAuth.computeStep3Hmac(secretKey, phoneNonce, watchNonce),
        ),
      );

      transport.emit(authResponse);
      await _flushAsyncEvents();
      expect(controller.sessionReady, isTrue);

      final app = WatchAppItem(
        packageName: 'com.anemo.quickapp',
        fingerprint: Uint8List.fromList(const [1, 2, 3, 4]),
        versionCode: 1,
        canRemove: true,
        appName: 'Quick App',
      );
      controller.installedWatchApps = List<WatchAppItem>.unmodifiable([app]);

      final uninstall = controller.uninstallWatchApp(app);
      final packet = await _waitForBusinessWrite(
        transport,
        cipher,
        command: ZauCommand.appList,
        sub: ZauCommand.uninstallAppSub,
      );

      // The device intentionally sends no encrypted command=20/sub=3 result.
      // Its transport ACK is the completion signal for uninstall.
      transport.emit(SppProtocol.buildAck(packet.seq));

      await expectLater(
        uninstall.timeout(const Duration(seconds: 1)),
        completion(isTrue),
      );
      expect(controller.installedWatchApps, isEmpty);
      expect(controller.watchAppsLoading, isFalse);
      expect(controller.watchAppsError, isNull);
      expect(controller.logs, contains(contains('卸载命令已收到 SPP ACK；本地列表已更新。')));
    },
  );

  test(
    'cancelled desktop pairing never publishes a connected device',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final transport = _FakeBleTransport(
        pairError: PlatformException(
          code: 'pairing_cancelled',
          message:
              'Classic Bluetooth pairing was cancelled or did not complete.',
        ),
      );
      final controller = DeviceController(transport: transport)
        ..authKey = List<int>.generate(
          16,
          (index) => index,
        ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      addTearDown(() async {
        controller.dispose();
        await transport.disposeRfcommStream();
      });
      final discovery = DiscoveredEventArgs(
        _testPeripheral(),
        -40,
        Advertisement(name: 'Xiaomi Smart Band 10 9D63'),
      );

      await controller.connect(discovery);

      expect(transport.calls, contains('pair'));
      expect(transport.calls, isNot(contains('connect')));
      expect(controller.connectedDevice, isNull);
      expect(controller.isConnected, isFalse);
      expect(controller.connectedDeviceName, isNull);
      expect(controller.connectedClassicAddress, isNull);
      expect(controller.connectedProfile, isNull);
      expect(controller.error, contains('pairing_cancelled'));
    },
  );

  test(
    'successful macOS desktop pairing proceeds directly to RFCOMM',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final transport = _FakeBleTransport();
      final controller = _desktopControllerWithAuthKey(transport);

      await controller.connect(_desktopDiscovery());

      expect(transport.calls, [
        'stopScan',
        'listen',
        'pair',
        'connect',
        'write',
      ]);
      expect(controller.isConnected, isFalse);
      expect(controller.isConnecting, isTrue);
      expect(controller.sessionReady, isFalse);
    },
  );

  test(
    'disconnect during desktop pairing ignores a late successful pair',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final pairGate = Completer<String?>();
      final transport = _FakeBleTransport(pairResult: pairGate.future);
      final controller = _desktopControllerWithAuthKey(transport);
      final discovery = _desktopDiscovery();

      final attempt = controller.connect(discovery);
      await _waitForCall(transport, 'pair');
      await controller.disconnect();

      pairGate.complete('AA:BB:CC:DD:EE:FF');
      await attempt;

      expect(transport.calls, isNot(contains('connect')));
      expect(controller.connectedDevice, isNull);
      expect(controller.isConnected, isFalse);
      expect(controller.sppConnecting, isFalse);
    },
  );

  test(
    'disconnect during desktop pairing ignores a late failed pair',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final pairGate = Completer<String?>();
      final transport = _FakeBleTransport(pairResult: pairGate.future);
      final controller = _desktopControllerWithAuthKey(transport);

      final attempt = controller.connect(_desktopDiscovery());
      await _waitForCall(transport, 'pair');
      await controller.disconnect();

      pairGate.completeError(
        PlatformException(
          code: 'pairing_cancelled',
          message: 'Classic Bluetooth pairing was cancelled.',
        ),
      );
      await attempt;

      expect(transport.calls, isNot(contains('connect')));
      expect(controller.connectedDevice, isNull);
      expect(controller.error, isNull);
    },
  );

  test('disposing during desktop pairing ignores a late pair result', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final pairGate = Completer<String?>();
    final transport = _FakeBleTransport(pairResult: pairGate.future);
    final controller = _desktopControllerWithAuthKey(
      transport,
      registerControllerTearDown: false,
    );
    addTearDown(transport.disposeRfcommStream);

    final attempt = controller.connect(_desktopDiscovery());
    await _waitForCall(transport, 'pair');
    controller.dispose();

    pairGate.complete('AA:BB:CC:DD:EE:FF');
    await attempt;

    expect(transport.calls, isNot(contains('connect')));
    expect(controller.connectedDevice, isNull);
  });
}

DeviceController _desktopControllerWithAuthKey(
  _FakeBleTransport transport, {
  bool registerControllerTearDown = true,
}) {
  final controller = DeviceController(transport: transport)
    ..authKey = List<int>.generate(
      16,
      (index) => index,
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  if (registerControllerTearDown) {
    addTearDown(() async {
      controller.dispose();
      await transport.disposeRfcommStream();
    });
  }
  return controller;
}

DiscoveredEventArgs _desktopDiscovery() => DiscoveredEventArgs(
  _testPeripheral(),
  -40,
  Advertisement(name: 'Xiaomi Smart Band 10 9D63'),
);

DeviceController _controllerWithDevice(_FakeBleTransport transport) {
  final controller = DeviceController(transport: transport)
    ..connectedDevice = _testPeripheral()
    ..connectedDeviceName = 'Xiaomi Smart Band 9';
  addTearDown(() async {
    controller.connectedDevice = null;
    controller.dispose();
    await transport.disposeRfcommStream();
  });
  return controller;
}

DeviceController _controllerWithAuthKey(
  _FakeBleTransport transport,
  List<int> secretKey,
) => _controllerWithDevice(transport)
  ..authKey = secretKey
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

_TestPeripheral _testPeripheral() =>
    _TestPeripheral(UUID.fromString('12345678-90ab-cdef-1234-567890abcdef'));

Future<List<int>> _beginAuthConfirmation(
  DeviceController controller,
  _FakeBleTransport transport,
  List<int> secretKey, {
  bool duplicateWatchNonce = false,
}) async {
  await controller.connectSpp();
  transport.emit(SppProtocol.encodeCmd(SppProtocol.cmdL1StartRsp, const []));
  await _waitForDataWriteCount(transport, 1);

  final nonceRequest = transport.writes
      .map(_parseSingleFrame)
      .firstWhere((packet) => packet.type == SppProtocol.typeData);
  final phoneNonce = XiaomiAuth.parse(
    nonceRequest.payload.sublist(2),
  )!.appNonce!;
  final watchNonce = List<int>.generate(16, (index) => 0x20 + index);
  final sessionMaterial = XiaomiAuth.computeStep3Hmac(
    secretKey,
    phoneNonce,
    watchNonce,
  );
  final watchHmac = XiaomiAuth.hmacSha256(sessionMaterial.sublist(0, 16), [
    ...watchNonce,
    ...phoneNonce,
  ]);
  final verify = ProtoWriter()
    ..writeBytes(1, watchNonce)
    ..writeBytes(2, watchHmac);
  final auth = ProtoWriter()..writeMessage(31, verify.bytes);
  final command = ProtoWriter()
    ..writeInt(1, XiaomiAuth.commandType)
    ..writeInt(2, XiaomiAuth.cmdNonce)
    ..writeMessage(3, auth.bytes);

  final watchNonceResponse = SppProtocol.buildDataFrame(7, command.bytes);
  transport.emit(watchNonceResponse);
  if (duplicateWatchNonce) transport.emit(watchNonceResponse);
  await _waitForDataWriteCount(transport, 2);
  return _authConfirmResponse(authStatus: 1);
}

List<int> _authConfirmResponse({
  int? authStatus,
  int commandType = XiaomiAuth.commandType,
  int subtype = XiaomiAuth.cmdAuth,
  int channel = SppProtocol.channelPb,
  int opCode = SppProtocol.opCodeWrite,
  int seq = 7,
}) {
  final confirm = ProtoWriter();
  if (authStatus != null) confirm.writeInt(1, authStatus);
  final auth = ProtoWriter()..writeMessage(33, confirm.bytes);
  final command = ProtoWriter()
    ..writeInt(1, commandType)
    ..writeInt(2, subtype)
    ..writeMessage(3, auth.bytes);
  return SppProtocol.buildDataFrame(
    seq,
    command.bytes,
    channel: channel,
    opCode: opCode,
  );
}

Future<void> _waitForCall(_FakeBleTransport transport, String expected) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if (transport.calls.contains(expected)) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for $expected: ${transport.calls}');
}

Future<void> _waitForCallCount(
  _FakeBleTransport transport,
  String expected,
  int count,
) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    if (transport.calls.where((call) => call == expected).length >= count) {
      return;
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for $count $expected calls: ${transport.calls}');
}

Future<void> _waitForDataWriteCount(
  _FakeBleTransport transport,
  int count,
) async {
  for (var attempt = 0; attempt < 20; attempt++) {
    final dataWrites = transport.writes
        .map(_parseSingleFrame)
        .where((packet) => packet.type == SppProtocol.typeData)
        .length;
    if (dataWrites >= count) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for $count DATA writes: ${transport.calls}');
}

Future<SppPacket> _waitForBusinessWrite(
  _FakeBleTransport transport,
  SessionCipher cipher, {
  required int command,
  required int sub,
}) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    for (final bytes in transport.writes.reversed) {
      final packet = _parseSingleFrame(bytes);
      if (packet.type != SppProtocol.typeData || packet.payload.length < 3) {
        continue;
      }
      if (packet.payload[0] != SppProtocol.channelPb ||
          packet.payload[1] != SppProtocol.opCodeWriteEnc) {
        continue;
      }
      final business = Zau.tryParse(
        cipher.encryptOutbound(packet.payload.sublist(2)),
      );
      if (business?.command == command && business?.sub == sub) {
        return packet;
      }
    }
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for encrypted $command/$sub write');
}

Future<void> _flushAsyncEvents() async {
  for (var iteration = 0; iteration < 5; iteration++) {
    await Future<void>.delayed(Duration.zero);
  }
}

SppPacket _parseSingleFrame(List<int> bytes) {
  final accumulator = Accumulator()..buffer = bytes;
  final packets = SppProtocol.parse(accumulator);
  expect(packets, hasLength(1));
  return packets.single;
}

final class _TestPeripheral implements Peripheral {
  _TestPeripheral(this.uuid);

  @override
  final UUID uuid;
}

final class _FakeBleTransport extends BleTransport {
  _FakeBleTransport({
    this.connectError,
    this.connectDelay,
    this.writeError,
    this.disconnectError,
    this.disconnectGate,
    this.pairError,
    this.pairResult,
    this.writeResults = const [],
  });

  final Object? connectError;
  final Duration? connectDelay;
  final Object? writeError;
  final Object? disconnectError;
  final Completer<void>? disconnectGate;
  final Object? pairError;
  final Future<String?>? pairResult;
  final List<Future<void>> writeResults;
  final List<String> calls = [];
  final List<List<int>> writes = [];
  final StreamController<Uint8List> _data =
      StreamController<Uint8List>.broadcast();
  Future<void>? _closingData;
  bool _rfcommListenerStarted = false;

  @override
  Stream<Uint8List> get rfcommData => _data.stream;

  @override
  Future<void> stopScan() async {
    calls.add('stopScan');
  }

  @override
  void listenRfcommData() {
    if (_rfcommListenerStarted) return;
    _rfcommListenerStarted = true;
    calls.add('listen');
  }

  @override
  Future<String?> connectRfcomm(
    UUID uuid, {
    String? serviceUuid,
    String? advertisedName,
  }) async {
    calls.add('connect');
    if (connectDelay != null) await Future<void>.delayed(connectDelay!);
    final error = connectError;
    if (error != null) throw error;
    return 'AA:BB:CC:DD:EE:FF';
  }

  @override
  Future<String?> pairDevice(UUID uuid, {String? advertisedName}) async {
    calls.add('pair');
    final result = pairResult;
    if (result != null) return result;
    final error = pairError;
    if (error != null) throw error;
    return 'AA:BB:CC:DD:EE:FF';
  }

  @override
  Future<void> rfcommWrite(UUID uuid, List<int> data) async {
    calls.add('write');
    writes.add(List<int>.from(data));
    final index = calls.where((call) => call == 'write').length - 1;
    if (index < writeResults.length) await writeResults[index];
    final error = writeError;
    if (error != null) throw error;
  }

  @override
  Future<void> disconnectRfcomm(UUID uuid) async {
    calls.add('disconnect');
    final gate = disconnectGate;
    if (gate != null) await gate.future;
    final error = disconnectError;
    if (error != null) throw error;
  }

  @override
  Future<void> disconnect(Peripheral peripheral) async {}

  void emit(List<int> data) {
    _data.add(Uint8List.fromList(data));
  }

  @override
  Future<void> disposeRfcommStream() => _closingData ??= _data.close();
}
