import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wristload_tui/src/backend_next/macos_tui_backend_adapter.dart';
import 'package:wristload_tui/src/backend_next/tui_mac_bluetooth_transport.dart';
import 'package:wristload_tui/src/backend_next/tui_protocol_backend.dart';
import 'package:wristload_tui/src/backend_next/tui_backend_port.dart';
import 'package:wristload_tui/src/domain/device_profile.dart';
import 'package:wristload_tui/src/diagnostics/diagnostic_journal.dart';

void main() {
  final bindingMaterial = TuiBackendBindingMaterial(
    appDeviceId: 'adapter-test-app-device-id',
    oob: 'adapter-test-oob',
  );
  late _FakeMacTransport transport;
  late MacOsTuiBackendAdapter adapter;

  setUp(() {
    transport = _FakeMacTransport();
    adapter = MacOsTuiBackendAdapter.withDependencies(
      transport: transport,
      backend: TuiProtocolBackend(transport: transport),
    );
  });

  tearDown(() => adapter.dispose());

  test('initialization starts the helper without querying paired devices',
      () async {
    await adapter.initialize();

    expect(transport.calls, ['start']);
  });

  test(
      'production factory injects the shared diagnostic journal into transport',
      () async {
    if (!Platform.isMacOS) return;
    final directory =
        await Directory.systemTemp.createTemp('wristload-factory-journal-');
    addTearDown(() => directory.delete(recursive: true));
    final journal = DiagnosticJournal(File('${directory.path}/events.jsonl'));
    final factoryAdapter = MacOsTuiBackendAdapter(
      helperPath: 'controlled-helper',
      diagnosticJournal: journal,
      processStarter: (_) => Process.start(
        '/usr/bin/python3',
        <String>['-u', '-c', _journalHelperSource],
        runInShell: false,
      ),
    );
    addTearDown(factoryAdapter.dispose);

    await factoryAdapter.initialize();
    final events = await _waitForJournalEvents(journal);
    expect(events, isNotEmpty);
    expect(events.any((event) => event.event == 'hello.done'), isTrue);
  });

  test('merges paired and inquiry rows by normalized classic MAC', () async {
    transport.pairedDevices = [
      TuiTransportDevice(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'Xiaomi Smart Band 10',
        paired: true,
        source: TuiTransportDeviceSource.paired,
      ),
    ];

    await adapter.initialize();
    await adapter.refreshPairedDevices();
    transport.discover(
      TuiTransportDevice(
        address: 'aa-bb-cc-dd-ee-ff',
        name: 'Xiaomi Smart Band 10 full name',
        rssi: -48,
        source: TuiTransportDeviceSource.inquiry,
      ),
    );

    final device = adapter.snapshot.devices.single;
    expect(device.addressKey, 'AABBCCDDEEFF');
    expect(device.name, 'Xiaomi Smart Band 10 full name');
    expect(device.paired, isTrue);
    expect(device.rssi, -48);
    expect(device.supported, isTrue);
    expect(
        device.sources,
        containsAll({
          TuiBackendDeviceSource.paired,
          TuiBackendDeviceSource.inquiry,
        }));
  });

  test('saved-device connect uses MAC directly and does not scan', () async {
    const key = '00112233445566778899aabbccddeeff';
    await adapter.provideAuthKey(key);
    await adapter.connectByAddress(
      address: '12:34:56:78:9A:BC',
      name: 'Xiaomi Smart Band 10',
      profile: DeviceProfile.band10,
      bindingMaterial: bindingMaterial,
    );

    expect(transport.calls, [
      'disconnect',
      'connect:12-34-56-78-9A-BC',
      startsWith('write:'),
    ]);
    expect(transport.calls, isNot(contains('scan.start')));
    expect(adapter.snapshot.activeDeviceAddress, '12-34-56-78-9A-BC');
    expect(adapter.snapshot.authKeyLoaded, isTrue);
    expect(adapter.snapshot.transportConnected, isTrue);
    expect(adapter.snapshot.connectionId, transport.latestConnectionId);
    expect(adapter.snapshot.connectionGeneration, 7);
    expect(
      adapter.snapshot.connection,
      TuiBackendConnectionState.authenticating,
    );
    expect(adapter.snapshot.message, isNot(contains(key)));

    await adapter.disconnect();
    expect(adapter.snapshot.transportConnected, isFalse);
    expect(adapter.snapshot.connectionId, isNull);
    expect(adapter.snapshot.connectionGeneration, isNull);
  });

  test('stops an active inquiry before starting directed pairing', () async {
    transport.resolvedDevicePaired = false;
    await transport.startScan();

    await adapter.provideAuthKey('00112233445566778899aabbccddeeff');
    await adapter.connectByAddress(
      address: '12:34:56:78:9A:BC',
      name: 'Xiaomi Smart Band 10',
      profile: DeviceProfile.band10,
      directedExactAddress: true,
      bindingMaterial: bindingMaterial,
    );

    expect(transport.calls.indexOf('scan.stop'),
        lessThan(transport.calls.indexOf('pair.start')));
    expect(transport.calls.indexOf('pair.start'),
        lessThan(transport.calls.indexOf('connect:12-34-56-78-9A-BC')));
    expect(transport.snapshot.scanning, isFalse);
  });

  test('waits for inquiry stop completion before pairing', () async {
    transport.resolvedDevicePaired = false;
    await transport.startScan();
    transport.stopScanGate = Completer<void>();

    final connecting = adapter.connectByAddress(
      address: '12:34:56:78:9A:BC',
      name: 'Xiaomi Smart Band 10',
      profile: DeviceProfile.band10,
      bindingMaterial: bindingMaterial,
    );
    for (var attempt = 0;
        attempt < 20 && !transport.calls.contains('scan.stop');
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(transport.calls, contains('scan.stop'));
    expect(transport.calls, isNot(contains('pair.start')));

    transport.stopScanGate!.complete();
    await connecting;
    expect(transport.calls.indexOf('scan.stop'),
        lessThan(transport.calls.indexOf('pair.start')));
  });

  test('stop-scan failure prevents pairing from starting', () async {
    transport.resolvedDevicePaired = false;
    await transport.startScan();
    transport.failStopScan = true;

    await expectLater(
      adapter.connectByAddress(
        address: '12:34:56:78:9A:BC',
        name: 'Xiaomi Smart Band 10',
        profile: DeviceProfile.band10,
        bindingMaterial: bindingMaterial,
      ),
      throwsA(isA<StateError>()),
    );
    expect(transport.calls, contains('scan.stop'));
    expect(transport.calls, isNot(contains('pair.start')));
  });

  test(
      'manual directed address enables exact-address identity intent only explicitly',
      () async {
    await adapter.provideAuthKey('00112233445566778899aabbccddeeff');
    await adapter.connectByAddress(
      address: '12:34:56:78:9A:BC',
      name: 'Xiaomi Smart Band 10',
      profile: DeviceProfile.band10,
      directedExactAddress: true,
      bindingMaterial: bindingMaterial,
    );

    expect(transport.lastDirectedExactAddress, isTrue);
    await adapter.disconnect();

    await adapter.provideAuthKey('00112233445566778899aabbccddeeff');
    await adapter.connectByAddress(
      address: '12:34:56:78:9A:BC',
      name: 'Xiaomi Smart Band 10',
      profile: DeviceProfile.band10,
      bindingMaterial: bindingMaterial,
    );
    expect(transport.lastDirectedExactAddress, isFalse);
  });

  test('forwards immutable per-device binding material to the protocol session',
      () async {
    final bindingTransport = _FakeMacTransport();
    final bindingBackend = _BindingCapturingProtocolBackend(bindingTransport);
    final bindingAdapter = MacOsTuiBackendAdapter.withDependencies(
      transport: bindingTransport,
      backend: bindingBackend,
    );
    addTearDown(bindingAdapter.dispose);
    final binding = TuiBackendBindingMaterial(
      appDeviceId: 'tui-test-app-device',
      oob: 'tui-test-oob',
    );

    await bindingAdapter.connectByAddress(
      address: '12:34:56:78:9A:BC',
      name: 'Xiaomi Smart Band 10',
      profile: DeviceProfile.band10,
      bindingMaterial: binding,
    );

    expect(bindingBackend.bindingMaterial, same(binding));
    expect(bindingBackend.connectedDevice?.addressKey, '123456789ABC');
  });

  test('connect rejects stale same-MAC tuples until the current connect.done',
      () async {
    const address = '12:34:56:78:9A:BC';
    const addressKey = '123456789ABC';
    const oldConnectionId = 'old-connection';
    const oldGeneration = 6;

    transport.emitSnapshot(
      _nativeSnapshot(
        connected: true,
        connectionId: oldConnectionId,
        connectionGeneration: oldGeneration,
        addressKey: addressKey,
        stage: 'connect.done',
        stageCode: 'connected',
        stageDetail: 'old RFCOMM connection',
      ),
    );

    void expectNoNativeTuple() {
      expect(adapter.snapshot.connectionId, isNull);
      expect(adapter.snapshot.connectionGeneration, isNull);
    }

    expectNoNativeTuple();
    transport.deferConnectDone = true;
    transport.connectStarted = Completer<void>();

    final connect = adapter.connectByAddress(
      address: address,
      name: 'Xiaomi Smart Band 10',
      profile: DeviceProfile.band10,
      bindingMaterial: bindingMaterial,
    );
    await transport.connectStarted!.future;

    transport.emitSnapshot(
      _nativeSnapshot(
        connected: true,
        connectionId: oldConnectionId,
        connectionGeneration: oldGeneration,
        addressKey: addressKey,
        stage: 'error',
        stageCode: 'native_error',
        stageDetail: 'late error from retired connection',
      ),
    );
    expectNoNativeTuple();

    transport.emitSnapshot(
      _nativeSnapshot(
        connected: false,
        connectionId: oldConnectionId,
        connectionGeneration: oldGeneration,
        addressKey: addressKey,
        stage: 'closed',
        stageCode: 'error',
        stageDetail: 'late close from retired connection',
      ),
    );
    expectNoNativeTuple();

    final newConnectionId = transport.pendingConnectionId;
    expect(newConnectionId, isNotNull);
    transport.emitPendingConnectDone();

    expect(adapter.snapshot.connectionId, newConnectionId);
    expect(adapter.snapshot.connectionGeneration, 7);
    await connect;
  });

  test('connect rejects a lower native generation with a different tuple',
      () async {
    const address = '12:34:56:78:9A:BC';
    const addressKey = '123456789ABC';
    transport.emitSnapshot(
      _nativeSnapshot(
        connected: true,
        connectionId: 'previous-connection',
        connectionGeneration: 6,
        addressKey: addressKey,
        stage: 'connect.done',
        stageCode: 'connected',
        stageDetail: 'previous RFCOMM connection',
      ),
    );
    transport.deferConnectDone = true;
    transport.connectStarted = Completer<void>();

    final connect = adapter.connectByAddress(
      address: address,
      name: 'Xiaomi Smart Band 10',
      profile: DeviceProfile.band10,
      bindingMaterial: bindingMaterial,
    );
    await transport.connectStarted!.future;

    transport.emitSnapshot(
      _nativeSnapshot(
        connected: true,
        connectionId: 'older-but-distinct',
        connectionGeneration: 5,
        addressKey: addressKey,
        stage: 'connect.done',
        stageCode: 'connected',
        stageDetail: 'late lower native generation',
      ),
    );
    expect(adapter.snapshot.connectionId, isNull);
    expect(adapter.snapshot.connectionGeneration, isNull);

    transport.emitPendingConnectDone();
    await connect;
    expect(adapter.snapshot.connectionGeneration, 7);
  });

  test('post-auth reconnect uses a fresh adapter-owned native tuple', () async {
    final reconnectTransport = _FakeMacTransport();
    final reconnectBackend = _CapturingProtocolBackend(reconnectTransport);
    final reconnectAdapter = MacOsTuiBackendAdapter.withDependencies(
      transport: reconnectTransport,
      backend: reconnectBackend,
    );
    addTearDown(reconnectAdapter.dispose);

    await reconnectAdapter.provideAuthKey(
      '00112233445566778899aabbccddeeff',
    );
    await reconnectAdapter.connectByAddress(
      address: '12:34:56:78:9A:BC',
      name: 'Xiaomi Smart Band 10',
      profile: DeviceProfile.band10,
      bindingMaterial: bindingMaterial,
    );
    final retired = reconnectAdapter.snapshot.connectionId;
    expect(retired, isNotNull);
    final handler = reconnectBackend.reconnectHandler;
    expect(handler, isNotNull);

    reconnectTransport.deferConnectDone = true;
    reconnectTransport.connectStarted = Completer<void>();
    final reconnect = handler!(
      TuiTransportDevice(
        address: '12:34:56:78:9A:BC',
        name: 'Xiaomi Smart Band 10',
        paired: true,
        source: TuiTransportDeviceSource.manual,
      ),
    );
    await reconnectTransport.connectStarted!.future;
    expect(reconnectAdapter.snapshot.connectionId, isNull);

    reconnectTransport.emitSnapshot(
      _nativeSnapshot(
        connected: true,
        connectionId: retired!,
        connectionGeneration: 7,
        addressKey: '123456789ABC',
        stage: 'connect.done',
        stageCode: 'connected',
        stageDetail: 'retired tuple',
      ),
    );
    expect(reconnectAdapter.snapshot.connectionId, isNull);

    final fresh = reconnectTransport.pendingConnectionId;
    expect(fresh, isNot(retired));
    reconnectTransport.emitPendingConnectDone();
    await reconnect;
    expect(reconnectAdapter.snapshot.connectionId, fresh);
    expect(reconnectAdapter.snapshot.connectionGeneration, 8);
  });

  test(
      'stale serialized and post-auth failures cannot retire a newer native tuple',
      () async {
    final raceTransport = _FakeMacTransport();
    final raceBackend = _TransportOnlyProtocolBackend(raceTransport);
    final raceAdapter = MacOsTuiBackendAdapter.withDependencies(
      transport: raceTransport,
      backend: raceBackend,
    );
    addTearDown(raceAdapter.dispose);
    final device = TuiTransportDevice(
      address: '12:34:56:78:9A:BC',
      name: 'Xiaomi Smart Band 10',
      paired: true,
      source: TuiTransportDeviceSource.manual,
    );

    await raceAdapter.connectByAddress(
      address: device.address,
      name: device.name,
      profile: DeviceProfile.band10,
      bindingMaterial: bindingMaterial,
    );
    expect(raceAdapter.snapshot.connectionGeneration, 7);
    final handler = raceBackend.reconnectHandler;
    expect(handler, isNotNull);

    raceTransport.deferConnectDone = true;
    raceTransport.connectStarted = Completer<void>();
    final staleSerialized = raceAdapter.connectByAddress(
      address: device.address,
      name: device.name,
      profile: DeviceProfile.band10,
      bindingMaterial: bindingMaterial,
    );
    final staleObserved = staleSerialized.then<void>(
      (_) {},
      onError: (Object _) {},
    );
    await raceTransport.connectStarted!.future;
    final staleConnectionId = raceTransport.pendingConnectionId;
    expect(staleConnectionId, isNotNull);

    raceTransport.connectStarted = Completer<void>();
    final freshReconnect = handler!(device);
    await raceTransport.connectStarted!.future;
    final freshConnectionId = raceTransport.pendingConnectionId;
    expect(freshConnectionId, isNotNull);
    expect(freshConnectionId, isNot(staleConnectionId));
    raceTransport.emitPendingConnectDone(connectionId: freshConnectionId);
    await freshReconnect;
    expect(raceAdapter.snapshot.connectionId, freshConnectionId);
    expect(raceAdapter.snapshot.connectionGeneration, 8);

    raceTransport.failPendingConnect(
      staleConnectionId!,
      StateError('stale serialized attempt failed'),
    );
    await staleObserved;

    expect(raceAdapter.snapshot.connectionId, freshConnectionId);
    expect(raceAdapter.snapshot.connectionGeneration, 8);
    expect(
      raceAdapter.snapshot.message,
      isNot(contains('stale serialized attempt failed')),
    );
  });

  test('commands execute serially in invocation order', () async {
    final gate = Completer<void>();
    transport.scanGate = gate;

    final scan = adapter.startScan();
    final refresh = adapter.refreshPairedDevices();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(transport.calls, ['scan.start']);

    gate.complete();
    await Future.wait([scan, refresh]);
    expect(transport.calls, ['scan.start', 'paired.list']);
  });
}

const _journalHelperSource = r'''
import json
import sys

for line in sys.stdin:
    command = json.loads(line)
    name = command['command']
    request_id = command['requestId']
    if name == 'hello':
        print(json.dumps({
            'event': 'hello.done',
            'requestId': request_id,
            'protocolVersion': 1,
            'helperSessionId': 'factory-journal-test',
        }), flush=True)
    elif name == 'disconnect':
        print(json.dumps({
            'event': 'disconnect.done',
            'requestId': request_id,
            'connectionId': command.get('connectionId'),
            'reason': 'local',
        }), flush=True)
''';

Future<List<DiagnosticEvent>> _waitForJournalEvents(
  DiagnosticJournal journal,
) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    final events = await journal.read();
    if (events.isNotEmpty) return events;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return journal.read();
}

