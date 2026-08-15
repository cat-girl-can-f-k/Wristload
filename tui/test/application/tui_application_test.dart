import 'dart:async';

import 'package:test/test.dart';
import 'package:wristload_tui/src/application/persistence/saved_device_repository.dart';
import 'package:wristload_tui/src/application/persistence/saved_tui_device.dart';
import 'package:wristload_tui/src/application/persistence/tui_credential_store.dart';
import 'package:wristload_tui/src/application/persistence/tui_preference_store.dart';
import 'package:wristload_tui/src/application/tui_application.dart';
import 'package:wristload_tui/src/application/tui_application_snapshot.dart';
import 'package:wristload_tui/src/backend_next/tui_backend_port.dart';
import 'package:wristload_tui/src/domain/device_profile.dart';
import 'package:wristload_tui/src/domain/install_models.dart';

void main() {
  const macA = 'AA:BB:CC:DD:EE:01';
  const macB = 'AA:BB:CC:DD:EE:02';
  const authKeyA = '00112233445566778899AABBCCDDEEFF';
  const authKeyB = 'FFEEDDCCBBAA99887766554433221100';

  group('TuiApplication', () {
    late _FakeBackend backend;
    late _MemorySavedDeviceRepository devices;
    late InMemoryTuiCredentialStore credentials;
    late _MemoryPreferenceStore preferences;
    late TuiApplication application;

    setUp(() {
      backend = _FakeBackend();
      devices = _MemorySavedDeviceRepository();
      credentials = InMemoryTuiCredentialStore();
      preferences = _MemoryPreferenceStore();
      application = TuiApplication(
        backend: backend,
        savedDeviceRepository: devices,
        credentialStore: credentials,
        preferenceStore: preferences,
      );
    });

    tearDown(() => application.dispose());

    test('merges saved and live devices by MAC without losing saved metadata',
        () async {
      await devices.save(
        SavedTuiDevice(
          displayName: 'Saved Xiaomi Smart Band 10 Pro',
          macAddress: macA,
          isSupported: true,
          profileId: DeviceFamily.band10Pro.name,
        ),
      );
      await credentials.saveAuthKey(macA, authKeyA);
      backend.publishDevices([
        _device(
          address: 'aa-bb-cc-dd-ee-01',
          name: 'Temporary advertisement name',
          profile: DeviceProfile.band9,
        ),
      ]);

      await application.initialize();

      final snapshot = application.snapshot;
      expect(snapshot.devices, hasLength(1));
      final device = snapshot.devices.single;
      expect(device.id, macA);
      expect(device.name, 'Saved Xiaomi Smart Band 10 Pro');
      expect(device.profileId, DeviceFamily.band10Pro.name);
      expect(device.authKeyLabel, authKeyA);
    });

    test('auto-connect connects the latest saved MAC without scanning',
        () async {
      await _saveSupportedDevice(devices, macA,
          at: DateTime.utc(2026, 8, 15, 1));
      await _saveSupportedDevice(devices, macB,
          at: DateTime.utc(2026, 8, 15, 2));
      await credentials.saveAuthKey(macB, authKeyB);

      await application.initialize();

      expect(backend.connectCalls, hasLength(1));
      expect(backend.connectCalls.single.address, macB);
      expect(backend.startScanCalls, isZero);
      expect(backend.providedKeys, [authKeyB]);
      expect(application.snapshot.autoConnectState,
          TuiApplicationAutoConnectState.connecting);
    });

    test('auto-connect without a key awaits input without Bluetooth activity',
        () async {
      await _saveSupportedDevice(devices, macA,
          at: DateTime.utc(2026, 8, 15, 1));

      await application.initialize();

      expect(backend.connectCalls, isEmpty);
      expect(backend.providedKeys, isEmpty);
      expect(backend.clearAuthKeyCalls, isZero);
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.awaitingAuthKey);
      expect(application.snapshot.autoConnectState,
          TuiApplicationAutoConnectState.missingAuthKey);
      expect(backend.startScanCalls, isZero);
    });

    test('a missing authkey never reaches backend until it is submitted',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);

      final requested = await application.connectDevice(macA);

      expect(requested.accepted, isTrue);
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.awaitingAuthKey);
      expect(application.snapshot.activeDeviceId, macA);
      expect(backend.providedKeys, isEmpty);
      expect(backend.connectCalls, isEmpty);
      expect(backend.clearAuthKeyCalls, isZero);

      final submitted = await application.submitAuthKey(macA, authKeyA);

      expect(submitted.accepted, isTrue);
      expect(backend.providedKeys, [authKeyA]);
      expect(backend.connectCalls, hasLength(1));
      expect(backend.connectCalls.single.address, macA);
    });

    test('cancelling a pending authkey input does not touch Bluetooth',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);

      final result = await application.disconnect();

      expect(result.accepted, isTrue);
      expect(backend.disconnectCalls, isZero);
      expect(backend.providedKeys, isEmpty);
      expect(backend.connectCalls, isEmpty);
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.disconnected);
      expect(application.snapshot.activeDeviceId, isNull);
    });

    test('authkey is persisted only after the matching connection is ready',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.saveDevice(macA);
      await application.connectDevice(macA);

      await application.submitAuthKey(macA, authKeyA);
      expect(await credentials.readAuthKey(macA), isNull);

      backend.publishConnection(
        TuiBackendConnectionState.authenticating,
        activeDeviceAddress: macA,
      );
      await _settle();
      expect(await credentials.readAuthKey(macA), isNull);

      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
      );
      await _settle();
      expect(await credentials.readAuthKey(macA), authKeyA);
      expect(application.snapshot.devices.single.authKeyLabel, authKeyA);
    });

    test('removing a saved device removes its key and snapshot key label',
        () async {
      await _saveSupportedDevice(devices, macA);
      await credentials.saveAuthKey(macA, authKeyA);
      await application.initialize();

      final result = await application.removeSavedDevice(macA);

      expect(result.accepted, isTrue);
      expect(await devices.load(), isEmpty);
      expect(await credentials.readAuthKey(macA), isNull);
      expect(application.snapshot.devices, isEmpty);
    });

    test('explicit disconnect suppresses another auto-connect this process',
        () async {
      await _saveSupportedDevice(devices, macA,
          at: DateTime.utc(2026, 8, 15, 1));
      await credentials.saveAuthKey(macA, authKeyA);
      await application.initialize();
      expect(backend.connectCalls, hasLength(1));

      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
      );
      await _settle();
      final result = await application.disconnect();
      expect(result.accepted, isTrue);
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.disconnected);
      expect(application.snapshot.activeDeviceId, isNull);

      await application.setAutoConnect(false);
      await application.setAutoConnect(true);
      expect(backend.connectCalls, hasLength(1));
      expect(application.snapshot.autoConnectState,
          TuiApplicationAutoConnectState.suppressedAfterDisconnect);
    });

    test('saving an already ready device makes it auto-connect eligible',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
      );
      await _settle();

      await application.saveDevice(macA);

      final saved = await devices.findByMacAddress(macA);
      expect(saved?.lastConnectedAt, isNotNull);
    });
  });
}

