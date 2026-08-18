import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wristload_tui/src/backend_next/tui_backend_port.dart';
import 'package:wristload_tui/src/backend_next/tui_mac_bluetooth_transport.dart';
import 'package:wristload_tui/src/backend_next/tui_protocol_backend.dart';
import 'package:wristload_tui/src/backend_next/tui_protocol_snapshot.dart';
import 'package:wristload_tui/src/domain/device_profile.dart';
import 'package:wristload_tui/src/domain/install_models.dart';
import 'package:wristload_tui/src/domain/install_task.dart';
import 'package:wristload_tui/src/domain/protocol/auth_handshake.dart';
import 'package:wristload_tui/src/domain/protocol/proto_wire.dart';
import 'package:wristload_tui/src/domain/protocol/spp_protocol.dart';
import 'package:wristload_tui/src/diagnostics/diagnostic_journal.dart';

const testAuthKey = '00112233445566778899aabbccddeeff';

final testBinding = TuiBackendBindingMaterial(
  appDeviceId: 'tui-app-device',
  oob: 'tui-oob',
);

void main() {
  const authKey = testAuthKey;
  late _FakeProtocolTransport transport;
  late TuiProtocolBackend backend;

  setUp(() {
    transport = _FakeProtocolTransport();
    backend = TuiProtocolBackend(
      transport: transport,
      handshakeTimeout: const Duration(milliseconds: 250),
    )..setAuthKey(authKey);
  });

  tearDown(() => backend.dispose());

  test('missing binding uses the official nonce-only Classic f=26 path',
      () async {
    final device = TuiTransportDevice(
      address: '12-34-56-78-9A-BC',
      name: 'Xiaomi Smart Band 10',
    );

    await backend.connect(
      device,
      profile: DeviceProfile.band10,
      bindingMaterial: null,
    );
    expect(transport.connectCalls, 1);
    expect(transport.writes.single, SppProtocol.buildL1StartRequest());
    final disconnectsBeforeL1Response = transport.disconnectCalls;

    transport
        .emitPacket(SppProtocol.encodeCmd(SppProtocol.cmdL1StartRsp, const []));
    await _flush();
    expect(transport.writes, hasLength(2));
    expect(_authSubtype(transport.writes.last), XiaomiAuth.cmdNonce);
    final f26 =
        XiaomiAuth.parse(_decode(transport.writes.last).payload.sublist(2));
    expect(f26?.appNonce, hasLength(16));
    expect(f26?.appDeviceId, isNull);
    expect(f26?.hasOob, isFalse);
    expect(
        backend.snapshot.connection, TuiProtocolConnectionState.authenticating);
    expect(transport.disconnectCalls, disconnectsBeforeL1Response);

    final phoneNonce = _phoneNonceFromF26(transport.writes.last);
    final watchNonce = List<int>.generate(16, (index) => index + 48);
    transport.emitPacket(SppProtocol.buildDataFrame(
      7,
      _watchNonceResponse(
        watchNonce,
        _watchHmac(phoneNonce, watchNonce, includeBinding: false),
      ),
    ));
    await _flush();
    expect(_authSubtype(transport.writes.last), XiaomiAuth.cmdAuth);

    transport.emitPacket(SppProtocol.buildDataFrame(8, _authConfirmation()));
    await _flush();
    expect(backend.snapshot.connection, TuiProtocolConnectionState.ready);
    expect(backend.snapshot.failureCode, isNull);
  });

  test('accepts the complete captured Band 10 L1START response and sends f=26',
      () async {
    await backend.connect(
      TuiTransportDevice(
        address: '12-34-56-78-9A-BC',
        name: 'Xiaomi Smart Band 10',
      ),
      profile: DeviceProfile.band10,
      bindingMaterial: testBinding,
    );

    // Captured from the real Band 10 after the current L1START request. This
    // is a CRC-valid CMD response with version, MPS, TX-window, and timeout.
    const response = <int>[
      0xa5,
      0xa5,
      0x02,
      0x00,
      0x16,
      0x00,
      0x76,
      0x00,
      0x02,
      0x01,
      0x03,
      0x00,
      0x03,
      0x01,
      0x0b,
      0x02,
      0x02,
      0x00,
      0x00,
      0x80,
      0x03,
      0x02,
      0x00,
      0x03,
      0x00,
      0x04,
      0x02,
      0x00,
      0x70,
      0x17,
    ];
    final configuration = SppProtocol.parseL1StartResponse(
      _decode(response).payload,
    );
    expect(configuration.version, '3.1.11');
    expect(configuration.remoteMps, 32768);
    expect(configuration.remoteTxWindow, 3);
    expect(configuration.remoteSendTimeoutMs, 6000);

    final disconnectsBeforeResponse = transport.disconnectCalls;
    transport.emitPacket(response);
    await _flush();

    expect(transport.disconnectCalls, disconnectsBeforeResponse);
    expect(
        backend.snapshot.connection, TuiProtocolConnectionState.authenticating);
    expect(_authSubtype(transport.writes.last), XiaomiAuth.cmdNonce);
  });

  test('rejects a malformed L1START configuration before f=26', () async {
    await backend.connect(
      TuiTransportDevice(
        address: '12-34-56-78-9A-BC',
        name: 'Xiaomi Smart Band 10',
      ),
      profile: DeviceProfile.band10,
      bindingMaterial: testBinding,
    );

    // VERSION declares three bytes but only carries two. The outer L1 CRC is
    // valid, so this covers the inner configuration-boundary check.
    transport.emitPacket(SppProtocol.encodeCmd(
      SppProtocol.cmdL1StartRsp,
      const <int>[SppProtocol.l1ConfigTypeVersion, 0x03, 0x00, 0x03, 0x01],
    ));
    await _flush();

    expect(transport.writes, hasLength(1));
    expect(backend.sessionReady, isFalse);
    expect(
        backend.snapshot.connection, TuiProtocolConnectionState.disconnected);
    expect(transport.disconnectCalls, greaterThan(0));
  });

  test('awaits DATA ACK write before f=27 and only valid confirm reaches ready',
      () async {
    await _startF26(backend, transport);
    final phoneNonce = _phoneNonceFromF26(transport.writes.last);
    final watchNonce = List<int>.generate(16, (index) => index + 32);
    final watchHmac = _watchHmac(phoneNonce, watchNonce);
    final ackGate = Completer<void>();
    transport.nextWriteGate = ackGate;

    transport.emitPacket(SppProtocol.buildDataFrame(
        7, _watchNonceResponse(watchNonce, watchHmac)));
    await _flush();

    expect(transport.writes.last, SppProtocol.buildAck(7));
    expect(transport.writes.length, 3);
    expect(backend.sessionReady, isFalse);

    ackGate.complete();
    await _flush();
    expect(transport.writes.length, 4);
    expect(_authSubtype(transport.writes.last), XiaomiAuth.cmdAuth);

    transport.emitPacket(
      SppProtocol.buildDataFrame(8, _authConfirmation()),
    );
    await _flush();

    expect(transport.writes.last, SppProtocol.buildAck(8));
    expect(backend.snapshot.connection, TuiProtocolConnectionState.ready);
  });

  test('device signature mismatch closes before f=27 without a write failure',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('wristload-signature-journal-');
    addTearDown(() => directory.delete(recursive: true));
    final journal = DiagnosticJournal(File('${directory.path}/events.jsonl'));
    final localTransport = _FakeProtocolTransport();
    final localBackend = TuiProtocolBackend(
      transport: localTransport,
      diagnosticJournal: journal,
      handshakeTimeout: const Duration(milliseconds: 250),
    )..setAuthKey(testAuthKey);
    addTearDown(localBackend.dispose);

    await _startF26(localBackend, localTransport);
    final writesBeforeResponse = localTransport.writes.length;
    final watchNonce = List<int>.generate(16, (index) => index + 96);

    // This is structurally valid f=26 data with a signature that does not
    // match the current authkey/binding context. The backend must ACK the
    // received frame but must not construct or transmit f=27.
    localTransport.emitPacket(SppProtocol.buildDataFrame(7,
        _watchNonceResponse(watchNonce, List<int>.filled(32, 0))));
    await _flush();

    expect(localTransport.writes, hasLength(writesBeforeResponse + 1));
    expect(
      localTransport.writes.where((frame) {
        final packet = _decode(frame);
        if (packet.type != SppProtocol.typeData || packet.payload.length < 2) {
          return false;
        }
        return XiaomiAuth.parse(packet.payload.sublist(2))?.subtype ==
            XiaomiAuth.cmdAuth;
      }),
      isEmpty,
    );
    expect(localBackend.snapshot.connection,
        TuiProtocolConnectionState.disconnected);
    expect(localBackend.snapshot.failureCode,
        deviceSignatureMismatchFailureCode);
    expect(localTransport.disconnectCalls, greaterThan(0));

    await Future<void>.delayed(const Duration(milliseconds: 50));
    final events = await journal.read();
    final failure =
        events.singleWhere((event) => event.event == 'auth.failure');
    expect(failure.fields['reason'], deviceSignatureMismatchFailureCode);
    expect(failure.stage, 'f26.response');
    expect(events.map((event) => event.event), isNot(contains('auth.f27.sent')));
    final raw = await File('${directory.path}/events.jsonl').readAsString();
    expect(raw, isNot(contains(testAuthKey)));
    expect(raw, isNot(contains(testBinding.appDeviceId)));
    expect(raw, isNot(contains(testBinding.oob)));
  });

  test('rejects wrong handshake channel before ACK or state mutation',
      () async {
    await _startF26(backend, transport);
    final writesBefore = transport.writes.length;

    transport.emitPacket(SppProtocol.buildDataFrame(9, const [1, 2, 3],
        channel: SppProtocol.channelMass));
    await _flush();

    expect(transport.writes.length, writesBefore);
    expect(backend.sessionReady, isFalse);
    expect(
        backend.snapshot.connection, TuiProtocolConnectionState.disconnected);
    expect(transport.disconnectCalls, greaterThan(0));
  });

  test('rejects unsolicited and duplicate f=27 confirmation', () async {
    await _startF26(backend, transport);

    transport.emitPacket(SppProtocol.buildDataFrame(10, _authConfirmation()));
    await _flush();

    expect(backend.sessionReady, isFalse);
    expect(
        backend.snapshot.connection, TuiProtocolConnectionState.disconnected);
  });

  test(
      'timeout clears pending f=27 material and stale confirmation stays rejected',
      () async {
    await _startF26(backend, transport);
    final phoneNonce = _phoneNonceFromF26(transport.writes.last);
    final watchNonce = List<int>.generate(16, (index) => index + 64);
    final watchHmac = _watchHmac(phoneNonce, watchNonce);

    transport.emitPacket(SppProtocol.buildDataFrame(
        11, _watchNonceResponse(watchNonce, watchHmac)));
    await _flush();
    expect(_authSubtype(transport.writes.last), XiaomiAuth.cmdAuth);

    await Future<void>.delayed(const Duration(milliseconds: 320));
    expect(
        backend.snapshot.connection, TuiProtocolConnectionState.disconnected);

    final writesBefore = transport.writes.length;
    transport.emitPacket(SppProtocol.buildDataFrame(12, _authConfirmation()));
    await _flush();
    expect(transport.writes.length, writesBefore);
    expect(backend.sessionReady, isFalse);
  });

  test('post-auth RFCOMM recovery uses the injected owned reconnect boundary',
      () async {
    await _completeReady(backend, transport);
    var reconnectCalls = 0;
    backend.setPostAuthReconnectHandler((device) async {
      reconnectCalls++;
      expect(device.addressKey, '123456789ABC');
    });

    transport.emitPacket(Uint8List(0));
    await Future<void>.delayed(const Duration(milliseconds: 650));

    expect(reconnectCalls, 1);
    // Initial connect only; post-auth recovery must not bypass the injected
    // adapter-owned attempt by invoking the raw transport directly.
    expect(transport.connectCalls, 1);
    expect(transport.writes.last, SppProtocol.buildL1StartRequest());

    transport
        .emitPacket(SppProtocol.encodeCmd(SppProtocol.cmdL1StartRsp, const []));
    await _flush();
    expect(backend.sessionReady, isTrue);
  });

  test('an old L1 watchdog cannot invalidate a newer f=26 phase', () async {
    await backend.connect(
      TuiTransportDevice(
        address: '12-34-56-78-9A-BC',
        name: 'Xiaomi Smart Band 10',
      ),
      profile: DeviceProfile.band10,
      bindingMaterial: testBinding,
    );
    transport.nextWriteGate = Completer<void>();
    transport
        .emitPacket(SppProtocol.encodeCmd(SppProtocol.cmdL1StartRsp, const []));
    await Future<void>.delayed(const Duration(milliseconds: 320));

    // The f=26 write is still gated, but the old L1 watchdog has elapsed.
    // Phase-token fencing must keep the newer authenticating phase alive.
    expect(
        backend.snapshot.connection, TuiProtocolConnectionState.authenticating);
    transport.nextWriteGate = null;
    // Release the original gate.
    // The fake consumes the gate when the f=26 write is started.
    expect(transport.pendingWriteGate, isNotNull);
    transport.pendingWriteGate!.complete();
    await _flush();
    expect(
        backend.snapshot.connection, TuiProtocolConnectionState.authenticating);
  });

  test('writes protocol lifecycle events to the redacted diagnostic journal',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('wristload-protocol-journal-');
    addTearDown(() => directory.delete(recursive: true));
    final journal = DiagnosticJournal(File('${directory.path}/events.jsonl'));
    final localTransport = _FakeProtocolTransport();
    final localBackend = TuiProtocolBackend(
      transport: localTransport,
      diagnosticJournal: journal,
      handshakeTimeout: const Duration(milliseconds: 250),
    )..setAuthKey(testAuthKey);
    addTearDown(localBackend.dispose);

    await _startF26(localBackend, localTransport);
    final phoneNonce = _phoneNonceFromF26(localTransport.writes.last);
    final watchNonce = List<int>.generate(16, (index) => index + 32);
    localTransport.emitPacket(SppProtocol.buildDataFrame(
      7,
      _watchNonceResponse(watchNonce, _watchHmac(phoneNonce, watchNonce)),
    ));
    await _flush();
    localTransport.emitPacket(
      SppProtocol.buildDataFrame(8, _authConfirmation()),
    );
    await _flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final events = await journal.read();
    final names = events.map((event) => event.event).toSet();
    expect(
        names,
        containsAll(<String>{
          'session.transition',
          'protocol.l1start.sent',
          'protocol.l1start.accepted',
          'auth.f26.sent',
          'auth.f26.response_received',
          'auth.f27.sent',
          'auth.success',
          'session.ready',
        }));
    expect(events.any((event) => event.category == DiagnosticCategory.auth),
        isTrue);
    final f26 = events.singleWhere((event) => event.event == 'auth.f26.sent');
    expect(f26.fields['bindingMaterial'], 'provided');
    final raw = await File('${directory.path}/events.jsonl').readAsString();
    expect(raw, isNot(contains(testAuthKey)));
    expect(raw, isNot(contains(testBinding.appDeviceId)));
    expect(raw, isNot(contains(testBinding.oob)));
  });

  test('journals watchdog auth failure without sensitive values', () async {
    final directory =
        await Directory.systemTemp.createTemp('wristload-timeout-journal-');
    addTearDown(() => directory.delete(recursive: true));
    final journal = DiagnosticJournal(File('${directory.path}/events.jsonl'));
    final localTransport = _FakeProtocolTransport();
    final localBackend = TuiProtocolBackend(
      transport: localTransport,
      diagnosticJournal: journal,
      handshakeTimeout: const Duration(milliseconds: 40),
    )..setAuthKey(testAuthKey);
    addTearDown(localBackend.dispose);

    await localBackend.connect(
      TuiTransportDevice(
        address: '12-34-56-78-9A-BC',
        name: 'Xiaomi Smart Band 10',
      ),
      profile: DeviceProfile.band10,
      bindingMaterial: testBinding,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final events = await journal.read();
    final timeout =
        events.singleWhere((event) => event.event == 'watchdog.timeout');
    expect(timeout.timeoutMs, 40);
    expect(timeout.stage, 'l1StartSent');
    final failure =
        events.singleWhere((event) => event.event == 'auth.failure');
    expect(failure.fields['reason'], 'watchdog_timeout');
    final raw = await File('${directory.path}/events.jsonl').readAsString();
    expect(raw, isNot(contains(testAuthKey)));
    expect(raw, isNot(contains(testBinding.appDeviceId)));
    expect(raw, isNot(contains(testBinding.oob)));
  });

  test('journals install retry and deferred lifecycle without request data',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('wristload-install-journal-');
    addTearDown(() => directory.delete(recursive: true));
    final journal = DiagnosticJournal(File('${directory.path}/events.jsonl'));
    final localTransport = _FakeProtocolTransport();
    final localBackend = TuiProtocolBackend(
      transport: localTransport,
      diagnosticJournal: journal,
    );
    addTearDown(localBackend.dispose);
    const request = InstallRequest(
      kind: InstallKind.quickApp,
      path: '/private/secret/package.rpk',
      metadata: InstallMetadata(
        fileName: 'private-package.rpk',
        fileSize: 42,
        md5Hex: '00112233445566778899aabbccddeeff',
        sha256Hex:
            '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff',
        packageName: 'private.package.name',
        versionCode: 7,
      ),
    );

    await localBackend.startInstall(request);
    localBackend.enqueue(request);
    final entry = localBackend.queue.single
      ..stage = QueueStage.failed
      ..failureAttempts = 2;
    await expectLater(localBackend.retry(entry), throwsStateError);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final events = await journal.read();
    final deferred =
        events.singleWhere((event) => event.event == 'install.deferred');
    expect(deferred.stage, 'waitingForProtocol');
    expect(deferred.fields['kind'], 'quickApp');
    final retry = events.singleWhere((event) => event.event == 'install.retry');
    expect(retry.retry, 3);
    final raw = await File('${directory.path}/events.jsonl').readAsString();
    expect(raw, isNot(contains(request.path)));
    expect(raw, isNot(contains(request.metadata.fileName)));
    expect(raw, isNot(contains(request.metadata.md5Hex)));
    expect(raw, isNot(contains(request.metadata.sha256Hex)));
    expect(raw, isNot(contains(request.metadata.packageName!)));
  });
}

