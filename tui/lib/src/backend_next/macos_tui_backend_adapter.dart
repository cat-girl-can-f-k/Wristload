/// TUI-only composition of the macOS JSONL Bluetooth helper and protocol core.
library;

import 'dart:async';
import 'dart:collection';

import '../domain/device_profile.dart';
import '../domain/install_checkpoint_store.dart';
import '../domain/install_models.dart';
import '../domain/install_task.dart';
import '../domain/transfer_settings_store.dart';
import 'tui_json_line_transport.dart';
import 'tui_mac_bluetooth_transport.dart';
import 'tui_protocol_backend.dart';
import 'tui_protocol_snapshot.dart';
import 'tui_backend_port.dart';

final class MacOsTuiBackendAdapter implements TuiBackendPort {
  factory MacOsTuiBackendAdapter({
    required String helperPath,
    InstallCheckpointStore? checkpointStore,
    TransferSettingsStore? settingsStore,
  }) {
    final transport =
        TuiJsonLineMacBluetoothTransport(executablePath: helperPath);
    return MacOsTuiBackendAdapter.withDependencies(
      transport: transport,
      backend: TuiProtocolBackend(
        transport: transport,
        checkpointStore: checkpointStore,
        settingsStore: settingsStore,
      ),
    );
  }

  MacOsTuiBackendAdapter.withDependencies({
    required TuiMacBluetoothTransport transport,
    required TuiProtocolBackend backend,
  })  : _transport = transport,
        _backend = backend,
        _transportSnapshot = transport.snapshot,
        _backendSnapshot = backend.snapshot {
    _transportSubscription = transport.snapshots.listen((value) {
      _transportSnapshot = value;
      _publish();
    }, onError: _recordError);
    _discoverySubscription =
        transport.discoveries.listen(_mergeDevice, onError: _recordError);
    _backendSubscription = backend.snapshots.listen((value) {
      _backendSnapshot = value;
      final active = value.device;
      if (active != null) _mergeDevice(active, profile: value.profile);
      _publish();
    }, onError: _recordError);
  }

  final TuiMacBluetoothTransport _transport;
  final TuiProtocolBackend _backend;
  final Map<String, _ObservedDevice> _devices = {};
  final StreamController<TuiBackendSnapshot> _snapshotController =
      StreamController<TuiBackendSnapshot>.broadcast(sync: true);

  late TuiMacTransportSnapshot _transportSnapshot;
  late TuiProtocolSnapshot _backendSnapshot;
  StreamSubscription<TuiMacTransportSnapshot>? _transportSubscription;
  StreamSubscription<TuiTransportDevice>? _discoverySubscription;
  StreamSubscription<TuiProtocolSnapshot>? _backendSubscription;
  Future<void> _commandTail = Future<void>.value();
  String? _adapterMessage;
  String? _adapterFailureCode;
  int _revision = 0;
  bool _disposed = false;

  @override
  TuiBackendSnapshot get snapshot => _makeSnapshot();

  @override
  Stream<TuiBackendSnapshot> get snapshots async* {
    yield snapshot;
    yield* _snapshotController.stream;
  }

  @override
  Future<void> initialize() => _serialize(() async {
        await _transport.start();
        // Startup must establish only the native helper. Fetching the system
        // paired-device list can block on IOBluetooth and must remain an
        // explicit user action, so saved-device history is usable first.
      });

  @override
  Future<void> refreshPairedDevices() => _serialize(_refreshPairedDevicesNow);

  Future<void> _refreshPairedDevicesNow() async {
    for (final device in await _transport.listPairedDevices()) {
      _mergeDevice(device);
    }
  }

  @override
  Future<void> startScan({
    Duration duration = const Duration(seconds: 10),
  }) =>
      _serialize(() => _transport.startScan(duration: duration));

  @override
  Future<void> stopScan() => _serialize(_transport.stopScan);