TuiBackendDevice _device({
  required String address,
  String name = 'Xiaomi Smart Band 10',
  DeviceProfile profile = DeviceProfile.band10,
}) =>
    TuiBackendDevice(
      address: address,
      addressKey: address,
      name: name,
      paired: true,
      profile: profile,
      sources: const {TuiBackendDeviceSource.inquiry},
    );

Future<void> _saveSupportedDevice(
  _MemorySavedDeviceRepository repository,
  String macAddress, {
  DateTime? at,
}) =>
    repository.save(
      SavedTuiDevice(
        displayName: 'Xiaomi Smart Band 10',
        macAddress: macAddress,
        isSupported: true,
        profileId: DeviceFamily.band10.name,
        lastConnectedAt: at,
      ),
    );

Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

final class _ConnectCall {
  const _ConnectCall({
    required this.address,
    required this.name,
    required this.profile,
  });

  final String address;
  final String name;
  final DeviceProfile? profile;
}

final class _FakeBackend implements TuiBackendPort {
  _FakeBackend() : _snapshot = _snapshotFor();

  final StreamController<TuiBackendSnapshot> _controller =
      StreamController<TuiBackendSnapshot>.broadcast(sync: true);
  final List<_ConnectCall> connectCalls = [];
  final List<String> providedKeys = [];
  late TuiBackendSnapshot _snapshot;
  void Function(_ConnectCall call)? onConnect;
  int startScanCalls = 0;
  int clearAuthKeyCalls = 0;
  int disconnectCalls = 0;

  @override
  TuiBackendSnapshot get snapshot => _snapshot;