Future<void> _completeReady(
  TuiProtocolBackend backend,
  _FakeProtocolTransport transport,
) async {
  await _startF26(backend, transport);
  final phoneNonce = _phoneNonceFromF26(transport.writes.last);
  final watchNonce = List<int>.generate(16, (index) => index + 32);
  final watchHmac = _watchHmac(phoneNonce, watchNonce);
  transport.emitPacket(SppProtocol.buildDataFrame(
      7, _watchNonceResponse(watchNonce, watchHmac)));
  await _flush();
  transport.emitPacket(SppProtocol.buildDataFrame(8, _authConfirmation()));
  await _flush();
  expect(backend.sessionReady, isTrue);
}

Future<void> _startF26(
  TuiProtocolBackend backend,
  _FakeProtocolTransport transport,
) async {
  await backend.connect(
    TuiTransportDevice(
      address: '12-34-56-78-9A-BC',
      name: 'Xiaomi Smart Band 10',
    ),
    profile: DeviceProfile.band10,
    bindingMaterial: testBinding,
  );
  transport
      .emitPacket(SppProtocol.encodeCmd(SppProtocol.cmdL1StartRsp, const []));
  await _flush();
  expect(_authSubtype(transport.writes.last), XiaomiAuth.cmdNonce);
  final parsed =
      XiaomiAuth.parse(_decode(transport.writes.last).payload.sublist(2));
  expect(parsed?.appDeviceId, 'tui-app-device');
  expect(parsed?.hasOob, isTrue);
}