TuiMacTransportSnapshot _nativeSnapshot({
  required bool connected,
  required String connectionId,
  required int connectionGeneration,
  required String addressKey,
  required String stage,
  required String stageCode,
  required String stageDetail,
}) =>
    TuiMacTransportSnapshot(
      helperState: TuiMacHelperState.ready,
      scanning: false,
      connected: connected,
      message: stageDetail,
      transport: 'classic-rfcomm',
      endpoint: 'rfcomm:7',
      serviceUuid: '00001101-0000-1000-8000-00805f9b34fb',
      channel: 7,
      mtu: 127,
      helperSessionId: 'fake-helper',
      sessionId: 'fake-session-$connectionId',
      connectionId: connectionId,
      connectionGeneration: connectionGeneration,
      addressKey: addressKey,
      stage: stage,
      stageCode: stageCode,
      stageDetail: stageDetail,
    );

final class _FakeMacTransport implements TuiMacBluetoothTransport {
  final _input = StreamController<Uint8List>.broadcast(sync: true);
  final _errors = StreamController<Object>.broadcast(sync: true);
  final _discoveries =
      StreamController<TuiTransportDevice>.broadcast(sync: true);
  final _snapshots =
      StreamController<TuiMacTransportSnapshot>.broadcast(sync: true);