  @override
  Stream<TuiBackendSnapshot> get snapshots async* {
    yield _snapshot;
    yield* _controller.stream;
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> startScan(
      {Duration duration = const Duration(seconds: 10)}) async {
    startScanCalls++;
    _publish(_copy(scanning: true));
  }

  @override
  Future<void> stopScan() async => _publish(_copy(scanning: false));

  @override
  Future<void> refreshPairedDevices() async {}

  @override
  Future<void> connectByAddress({
    required String address,
    required String name,
    DeviceProfile? profile,
  }) async {
    final call = _ConnectCall(address: address, name: name, profile: profile);
    connectCalls.add(call);
    _publish(_copy(
      connection: TuiBackendConnectionState.connecting,
      activeDeviceAddress: address,
      clearFailure: true,
    ));
    onConnect?.call(call);
  }

  @override
  Future<void> provideAuthKey(String authKey) async {
    providedKeys.add(authKey);
    _publish(_copy(authKeyLoaded: true));
  }

  @override
  Future<void> clearAuthKey() async {
    clearAuthKeyCalls++;
    _publish(_copy(authKeyLoaded: false));
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _publish(_copy(
      connection: TuiBackendConnectionState.disconnected,
      activeDeviceAddress: null,
      clearActiveDeviceAddress: true,
      clearFailure: true,
    ));
  }

  @override
  Future<void> install(InstallRequest request) async {}

  @override
  Future<void> cancelInstall() async {}

  @override
  Future<void> dispose() => _controller.close();

  void publishDevices(List<TuiBackendDevice> devices) =>
      _publish(_copy(devices: devices));

  void publishConnection(
    TuiBackendConnectionState connection, {
    required String activeDeviceAddress,
  }) =>
      _publish(_copy(
        connection: connection,
        activeDeviceAddress: activeDeviceAddress,
        clearFailure: true,
      ));

  void _publish(TuiBackendSnapshot value) {
    _snapshot = value;
    _controller.add(value);
  }

  TuiBackendSnapshot _copy({
    bool? scanning,
    TuiBackendConnectionState? connection,
    List<TuiBackendDevice>? devices,
    bool? authKeyLoaded,
    String? activeDeviceAddress,
    bool clearActiveDeviceAddress = false,
    bool clearFailure = false,
  }) =>
      TuiBackendSnapshot(
        revision: _snapshot.revision + 1,
        helperState: _snapshot.helperState,
        scanning: scanning ?? _snapshot.scanning,
        transportConnected: _snapshot.transportConnected,
        connection: connection ?? _snapshot.connection,
        devices: devices ?? _snapshot.devices,
        authKeyLoaded: authKeyLoaded ?? _snapshot.authKeyLoaded,
        activeDeviceAddress: clearActiveDeviceAddress
            ? null
            : (activeDeviceAddress ?? _snapshot.activeDeviceAddress),
        failureCode: clearFailure ? null : _snapshot.failureCode,
        message: _snapshot.message,
        installation: _snapshot.installation,
      );

  static TuiBackendSnapshot _snapshotFor() => const TuiBackendSnapshot(
        revision: 0,
        helperState: TuiBackendHelperState.ready,
        scanning: false,
        transportConnected: false,
        connection: TuiBackendConnectionState.disconnected,
        devices: [],
        authKeyLoaded: false,
      );
}

final class _MemorySavedDeviceRepository implements SavedDeviceRepository {
  final Map<String, SavedTuiDevice> _devices = {};

  @override
  Future<List<SavedTuiDevice>> load() async => _devices.values.toList();

  @override
  Future<SavedTuiDevice?> findByMacAddress(String macAddress) async =>
      _devices[SavedTuiDevice.normalizeMacAddress(macAddress)];

  @override
  Future<void> save(SavedTuiDevice device) async {
    _devices[device.macAddress] = device;
  }

  @override
  Future<void> removeByMacAddress(String macAddress) async {
    _devices.remove(SavedTuiDevice.normalizeMacAddress(macAddress));
  }
}

final class _MemoryPreferenceStore extends TuiPreferenceStore {
  _MemoryPreferenceStore() : super(fileResolver: _unusedFile);

  TuiPreferences value = const TuiPreferences();

  @override
  Future<TuiPreferences> load() async => value;

  @override
  Future<void> setAutoConnectLastDevice(bool enabled) async {
    value = value.copyWith(autoConnectLastDevice: enabled);
  }

  @override
  Future<void> setThemeId(String themeId) async {
    value = value.copyWith(themeId: themeId);
  }
}

Future<Never> _unusedFile() => throw UnimplementedError();
