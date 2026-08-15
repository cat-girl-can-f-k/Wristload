import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wristload_tui/src/backend_next/macos_tui_backend_adapter.dart';
import 'package:wristload_tui/src/backend_next/tui_mac_bluetooth_transport.dart';
import 'package:wristload_tui/src/backend_next/tui_protocol_backend.dart';
import 'package:wristload_tui/src/backend_next/tui_backend_port.dart';
import 'package:wristload_tui/src/domain/device_profile.dart';

void main() {
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
    );

    expect(transport.calls, [
      'disconnect',
      'connect:12-34-56-78-9A-BC',
      startsWith('write:'),
    ]);
    expect(transport.calls, isNot(contains('scan.start')));
    expect(adapter.snapshot.activeDeviceAddress, '12-34-56-78-9A-BC');
    expect(adapter.snapshot.authKeyLoaded, isTrue);
    expect(
      adapter.snapshot.connection,
      TuiBackendConnectionState.authenticating,
    );
    expect(adapter.snapshot.message, isNot(contains(key)));
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
  TuiMacTransportSnapshot _snapshot = const TuiMacTransportSnapshot.stopped();

  @override
  Stream<Uint8List> get input => _input.stream;
  @override
  Stream<Object> get errors => _errors.stream;
  @override
  Stream<TuiTransportDevice> get discoveries => _discoveries.stream;
  @override
  Stream<TuiMacTransportSnapshot> get snapshots => _snapshots.stream;
  @override
  TuiMacTransportSnapshot get snapshot => _snapshot;

  void discover(TuiTransportDevice device) => _discoveries.add(device);

  void _update({
    TuiMacHelperState? helperState,
    bool? scanning,
    bool? connected,
  }) {
    _snapshot = TuiMacTransportSnapshot(
      helperState: helperState ?? _snapshot.helperState,
      scanning: scanning ?? _snapshot.scanning,
      connected: connected ?? _snapshot.connected,
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
    _update(scanning: false);
  }

  @override
  Future<void> connect(
    TuiTransportDevice device, {
    String serviceUuid = '00001101-0000-1000-8000-00805f9b34fb',
  }) async {
    calls.add('connect:' + device.address);
    _update(connected: true);
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