  final List<String> calls = [];
  List<TuiTransportDevice> pairedDevices = const [];
  Completer<void>? scanGate;
  Completer<void>? connectStarted;
  bool deferConnectDone = false;
  bool resolvedDevicePaired = true;
  bool failStopScan = false;
  Completer<void>? stopScanGate;
  int _connectionCounter = 0;
  int _connectionGenerationCounter = 6;
  String? latestConnectionId;
  bool? lastDirectedExactAddress;
  final List<_PendingFakeConnect> _pendingConnects = <_PendingFakeConnect>[];
  TuiMacTransportSnapshot _snapshot = const TuiMacTransportSnapshot.stopped();

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

  void discover(TuiTransportDevice device) => _discoveries.add(device);
  String? get pendingConnectionId =>
      _pendingConnects.isEmpty ? null : _pendingConnects.last.connectionId;

  void emitSnapshot(TuiMacTransportSnapshot snapshot) {
    _snapshot = snapshot;
    _snapshots.add(_snapshot);
  }

  void emitPendingConnectDone({String? connectionId}) {
    final pending = _pendingFor(connectionId);
    if (pending == null) {
      throw StateError('no pending fake connection');
    }
    latestConnectionId = pending.connectionId;
    emitSnapshot(
      _nativeSnapshot(
        connected: true,
        connectionId: pending.connectionId,
        connectionGeneration: ++_connectionGenerationCounter,
        addressKey: pending.device.addressKey,
        stage: 'connect.done',
        stageCode: 'connected',
        stageDetail: 'RFCOMM 已连接。',
      ),
    );
    if (!pending.done.isCompleted) pending.done.complete();
  }