List<int> _watchHmac(
  List<int> phoneNonce,
  List<int> watchNonce, {
  bool includeBinding = true,
}) {
  final secret = XiaomiAuth.secretKeyFromHex(testAuthKey)!;
  final keys = XiaomiAuth.computeStep3Hmac(secret, phoneNonce, watchNonce);
  final signInput = <int>[...watchNonce, ...phoneNonce];
  final oob = includeBinding ? testBinding.oob : null;
  if (oob != null) signInput.addAll(oob.codeUnits);
  return XiaomiAuth.hmacSha256(keys.sublist(0, 16), signInput);
}

List<int> _phoneNonceFromF26(List<int> frame) {
  final packet = _decode(frame);
  return XiaomiAuth.parse(packet.payload.sublist(2))!.appNonce!;
}

int? _authSubtype(List<int> frame) {
  final packet = _decode(frame);
  return XiaomiAuth.parse(packet.payload.sublist(2))?.subtype;
}

SppPacket _decode(List<int> frame) {
  final accumulator = Accumulator()..buffer = frame;
  return SppProtocol.parse(accumulator).single;
}

List<int> _watchNonceResponse(List<int> nonce, List<int> hmac) {
  final verify = ProtoWriter()
    ..writeBytes(1, nonce)
    ..writeBytes(2, hmac);
  final command = ProtoWriter()..writeMessage(31, verify.bytes);
  return (ProtoWriter()
        ..writeInt(1, XiaomiAuth.commandType)
        ..writeInt(2, XiaomiAuth.cmdNonce)
        ..writeMessage(3, command.bytes))
      .bytes;
}