  @override
  Future<void> connectByAddress({
    required String address,
    required String name,
    DeviceProfile? profile,
  }) =>
      _serialize(() async {
        final bluetoothAddress = TuiBluetoothAddress.parse(address);
        final normalizedName =
            name.trim().isEmpty ? bluetoothAddress.display : name.trim();
        final existing = _devices[bluetoothAddress.key];
        final resolvedProfile = profile ??
            existing?.profile ??
            DeviceProfile.matchAdvertisementName(normalizedName);
        final device = TuiTransportDevice.fromAddress(
          bluetoothAddress: bluetoothAddress,
          name: normalizedName,
          paired: existing?.device.paired ?? false,
          source: TuiTransportDeviceSource.manual,
        );
        _mergeDevice(device, profile: resolvedProfile);

        // Saved-device reconnect never starts inquiry. An explicitly active
        // inquiry is stopped before SDP/RFCOMM so native work stays ordered.
        if (_transport.snapshot.scanning) await _transport.stopScan();
        await _backend.connect(device, profile: resolvedProfile);
      });

  @override
  Future<void> provideAuthKey(String authKey) => _serialize(() async {
        _backend.setAuthKey(authKey);
      });

  @override
  Future<void> clearAuthKey() => _serialize(_backend.clearAuthKey);

  @override
  Future<void> disconnect() async {
    _ensureLive();
    // Cancellation only completes the protocol core's local signal. The
    // serialized install operation remains responsible for finishing before
    // the queued transport disconnect starts.
    await _backend.cancelInstall();
    await _serialize(_backend.disconnect);
  }

  @override
  Future<void> install(InstallRequest request) =>
      _serialize(() => _backend.startInstall(request));

  @override
  Future<void> cancelInstall() async {
    _ensureLive();
    // Do not queue cancellation behind the long-running install it must stop.
    // This method emits no Bluetooth bytes; transport I/O remains serialized.
    await _backend.cancelInstall();
    _synchronizeSnapshots();
    _publish();
  }

  void _ensureLive() {
    if (_disposed) throw StateError('TUI backend 已释放。');
  }