  void failPendingConnect(String connectionId, Object error) {
    final pending = _pendingFor(connectionId);
    if (pending == null) throw StateError('no pending fake connection');
    if (!pending.done.isCompleted) pending.done.completeError(error);
  }

  _PendingFakeConnect? _pendingFor(String? connectionId) {
    if (_pendingConnects.isEmpty) return null;
    if (connectionId == null) return _pendingConnects.last;
    for (final pending in _pendingConnects.reversed) {
      if (pending.connectionId == connectionId) return pending;
    }
    return null;
  }

  void _update({
    TuiMacHelperState? helperState,
    bool? scanning,
    bool? connected,
    String? connectionId,
    int? connectionGeneration,
  }) {
    _snapshot = TuiMacTransportSnapshot(
      helperState: helperState ?? _snapshot.helperState,
      scanning: scanning ?? _snapshot.scanning,
      connected: connected ?? _snapshot.connected,
      connectionId: connectionId ?? _snapshot.connectionId,
      connectionGeneration:
          connectionGeneration ?? _snapshot.connectionGeneration,
    );
    _snapshots.add(_snapshot);
  }

  @override
  Future<void> start() async {
    calls.add('start');
    _update(helperState: TuiMacHelperState.ready);
  }

  @override
  Future<List<TuiTransportDevice>> listPairedDevices() async {
    calls.add('paired.list');
    return pairedDevices;
  }

