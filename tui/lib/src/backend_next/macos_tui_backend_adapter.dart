/// TUI-only composition of the macOS JSONL Bluetooth helper and protocol core.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../domain/device_profile.dart';
import '../domain/install_checkpoint_store.dart';
import '../domain/install_models.dart';
import '../domain/install_task.dart';
import '../domain/transfer_settings_store.dart';
import '../diagnostics/diagnostic_journal.dart';
import 'tui_json_line_transport.dart';
import 'tui_mac_bluetooth_transport.dart';
import 'tui_protocol_backend.dart';
import 'tui_protocol_snapshot.dart';
import 'tui_backend_port.dart';

TuiMacTransportSnapshot _withoutNativeTuple(TuiMacTransportSnapshot value) =>
    value.copyWith(
      connected: false,
      transport: null,
      endpoint: null,
      serviceUuid: null,
      channel: null,
      mtu: null,
      sessionId: null,
      connectionId: null,
      connectionGeneration: null,
      addressKey: null,
      stage: null,
      stageCode: null,
      stageDetail: null,
    );

final class MacOsTuiBackendAdapter implements TuiBackendPort {
  factory MacOsTuiBackendAdapter({
    required String helperPath,
    InstallCheckpointStore? checkpointStore,
    TransferSettingsStore? settingsStore,
    DiagnosticJournal? diagnosticJournal,
    MacBridgeProcessStarter? processStarter,
  }) {
    final journal = diagnosticJournal ?? _defaultDiagnosticJournal();
    final transport = TuiJsonLineMacBluetoothTransport(
      executablePath: helperPath,
      diagnosticJournal: journal,
      processStarter: processStarter,
    );
    return MacOsTuiBackendAdapter.withDependencies(
      transport: transport,
      backend: TuiProtocolBackend(
        transport: transport,
        checkpointStore: checkpointStore,
        settingsStore: settingsStore,
        diagnosticJournal: journal,
      ),
    );
  }