List<int> _authConfirmation() {
  final confirm = ProtoWriter()..writeInt(1, 1);
  final command = ProtoWriter()..writeMessage(33, confirm.bytes);
  return (ProtoWriter()
        ..writeInt(1, XiaomiAuth.commandType)
        ..writeInt(2, XiaomiAuth.cmdAuth)
        ..writeMessage(3, command.bytes))
      .bytes;
}

Future<void> _flush() => Future<void>.delayed(const Duration(milliseconds: 50));

final class _FakeProtocolTransport implements TuiMacBluetoothTransport {
  final _input = StreamController<Uint8List>.broadcast(sync: true);
  final _errors = StreamController<Object>.broadcast(sync: true);
  final _discoveries =
      StreamController<TuiTransportDevice>.broadcast(sync: true);
  final _snapshots =
      StreamController<TuiMacTransportSnapshot>.broadcast(sync: true);
  final List<List<int>> writes = [];
  Completer<void>? nextWriteGate;
  Completer<void>? pendingWriteGate;
  int connectCalls = 0;
  int disconnectCalls = 0;
  TuiMacTransportSnapshot _snapshot = const TuiMacTransportSnapshot.stopped();

  void emitPacket(List<int> bytes) => _input.add(Uint8List.fromList(bytes));

  @override
  Stream<Uint8List> get input => _input.stream;
  @override
  Stream<Object> get errors => _errors.stream;
  @override
  Stream<TuiTransportDevice> get discoveries => _discoveries.stream;
  @override
  Stream<TuiPairingStage> get pairingStages =>
      const Stream<TuiPairingStage>.empty();
  @override
  Stream<TuiMacTransportSnapshot> get snapshots => _snapshots.stream;
  @override
  TuiMacTransportSnapshot get snapshot => _snapshot;
  @override
  Future<void> start() async {}
  @override
  Future<List<TuiTransportDevice>> listPairedDevices() async => const [];
  @override
  Future<void> startScan(
      {Duration duration = const Duration(seconds: 10)}) async {}
  @override
  Future<void> stopScan() async {}
  @override
  Future<TuiIdentityResolutionResult> resolveIdentity(
          TuiIdentityCandidate candidate) async =>
      TuiIdentityResolutionResult(
          candidateId: candidate.candidateId,
          resolution: TuiIdentityResolution.directClassic,
          identityState: TuiIdentityState.provisional);
  @override
  Future<TuiPairingResult> startPairing(TuiIdentityCandidate candidate) async =>
      throw UnsupportedError('pairing not used by protocol test');
  @override
  Future<void> cancelPairing({String? pairingId}) async {}
  @override
  Future<TuiIdentityResolutionResult> confirmIdentity(
          TuiIdentityConfirmation confirmation) async =>
      TuiIdentityResolutionResult(
          candidateId: confirmation.candidateId,
          resolution: TuiIdentityResolution.confirmed,
          identityState: TuiIdentityState.confirmed);
  @override
  Future<TuiIdentityForgetResult> forgetIdentity(String candidateId) async =>
      const TuiIdentityForgetResult(
          candidateId: '',
          forgotten: true,
          unpaired: false,
          disconnected: false);
  @override
  Future<void> connect(TuiTransportDevice device,
      {String serviceUuid = '00001101-0000-1000-8000-00805f9b34fb'}) async {
    connectCalls++;
    _snapshot = const TuiMacTransportSnapshot(
        helperState: TuiMacHelperState.ready, scanning: false, connected: true);
  }

  @override
  Future<void> write(List<int> bytes) async {
    writes.add(List<int>.from(bytes));
    final gate = nextWriteGate;
    nextWriteGate = null;
    pendingWriteGate = gate;
    await gate?.future;
    pendingWriteGate = null;
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _snapshot = const TuiMacTransportSnapshot(
        helperState: TuiMacHelperState.ready,
        scanning: false,
        connected: false);
  }

  @override
  Future<void> dispose() async {
    await _input.close();
    await _errors.close();
    await _discoveries.close();
    await _snapshots.close();
  }
}