  @override
  Future<void> startScan({
    Duration duration = const Duration(seconds: 10),
  }) async {
    calls.add('scan.start');
    await scanGate?.future;
    _update(scanning: true);
  }

  @override
  Future<void> stopScan() async {
    calls.add('scan.stop');
    if (failStopScan) throw StateError('scan stop failed');
    await stopScanGate?.future;
    _update(scanning: false);
  }

  @override
  Future<TuiIdentityResolutionResult> resolveIdentity(
          TuiIdentityCandidate candidate) async =>
      (() {
        lastDirectedExactAddress = candidate.directedExactAddress;
        return TuiIdentityResolutionResult(
          candidateId: candidate.candidateId,
          resolution: TuiIdentityResolution.directClassic,
          identityState: TuiIdentityState.confirmed,
          device: TuiTransportDevice(
            address: candidate.address!,
            name: candidate.advertisedName,
            paired: resolvedDevicePaired,
            source: TuiTransportDeviceSource.paired,
          ),
          generation: 1,
        );
      })();
  @override
  Future<TuiPairingResult> startPairing(TuiIdentityCandidate candidate) async {
    calls.add('pair.start');
    return TuiPairingResult(
      pairingId: 'pairing-test',
      candidateId: candidate.candidateId,
      identityState: TuiIdentityState.provisional,
      device: TuiTransportDevice(
        address: candidate.address!,
        name: candidate.advertisedName,
        paired: true,
        source: TuiTransportDeviceSource.paired,
      ),
      generation: 2,
    );
  }