  Future<void> _serialize(Future<void> Function() operation) {
    if (_disposed) return Future<void>.error(StateError('TUI backend 已释放。'));
    final result = _commandTail.then<void>(
      (_) => _runOperation(operation),
      onError: (_) => _runOperation(operation),
    );
    _commandTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _runOperation(Future<void> Function() operation) async {
    _adapterFailureCode = null;
    try {
      await operation();
    } on Object catch (error) {
      _adapterMessage = error.toString();
      _adapterFailureCode = _errorCode(error);
      _synchronizeSnapshots();
      _publish();
      rethrow;
    }
    _adapterMessage = null;
    _synchronizeSnapshots();
    _publish();
  }

  void _synchronizeSnapshots() {
    _transportSnapshot = _transport.snapshot;
    _backendSnapshot = _backend.snapshot;
    final active = _backendSnapshot.device;
    if (active != null) {
      _mergeDevice(active, profile: _backendSnapshot.profile, publish: false);
    }
  }

  void _mergeDevice(
    TuiTransportDevice device, {
    DeviceProfile? profile,
    bool publish = true,
  }) {
    final previous = _devices[device.addressKey];
    final merged = previous == null ? device : previous.device.merge(device);
    _devices[device.addressKey] = _ObservedDevice(
      device: merged,
      profile: profile ??
          previous?.profile ??
          DeviceProfile.matchAdvertisementName(merged.name),
      sources: {...?previous?.sources, device.source},
    );
    if (publish) _publish();
  }

  void _recordError(Object error, [StackTrace? stack]) {
    _adapterMessage = error.toString();
    _adapterFailureCode = _errorCode(error);
    _publish();
  }

  String _errorCode(Object error) => switch (error) {
        FormatException _ => 'invalid_input',
        UnsupportedError _ => 'unsupported_platform',
        TuiNativeTransportException value => value.code,
        TuiTransportProtocolException _ => 'helper_protocol',
        StateError _ => 'invalid_state',
        _ => 'backend_error',
      };

  void _publish() {
    if (_disposed || _snapshotController.isClosed) return;
    _revision++;
    _snapshotController.add(_makeSnapshot());
  }

  TuiBackendSnapshot _makeSnapshot() {
    final devices = _devices.values.map(_mapDevice).toList()
      ..sort((left, right) {
        final byName =
            left.name.toLowerCase().compareTo(right.name.toLowerCase());
        return byName != 0
            ? byName
            : left.addressKey.compareTo(right.addressKey);
      });
    return TuiBackendSnapshot(
      revision: _revision,
      helperState: _mapHelperState(_transportSnapshot.helperState),
      scanning: _transportSnapshot.scanning,
      transportConnected: _transportSnapshot.connected,
      connection: _mapConnectionState(_backendSnapshot.connection),
      devices: UnmodifiableListView(devices),
      activeDeviceAddress: _backendSnapshot.device?.address,
      message: _adapterMessage ??
          _backendSnapshot.message ??
          _transportSnapshot.message,
      failureCode: _adapterFailureCode ?? _backendSnapshot.failureCode,
      installation: _mapInstallation(_backendSnapshot.latestTask),
      authKeyLoaded: _backendSnapshot.authKeyLoaded,
    );
  }

  TuiBackendDevice _mapDevice(_ObservedDevice observed) => TuiBackendDevice(
        address: observed.device.address,
        addressKey: observed.device.addressKey,
        name: observed.device.name.trim().isEmpty
            ? observed.device.address
            : observed.device.name,
        profile: observed.profile,
        paired: observed.device.paired,
        rssi: observed.device.rssi,
        sources: UnmodifiableSetView(
          observed.sources.map(_mapDeviceSource).toSet(),
        ),
      );

  TuiBackendInstallation? _mapInstallation(InstallTask? task) {
    if (task == null) return null;
    return TuiBackendInstallation(
      state: switch (task.stage) {
        InstallStage.idle => TuiBackendInstallState.idle,
        InstallStage.validating => TuiBackendInstallState.validating,
        InstallStage.waitingForProtocol =>
          TuiBackendInstallState.waitingForProtocol,
        InstallStage.transferring => TuiBackendInstallState.transferring,
        InstallStage.awaitingDevice => TuiBackendInstallState.awaitingDevice,
        InstallStage.succeeded => TuiBackendInstallState.succeeded,
        InstallStage.cancelled => TuiBackendInstallState.cancelled,
        InstallStage.stateUnknown => TuiBackendInstallState.stateUnknown,
        InstallStage.failed => TuiBackendInstallState.failed,
      },
      fileName: task.fileName,
      message: task.message,
      confirmedBytes: task.confirmedBytes,
      queuedBytes: task.queuedBytes,
      totalBytes: task.totalBytes,
      bytesPerSecond: task.bytesPerSecond,
      successVerifiedByDeviceBusinessEvent:
          task.successVerifiedByDeviceBusinessEvent,
    );
  }

  TuiBackendHelperState _mapHelperState(TuiMacHelperState state) =>
      switch (state) {
        TuiMacHelperState.stopped => TuiBackendHelperState.stopped,
        TuiMacHelperState.starting => TuiBackendHelperState.starting,
        TuiMacHelperState.ready => TuiBackendHelperState.ready,
        TuiMacHelperState.failed => TuiBackendHelperState.failed,
        TuiMacHelperState.disposed => TuiBackendHelperState.disposed,
      };

  TuiBackendConnectionState _mapConnectionState(
          TuiProtocolConnectionState state) =>
      switch (state) {
        TuiProtocolConnectionState.disconnected =>
          TuiBackendConnectionState.disconnected,
        TuiProtocolConnectionState.connecting =>
          TuiBackendConnectionState.connecting,
        TuiProtocolConnectionState.awaitingAuthKey =>
          TuiBackendConnectionState.awaitingAuthKey,
        TuiProtocolConnectionState.authenticating =>
          TuiBackendConnectionState.authenticating,
        TuiProtocolConnectionState.ready => TuiBackendConnectionState.ready,
      };

  TuiBackendDeviceSource _mapDeviceSource(TuiTransportDeviceSource source) =>
      switch (source) {
        TuiTransportDeviceSource.inquiry => TuiBackendDeviceSource.inquiry,
        TuiTransportDeviceSource.paired => TuiBackendDeviceSource.paired,
        TuiTransportDeviceSource.manual => TuiBackendDeviceSource.manual,
      };

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    // Release a running installation before waiting for the actor tail.
    await _backend.cancelInstall();
    _disposed = true;
    await _commandTail;
    await _transportSubscription?.cancel();
    await _discoverySubscription?.cancel();
    await _backendSubscription?.cancel();
    await _backend.dispose();
    await _snapshotController.close();
  }
}

final class _ObservedDevice {
  const _ObservedDevice({
    required this.device,
    required this.profile,
    required this.sources,
  });

  final TuiTransportDevice device;
  final DeviceProfile? profile;
  final Set<TuiTransportDeviceSource> sources;
}