  /// The production TUI and `wristload_logs --follow` share this append-only
  /// file.  Keep the journal owned by the standalone TUI backend; no GUI
  /// runtime or service is involved in creating it.
  static DiagnosticJournal _defaultDiagnosticJournal() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError(
          'HOME is unavailable; cannot create the TUI diagnostic journal.');
    }
    return DiagnosticJournal(
      File('$home/Library/Application Support/WristloadTui/diagnostics.jsonl'),
    );
  }

  MacOsTuiBackendAdapter.withDependencies({
    required TuiMacBluetoothTransport transport,
    required TuiProtocolBackend backend,
  })  : _transport = transport,
        _backend = backend,
        // A transport may be reused by a caller that still has a retired
        // RFCOMM snapshot.  The adapter has no provenance for that tuple at
        // construction time, so never publish it as an owned TUI session.
        _transportSnapshot = _withoutNativeTuple(transport.snapshot),
        _backendSnapshot = backend.snapshot {
    // Protocol recovery after f=27 must obtain a fresh RFCOMM tuple through
    // this adapter-owned attempt boundary.  Do not let the protocol core
    // call connectByAddress recursively: that would reset application
    // identity state and could admit a stale same-MAC tuple.
    backend.setPostAuthReconnectHandler(_postAuthReconnect);
    _transportSubscription = transport.snapshots
        .listen(_observeTransportSnapshot, onError: _recordError);
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
  String? _identityCandidateId;
  String? _identityName;
  String? _identityAddress;
  TuiIdentityState _identityState = TuiIdentityState.unresolved;
  int? _identityGeneration;
  int? _attemptGeneration;
  String? _confirmedConnectionId;
  _NativeConnectionAttempt? _nativeAttempt;
  int? _acceptedNativeAttemptToken;
  _NativeConnectionTuple? _ownedNativeTuple;
  // A tuple remains attributed to its accepting attempt after the synchronous
  // connect callback has cleared [_nativeAttempt].  Later failures from a
  // retired async attempt must never clear a newer tuple.
  int? _ownedNativeAttemptToken;
  final Map<int, int> _serializedOperationAttemptTokens = <int, int>{};
  int _nativeAttemptToken = 0;
  int _serializedOperationToken = 0;
  int _revision = 0;
  bool _disposed = false;

  static final Object _serializedOperationZoneKey = Object();

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
    bool requireConfirmedIdentity = false,
    bool directedExactAddress = false,
    int? attemptGeneration,
    required TuiBackendBindingMaterial? bindingMaterial,
  }) =>
      _serialize(() async {
        final bluetoothAddress = TuiBluetoothAddress.parse(address);
        final normalizedName =
            name.trim().isEmpty ? bluetoothAddress.display : name.trim();
        final existing = _devices[bluetoothAddress.key];
        final resolvedProfile = profile ??
            existing?.profile ??
            DeviceProfile.matchAdvertisementName(normalizedName);
        final candidateId = 'classic:${bluetoothAddress.key}';
        final candidate = TuiIdentityCandidate(
          candidateId: candidateId,
          advertisedName: normalizedName,
          address: bluetoothAddress.display,
          directedExactAddress: directedExactAddress,
        );
        _identityCandidateId = candidateId;
        _identityName = normalizedName;
        _identityAddress = bluetoothAddress.display;
        _attemptGeneration = attemptGeneration;
        _confirmedConnectionId = null;
        final attemptToken = ++_nativeAttemptToken;
        _nativeAttempt = _NativeConnectionAttempt(
          token: attemptToken,
          applicationGeneration: attemptGeneration,
          addressKey: bluetoothAddress.key,
          previous: _nativeTupleFrom(_transport.snapshot),
        );
        _acceptedNativeAttemptToken = null;
        _ownedNativeTuple = null;
        _ownedNativeAttemptToken = null;
        _transportSnapshot = _withoutNativeTuple(_transport.snapshot);
        final operationToken =
            Zone.current[_serializedOperationZoneKey] as int?;
        if (operationToken != null) {
          _serializedOperationAttemptTokens[operationToken] = attemptToken;
        }
        _publish();
        final resolved = await _transport.resolveIdentity(candidate);
        if (resolved.candidateId != candidateId ||
            _attemptGeneration != attemptGeneration ||
            _nativeAttempt?.token != attemptToken) {
          throw StateError('identity.resolve 已被新的连接世代取代。');
        }
        _identityState = resolved.identityState;
        _identityGeneration = resolved.generation;
        var device = resolved.device;
        if (requireConfirmedIdentity &&
            resolved.identityState != TuiIdentityState.confirmed) {
          throw StateError('自动连接只允许已确认的 Classic identity。');
        }
        if (device == null || !device.paired) {
          // IOBluetooth inquiry must reach its terminal callback before the
          // directed pairing request starts. This operation already owns the
          // adapter's serialized queue, so await the transport directly.
          if (_transport.snapshot.scanning) {
            await _transport.stopScan();
          }
          final paired = await _transport.startPairing(candidate);
          if (paired.candidateId != candidateId ||
              _attemptGeneration != attemptGeneration ||
              _nativeAttempt?.token != attemptToken) {
            throw StateError('pair.start 已被新的连接世代取代。');
          }
          device = paired.device;
          _identityState = paired.identityState;
          _identityGeneration = paired.generation;
        }
        if (device.addressKey != bluetoothAddress.key) {
          throw StateError('解析到的 Classic identity 与选中设备不匹配。');
        }
        _mergeDevice(device, profile: resolvedProfile);

        // Saved-device reconnect never starts inquiry. An explicitly active
        // inquiry on an already-paired identity is stopped before SDP/RFCOMM
        // so native work stays ordered.
        if (_transport.snapshot.scanning) await _transport.stopScan();
        // The protocol backend owns this immutable material for the whole
        // logical session, including its adapter-owned post-f=27 RFCOMM
        // recovery.  The adapter must not derive, replace, or log it.
        await _backend.connect(
          device,
          profile: resolvedProfile,
          bindingMaterial: bindingMaterial,
        );
        if (_attemptGeneration != attemptGeneration ||
            (_nativeAttempt?.token != attemptToken &&
                _acceptedNativeAttemptToken != attemptToken)) {
          throw StateError('connect 已被新的连接世代取代。');
        }
        _requireNativeConnectionGeneration();
        if (_acceptedNativeAttemptToken == attemptToken) {
          _acceptedNativeAttemptToken = null;
        }
      });

  Future<void> _postAuthReconnect(TuiTransportDevice device) async {
    _ensureLive();
    final addressKey = device.addressKey;
    final previous = _ownedNativeTuple ?? _nativeTupleFrom(_transport.snapshot);
    final attemptToken = ++_nativeAttemptToken;
    final attempt = _NativeConnectionAttempt(
      token: attemptToken,
      applicationGeneration: _attemptGeneration,
      addressKey: addressKey,
      previous: previous,
    );
    _nativeAttempt = attempt;
    _acceptedNativeAttemptToken = null;
    _ownedNativeTuple = null;
    _ownedNativeAttemptToken = null;
    _transportSnapshot = _withoutNativeTuple(_transport.snapshot);
    _publish();

    try {
      await _transport.connect(device);
      // TuiMacBluetoothTransport.connect completes only after connect.done
      // (or rfcomm.open.completed) has been observed.  The snapshot listener
      // may have run synchronously and cleared _nativeAttempt while recording
      // the accepted token, so accept either provenance form here.
      final accepted = _acceptedNativeAttemptToken == attemptToken ||
          _nativeAttempt?.token == attemptToken;
      if (!accepted ||
          _attemptGeneration != attempt.applicationGeneration ||
          _ownedNativeTuple == null ||
          !_tupleMatches(
            _ownedNativeTuple!,
            _nativeTupleFrom(_transport.snapshot),
          )) {
        throw StateError(
            'post-auth RFCOMM reconnect 未获得当前 attempt 的 native tuple。');
      }
      if (_acceptedNativeAttemptToken == attemptToken) {
        _acceptedNativeAttemptToken = null;
      }
      if (_nativeAttempt?.token == attemptToken) {
        _nativeAttempt = null;
      }
      _publish();
    } on Object catch (error) {
      // Recovery is invoked outside the adapter command queue.  Preserve the
      // detailed error for the TUI only when this attempt still owns native
      // state.  A late failure from a retired post-auth reconnect must not
      // erase or report over the newer attempt that replaced it.
      if (_retireNativeAttemptIfOwned(attemptToken)) {
        _adapterMessage = error.toString();
        _adapterFailureCode = _errorCode(error);
        _publish();
      }
      rethrow;
    }
  }

  @override
  Future<void> confirmActiveIdentity({required int attemptGeneration}) =>
      _serialize(() async {
        if (_attemptGeneration != attemptGeneration ||
            _identityCandidateId == null ||
            _identityName == null ||
            _identityAddress == null) {
          throw StateError('identity.confirm 的 application generation 已过期。');
        }
        if (_backend.snapshot.connection != TuiProtocolConnectionState.ready) {
          throw StateError('identity.confirm 只能在 f=27 ready 后执行。');
        }
        final nativeTuple = _requireNativeTuple();
        final connectionId = nativeTuple.connectionId;
        final nativeGeneration = _requireNativeConnectionGeneration();
        final result = await _transport.confirmIdentity(
          TuiIdentityConfirmation(
            candidateId: _identityCandidateId!,
            advertisedName: _identityName!,
            address: _identityAddress!,
            connectionId: connectionId,
            generation: nativeGeneration,
          ),
        );
        if (result.candidateId != _identityCandidateId ||
            result.identityState != TuiIdentityState.confirmed ||
            result.generation != nativeGeneration ||
            _transport.snapshot.connectionId != connectionId ||
            _transport.snapshot.connectionGeneration != nativeGeneration) {
          throw StateError('identity.confirm 返回了过期或不匹配的身份。');
        }
        _identityState = TuiIdentityState.confirmed;
        _identityGeneration = result.generation;
        _confirmedConnectionId = connectionId;
        _publish();
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
    _nativeAttempt = null;
    _acceptedNativeAttemptToken = null;
    _ownedNativeTuple = null;
    _ownedNativeAttemptToken = null;
    _transportSnapshot = _withoutNativeTuple(_transport.snapshot);
    _confirmedConnectionId = null;
    _publish();
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

  Future<void> _runOperation(Future<void> Function() operation) {
    final operationToken = ++_serializedOperationToken;
    return runZoned<Future<void>>(
      () async {
        _adapterFailureCode = null;
        try {
          await operation();
        } on Object catch (error) {
          final operationAttemptToken =
              _serializedOperationAttemptTokens[operationToken];
          // Only connectByAddress creates an adapter-native attempt while it
          // runs through this serialized queue.  It records that token above.
          // If a later post-auth reconnect or another explicit connect has
          // replaced it, this failure is stale and must not clear or report
          // over the newer tuple.
          if (operationAttemptToken != null &&
              !_retireNativeAttemptIfOwned(operationAttemptToken)) {
            // Do not mutate adapter diagnostics or tuple ownership for an
            // operation whose native attempt has already been replaced.
            _synchronizeSnapshots();
            _publish();
            rethrow;
          }
          _adapterMessage = error.toString();
          _adapterFailureCode = _errorCode(error);
          _synchronizeSnapshots();
          _publish();
          rethrow;
        } finally {
          _serializedOperationAttemptTokens.remove(operationToken);
        }
        _adapterMessage = null;
        _synchronizeSnapshots();
        _publish();
      },
      zoneValues: <Object?, Object?>{
        _serializedOperationZoneKey: operationToken,
      },
    );
  }

  void _synchronizeSnapshots() {
    _adoptTransportSnapshot(_transport.snapshot);
    _backendSnapshot = _backend.snapshot;
    final active = _backendSnapshot.device;
    if (active != null) {
      _mergeDevice(active, profile: _backendSnapshot.profile, publish: false);
    }
  }

  void _observeTransportSnapshot(TuiMacTransportSnapshot value) {
    _adoptTransportSnapshot(value);
    _publish();
  }

  void _adoptTransportSnapshot(TuiMacTransportSnapshot value) {
    final candidate = _nativeTupleFrom(value);
    final attempt = _nativeAttempt;
    if (attempt != null && _ownedNativeTuple == null) {
      if (_isAdmissibleNativeTuple(value, candidate, attempt)) {
        _ownedNativeTuple = candidate;
        _ownedNativeAttemptToken = attempt.token;
        // Keep provenance after the synchronous snapshot callback clears the
        // pending attempt.  connectByAddress must distinguish this accepted
        // tuple from a genuinely superseded attempt after await connect.
        _acceptedNativeAttemptToken = attempt.token;
        _nativeAttempt = null;
        _transportSnapshot = value;
        return;
      }
      _transportSnapshot = _withoutNativeTuple(value);
      return;
    }
    final owned = _ownedNativeTuple;
    if (owned != null && _tupleMatches(owned, candidate)) {
      _transportSnapshot = value;
      return;
    }
    _transportSnapshot = _withoutNativeTuple(value);
  }

  bool _isAdmissibleNativeTuple(
    TuiMacTransportSnapshot value,
    _NativeConnectionTuple? candidate,
    _NativeConnectionAttempt attempt,
  ) {
    if (!value.connected ||
        candidate == null ||
        candidate.connectionGeneration <= 0 ||
        candidate.addressKey != attempt.addressKey) {
      return false;
    }
    final previous = attempt.previous;
    if (previous != null &&
        (previous.connectionId == candidate.connectionId ||
            candidate.connectionGeneration <= previous.connectionGeneration)) {
      return false;
    }
    final stage = value.stage;
    if (stage != null &&
        stage != 'connect.done' &&
        stage != 'rfcomm.open.completed') {
      return false;
    }
    return true;
  }

  bool _nativeAttemptTokenOwnsState(int token) =>
      _nativeAttempt?.token == token ||
      _acceptedNativeAttemptToken == token ||
      _ownedNativeAttemptToken == token;

  /// Retires only state still owned by [token].  Returning false means a
  /// newer attempt has replaced it and must remain untouched.
  bool _retireNativeAttemptIfOwned(int token) {
    if (!_nativeAttemptTokenOwnsState(token)) return false;
    if (_nativeAttempt?.token == token) _nativeAttempt = null;
    if (_acceptedNativeAttemptToken == token) {
      _acceptedNativeAttemptToken = null;
    }
    if (_ownedNativeAttemptToken == token) {
      _ownedNativeTuple = null;
      _ownedNativeAttemptToken = null;
    }
    _transportSnapshot = _withoutNativeTuple(_transport.snapshot);
    return true;
  }

  _NativeConnectionTuple? _nativeTupleFrom(TuiMacTransportSnapshot value) {
    final id = value.connectionId;
    final generation = value.connectionGeneration;
    final addressKey = value.addressKey;
    if (id == null || generation == null || addressKey == null) return null;
    return _NativeConnectionTuple(
      connectionId: id,
      connectionGeneration: generation,
      addressKey: addressKey,
    );
  }

  bool _tupleMatches(
    _NativeConnectionTuple expected,
    _NativeConnectionTuple? actual,
  ) =>
      actual != null &&
      actual.connectionId == expected.connectionId &&
      actual.connectionGeneration == expected.connectionGeneration &&
      actual.addressKey == expected.addressKey;

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
      identityCandidateId: _identityCandidateId,
      identityState: switch (_identityState) {
        TuiIdentityState.unresolved => TuiBackendIdentityState.unresolved,
        TuiIdentityState.provisional => TuiBackendIdentityState.provisional,
        TuiIdentityState.confirmed => TuiBackendIdentityState.confirmed,
      },
      identityGeneration: _identityGeneration,
      connectionId:
          _ownedNativeTuple == null ? null : _transportSnapshot.connectionId,
      connectionGeneration: _ownedNativeTuple == null
          ? null
          : _transportSnapshot.connectionGeneration,
      applicationAttemptGeneration: _attemptGeneration,
      protocolAuthenticated:
          _backendSnapshot.connection == TuiProtocolConnectionState.ready,
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
        TuiProtocolConnectionState.ready => _ownedNativeTuple != null &&
                _identityState == TuiIdentityState.confirmed &&
                _confirmedConnectionId == _transportSnapshot.connectionId
            ? TuiBackendConnectionState.ready
            : TuiBackendConnectionState.authenticating,
      };

  int _requireNativeConnectionGeneration() {
    final tuple = _requireNativeTuple();
    return tuple.connectionGeneration;
  }

  _NativeConnectionTuple _requireNativeTuple() {
    _adoptTransportSnapshot(_transport.snapshot);
    final tuple = _ownedNativeTuple;
    if (tuple == null ||
        !_tupleMatches(tuple, _nativeTupleFrom(_transport.snapshot))) {
      throw StateError('当前 RFCOMM connection 缺少本次 attempt 的 native tuple。');
    }
    return tuple;
  }

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

final class _NativeConnectionAttempt {
  const _NativeConnectionAttempt({
    required this.token,
    required this.applicationGeneration,
    required this.addressKey,
    required this.previous,
  });

  final int token;
  final int? applicationGeneration;
  final String addressKey;
  final _NativeConnectionTuple? previous;
}

final class _NativeConnectionTuple {
  const _NativeConnectionTuple({
    required this.connectionId,
    required this.connectionGeneration,
    required this.addressKey,
  });

  final String connectionId;
  final int connectionGeneration;
  final String addressKey;
}