  @override
  Future<void> cancelPairing({String? pairingId}) async {}
  @override
  Future<TuiIdentityResolutionResult> confirmIdentity(
          TuiIdentityConfirmation confirmation) async =>
      TuiIdentityResolutionResult(
          candidateId: confirmation.candidateId,
          resolution: TuiIdentityResolution.confirmed,
          identityState: TuiIdentityState.confirmed,
          generation: _snapshot.connectionGeneration);
  @override
  Future<TuiIdentityForgetResult> forgetIdentity(String candidateId) async =>
      TuiIdentityForgetResult(
          candidateId: candidateId,
          forgotten: true,
          unpaired: false,
          disconnected: false);

  @override
  Future<void> connect(
    TuiTransportDevice device, {
    String serviceUuid = '00001101-0000-1000-8000-00805f9b34fb',
  }) async {
    calls.add('connect:' + device.address);
    final pending = _PendingFakeConnect(
      connectionId: 'fake-connection-${++_connectionCounter}',
      device: device,
    );
    _pendingConnects.add(pending);
    final started = connectStarted;
    if (started != null && !started.isCompleted) started.complete();
    if (!deferConnectDone) emitPendingConnectDone();
    await pending.done.future;
    _pendingConnects.remove(pending);
  }

  @override
  Future<void> write(List<int> bytes) async {
    calls.add('write:' + bytes.length.toString());
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    _update(connected: false);
  }

