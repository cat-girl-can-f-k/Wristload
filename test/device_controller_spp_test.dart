import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/application/device_controller.dart';
import 'package:wristload/domain/protocol/auth_handshake.dart';
import 'package:wristload/domain/protocol/proto_wire.dart';
import 'package:wristload/domain/protocol/spp_protocol.dart';
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

  test('L1START write failure closes the connected RFCOMM channel', () async {
    final transport = _FakeBleTransport(
      writeError: StateError('write failed'),
    );
    final controller = _controllerWithDevice(transport);

    await controller.connectSpp();

    expect(transport.calls, ['listen', 'connect', 'write', 'disconnect']);
    expect(controller.sppConnecting, isFalse);
    expect(controller.sessionReady, isFalse);
  });

  test('a failed connection stays busy until native disconnect completes',
      () async {
    final disconnectGate = Completer<void>();
    final transport = _FakeBleTransport(
      connectError: StateError('connect failed'),
      disconnectGate: disconnectGate,
    );
    final controller = _controllerWithDevice(transport);
    var completed = false;

    final first = controller.connectSpp()..whenComplete(() => completed = true);
    await _waitForCall(transport, 'disconnect');

    expect(controller.sppConnecting, isTrue);
    expect(completed, isFalse);
    await controller.connectSpp();
    expect(transport.calls.where((call) => call == 'connect'), hasLength(1));

    disconnectGate.complete();
    await first;
    expect(completed, isTrue);
    expect(controller.sppConnecting, isFalse);
  });

  test('late RFCOMM data is ignored while failed connection is closing',
      () async {
    final disconnectGate = Completer<void>();
    final transport = _FakeBleTransport(
      connectError: StateError('connect failed'),
      disconnectGate: disconnectGate,
    );
    final controller = _controllerWithDevice(transport);

    final attempt = controller.connectSpp();
    await _waitForCall(transport, 'disconnect');
    transport.emit(SppProtocol.encodeCmd(
      SppProtocol.cmdL1StartRsp,
      const [],
    ));
    await _flushAsyncEvents();

    expect(transport.calls.where((call) => call == 'write'), isEmpty);

    disconnectGate.complete();
    await attempt;
  });

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

    transport.emit(_authConfirmResponse(
      authStatus: 1,
      commandType: XiaomiAuth.commandType + 1,
      seq: 8,
    ));
    await _flushAsyncEvents();
    expect(controller.sessionReady, isFalse);
    expect(controller.sppConnecting, isTrue);

    transport.emit(_authConfirmResponse(
      authStatus: 1,
      channel: SppProtocol.channelMass,
      seq: 9,
    ));
    await _flushAsyncEvents();
    expect(controller.sessionReady, isFalse);
    expect(controller.sppConnecting, isTrue);

    transport.emit(_authConfirmResponse(
      authStatus: 1,
      opCode: 0x7f,
      seq: 10,
    ));
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
      controller.logs
          .where((entry) => entry.contains('f=27 设备响应'))
          .length,
      1,
    );
  });

  test('failed f=27 consumes the handshake and late success is ignored',
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
      controller.logs
          .where((entry) => entry.contains('f=27 设备响应'))
          .length,
      1,
    );
  });

  test('f=27 success from a previous connection cannot ready a new one',
      () async {
    final secretKey = List<int>.generate(16, (index) => index);
    final transport = _FakeBleTransport();
    final controller = _controllerWithAuthKey(transport, secretKey);
    final oldSuccess =
        await _beginAuthConfirmation(controller, transport, secretKey);

    await controller.disconnect();
    controller
      ..connectedDevice = _testPeripheral()
      ..connectedDeviceName = 'Xiaomi Smart Band 9';
    await controller.connectSpp();
    transport.emit(oldSuccess);
    await _flushAsyncEvents();

    expect(controller.sessionReady, isFalse);
    expect(controller.sppConnecting, isTrue);
  });

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
}

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
) =>
    _controllerWithDevice(transport)
      ..authKey = secretKey
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();

_TestPeripheral _testPeripheral() => _TestPeripheral(
      UUID.fromString('12345678-90ab-cdef-1234-567890abcdef'),
    );

Future<List<int>> _beginAuthConfirmation(
  DeviceController controller,
  _FakeBleTransport transport,
  List<int> secretKey,
  {
  bool duplicateWatchNonce = false,
}) async {
  await controller.connectSpp();
  transport.emit(SppProtocol.encodeCmd(
    SppProtocol.cmdL1StartRsp,
    const [],
  ));
  await _waitForDataWriteCount(transport, 1);

  final nonceRequest = transport.writes
      .map(_parseSingleFrame)
      .firstWhere((packet) => packet.type == SppProtocol.typeData);
  final phoneNonce =
      XiaomiAuth.parse(nonceRequest.payload.sublist(2))!.appNonce!;
  final watchNonce = List<int>.generate(16, (index) => 0x20 + index);
  final sessionMaterial =
      XiaomiAuth.computeStep3Hmac(secretKey, phoneNonce, watchNonce);
  final watchHmac = XiaomiAuth.hmacSha256(
    sessionMaterial.sublist(0, 16),
    [...watchNonce, ...phoneNonce],
  );
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
    this.writeError,
    this.disconnectError,
    this.disconnectGate,
    this.writeResults = const [],
  });

  final Object? connectError;
  final Object? writeError;
  final Object? disconnectError;
  final Completer<void>? disconnectGate;
  final List<Future<void>> writeResults;
  final List<String> calls = [];
  final List<List<int>> writes = [];
  final StreamController<Uint8List> _data =
      StreamController<Uint8List>.broadcast();
  Future<void>? _closingData;

  @override
  Stream<Uint8List> get rfcommData => _data.stream;

  @override
  void listenRfcommData() {
    calls.add('listen');
  }

  @override
  Future<String?> connectRfcomm(
    UUID uuid, {
    String? serviceUuid,
    String? advertisedName,
  }) async {
    calls.add('connect');
    final error = connectError;
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
  Future<void> disposeRfcommStream() =>
      _closingData ??= _data.close();
}