  @override
  Future<void> dispose() async {
    _update(helperState: TuiMacHelperState.disposed);
    await _input.close();
    await _errors.close();
    await _discoveries.close();
    await _snapshots.close();
  }
}

final class _PendingFakeConnect {
  _PendingFakeConnect({
    required this.connectionId,
    required this.device,
  });

  final String connectionId;
  final TuiTransportDevice device;
  final Completer<void> done = Completer<void>();
}

final class _CapturingProtocolBackend extends TuiProtocolBackend {
  _CapturingProtocolBackend(TuiMacBluetoothTransport transport)
      : super(transport: transport);

  TuiPostAuthReconnect? reconnectHandler;

  @override
  void setPostAuthReconnectHandler(TuiPostAuthReconnect? handler) {
    reconnectHandler = handler;
    super.setPostAuthReconnectHandler(handler);
  }
}

final class _BindingCapturingProtocolBackend extends TuiProtocolBackend {
  _BindingCapturingProtocolBackend(TuiMacBluetoothTransport transport)
      : _testTransport = transport,
        super(transport: transport);

  final TuiMacBluetoothTransport _testTransport;
  TuiBackendBindingMaterial? bindingMaterial;
  TuiTransportDevice? connectedDevice;

  @override
  Future<void> connect(
    TuiTransportDevice device, {
    DeviceProfile? profile,
    required TuiBackendBindingMaterial? bindingMaterial,
  }) async {
    connectedDevice = device;
    this.bindingMaterial = bindingMaterial;
    await _testTransport.connect(device);
  }
}

/// Keeps the adapter race test at the native-attempt boundary.  The production
/// protocol core is separately covered by its handshake tests.
final class _TransportOnlyProtocolBackend extends TuiProtocolBackend {
  _TransportOnlyProtocolBackend(TuiMacBluetoothTransport transport)
      : _testTransport = transport,
        super(transport: transport);

  final TuiMacBluetoothTransport _testTransport;
  TuiPostAuthReconnect? reconnectHandler;

  @override
  Future<void> connect(
    TuiTransportDevice device, {
    DeviceProfile? profile,
    required TuiBackendBindingMaterial? bindingMaterial,
  }) =>
      _testTransport.connect(device);

  @override
  void setPostAuthReconnectHandler(TuiPostAuthReconnect? handler) {
    reconnectHandler = handler;
    super.setPostAuthReconnectHandler(handler);
  }
}
