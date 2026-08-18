import 'dart:async';

import 'package:test/test.dart';
import 'package:wristload_tui/src/application/persistence/saved_device_repository.dart';
import 'package:wristload_tui/src/application/persistence/saved_tui_device.dart';
import 'package:wristload_tui/src/application/persistence/tui_credential_store.dart';
import 'package:wristload_tui/src/application/persistence/tui_binding_material_store.dart';
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
    late InMemoryTuiBindingMaterialStore bindingMaterials;
    late _MemoryPreferenceStore preferences;
    late TuiApplication application;

    setUp(() async {
      backend = _FakeBackend();
      devices = _MemorySavedDeviceRepository();
      credentials = InMemoryTuiCredentialStore();
      bindingMaterials = InMemoryTuiBindingMaterialStore();
      await bindingMaterials.saveBindingMaterial(
        macA,
        appDeviceId: 'app-device-a',
        oob: 'oob-a',
      );
      await bindingMaterials.saveBindingMaterial(
        macB,
        appDeviceId: 'app-device-b',
      );
      preferences = _MemoryPreferenceStore();
      application = TuiApplication(
        backend: backend,
        savedDeviceRepository: devices,
        credentialStore: credentials,
        bindingMaterialStore: bindingMaterials,
        preferenceStore: preferences,
      );
    });

    tearDown(() => application.dispose());

    test('publishes the canonical lifecycle without conflating transport ready',
        () async {
      final observed = <TuiApplicationConnectionState>[];
      final subscription = application.snapshots.listen(
        (snapshot) => observed.add(snapshot.connection),
      );
      addTearDown(subscription.cancel);

      await application.initialize();
      expect(
          application.snapshot.connection, TuiApplicationConnectionState.idle);

      await application.startScan();
      expect(
        application.snapshot.connection,
        TuiApplicationConnectionState.scanning,
      );
      expect(application.snapshot.scanning, isTrue);

      await application.stopScan();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      expect(
        application.snapshot.connection,
        TuiApplicationConnectionState.waitingAuthkey,
      );
      expect(application.snapshot.selectedDeviceId, macA);

      await application.disconnect();
      expect(
        application.snapshot.connection,
        TuiApplicationConnectionState.selected,
      );
      expect(application.snapshot.selectedDeviceId, macA);

      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);
      expect(
        application.snapshot.connection,
        TuiApplicationConnectionState.connecting,
      );

      final backendRows = <({
        String label,
        TuiBackendConnectionState backendState,
        bool transportConnected,
        TuiBackendInstallation? installation,
        TuiApplicationConnectionState expected,
      })>[
        (
          label: 'raw transport only',
          backendState: TuiBackendConnectionState.connecting,
          transportConnected: true,
          installation: null,
          expected: TuiApplicationConnectionState.connected,
        ),
        (
          label: 'protocol authentication',
          backendState: TuiBackendConnectionState.authenticating,
          transportConnected: true,
          installation: null,
          expected: TuiApplicationConnectionState.authenticating,
        ),
        (
          label: 'authenticated session',
          backendState: TuiBackendConnectionState.ready,
          transportConnected: true,
          installation: null,
          expected: TuiApplicationConnectionState.ready,
        ),
        (
          label: 'install in progress',
          backendState: TuiBackendConnectionState.ready,
          transportConnected: true,
          installation: const TuiBackendInstallation(
            state: TuiBackendInstallState.transferring,
            fileName: 'face.bin',
            message: 'transferring',
          ),
          expected: TuiApplicationConnectionState.installing,
        ),
      ];

      for (final row in backendRows) {
        backend.publishLifecycle(
          row.backendState,
          activeDeviceAddress: macA,
          transportConnected: row.transportConnected,
          installation: row.installation,
        );
        expect(
          application.snapshot.connection,
          row.expected,
          reason: row.label,
        );
      }

      backend.pauseDisconnect = true;
      final disconnect = application.disconnect();
      await _settle();
      expect(
        application.snapshot.connection,
        TuiApplicationConnectionState.disconnecting,
      );
      backend.completeDisconnect();
      await disconnect;

      backend.publishFailure('transport_failed');
      expect(
        application.snapshot.connection,
        TuiApplicationConnectionState.selected,
      );
      expect(observed, contains(TuiApplicationConnectionState.disconnecting));
    });

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
      expect(backend.connectCalls.single.directedExactAddress, isFalse);
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
      expect(backend.operations, ['provide:$authKeyA', 'connect:$macA']);
      expect(backend.connectCalls.single.directedExactAddress, isFalse);
    });

    test(
        'a selected live Classic scan uses its exact MAC and current metadata',
        () async {
      await devices.save(SavedTuiDevice(
        displayName: 'Stale saved name',
        macAddress: macA,
        isSupported: true,
        profileId: DeviceFamily.band9.name,
      ));
      await application.initialize();
      backend.publishDevices([
        _device(
          address: macA,
          name: 'Live Xiaomi Smart Band 10 Pro',
          profile: DeviceProfile.band10Pro,
        ),
      ]);

      final selected = await application.connectSelectedScannedDevice(macA);
      final submitted = await application.submitAuthKey(macA, authKeyA);

      expect(selected.accepted, isTrue);
      expect(submitted.accepted, isTrue);
      expect(backend.connectCalls, hasLength(1));
      final call = backend.connectCalls.single;
      expect(call.address, macA);
      expect(call.name, 'Live Xiaomi Smart Band 10 Pro');
      expect(call.profile, DeviceProfile.band10Pro);
      expect(call.directedExactAddress, isTrue);

      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        connectionGeneration: call.attemptGeneration!,
      );
      await _settle();
      await _settle();

      // A current scan row controls this connection attempt, while an existing
      // saved record keeps its user-owned display/profile metadata.  Ready
      // still updates its history and persists the submitted key normally.
      final persisted = await devices.findByMacAddress(macA);
      expect(persisted?.displayName, 'Stale saved name');
      expect(persisted?.profileId, DeviceFamily.band9.name);
      expect(persisted?.lastConnectedAt, isNotNull);
      expect(await credentials.readAuthKey(macA), authKeyA);
    });

    test('a saved-only selected row retains strict identity behavior', () async {
      await _saveSupportedDevice(devices, macA);
      await application.initialize();

      await application.connectSelectedScannedDevice(macA);
      await application.submitAuthKey(macA, authKeyA);

      expect(backend.connectCalls, hasLength(1));
      expect(backend.connectCalls.single.directedExactAddress, isFalse);
    });

    test(
        'submitting authkey fences synchronous stale awaiting snapshots and connects once',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectSelectedScannedDevice(macA);
      final observed = <TuiApplicationSnapshot>[];
      final subscription = application.snapshots.listen(observed.add);
      addTearDown(subscription.cancel);
      await _settle();
      observed.clear();
      backend.onProvideAuthKey = (_) {
        backend.publishConnection(
          TuiBackendConnectionState.awaitingAuthKey,
          activeDeviceAddress: macA,
        );
      };

      final submitted = await application.submitAuthKey(macA, authKeyA);

      expect(submitted.accepted, isTrue);
      expect(backend.connectCalls, hasLength(1));
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.connecting);
      expect(application.snapshot.pendingAuthDeviceId, isNull);
      expect(
        observed.any((snapshot) =>
            snapshot.connection == TuiApplicationConnectionState.waitingAuthkey ||
            snapshot.pendingAuthDeviceId != null),
        isFalse,
      );
    });

    test('a pre-resolve tupleless disconnect does not retire the attempt',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectSelectedScannedDevice(macA);
      backend.onConnectStarted = (_) => backend.publishTuplelessDisconnect();

      final submitted = await application.submitAuthKey(macA, authKeyA);

      expect(submitted.accepted, isTrue);
      expect(backend.connectCalls, hasLength(1));
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.connecting);
      expect(application.snapshot.pendingAuthDeviceId, isNull);

      final generation = backend.connectCalls.single.attemptGeneration!;
      backend.publishConnection(
        TuiBackendConnectionState.authenticating,
        activeDeviceAddress: macA,
        connectionGeneration: generation,
      );
      await _settle();
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.authenticating);
    });

    test(
        'explicit directed address intent reaches backend only for that attempt',
        () async {
      final directed = TuiApplication(
        backend: backend,
        savedDeviceRepository: devices,
        credentialStore: credentials,
        bindingMaterialStore: bindingMaterials,
        preferenceStore: preferences,
        directedClassicTarget: TuiDirectedClassicTarget(
          macAddress: macA,
          displayName: 'Explicit directed target',
          profile: DeviceProfile.band10,
        ),
      );
      addTearDown(directed.dispose);
      await directed.initialize();
      await directed.connectDevice(
        macA,
        intent: TuiApplicationConnectionIntent.directedExactAddress,
      );
      final submitted = await directed.submitAuthKey(macA, authKeyA);

      expect(submitted.accepted, isTrue);
      expect(backend.connectCalls, hasLength(1));
      expect(backend.connectCalls.single.directedExactAddress, isTrue);

      await directed.disconnect();
      await directed.connectDevice(macA);
      await directed.submitAuthKey(macA, authKeyA);
      expect(backend.connectCalls.last.directedExactAddress, isFalse);
    });

    test('directed target is visible before discovery without saved history',
        () async {
      final target = TuiDirectedClassicTarget(
        macAddress: macB,
        displayName: 'Configured Classic target',
        profile: DeviceProfile.band10Pro,
      );
      final directed = TuiApplication(
        backend: backend,
        savedDeviceRepository: devices,
        credentialStore: credentials,
        bindingMaterialStore: bindingMaterials,
        preferenceStore: preferences,
        directedClassicTarget: target,
      );
      addTearDown(directed.dispose);

      await directed.initialize();

      final device = directed.snapshot.devices.single;
      expect(device.macAddress, macB);
      expect(device.name, 'Configured Classic target');
      expect(device.profileId, DeviceFamily.band10Pro.name);
      expect(device.support, TuiApplicationDeviceSupport.supported);
      expect(device.isDirectedSessionTarget, isTrue);
      expect(device.saved, isFalse);
      expect(device.authKeyLabel, '-');
    });

    test('directed connection is rejected without an exact launch target',
        () async {
      await application.initialize();

      final dedicated = await application.connectDirectedExactAddress();
      final mismatched = await application.connectDevice(
        macA,
        intent: TuiApplicationConnectionIntent.directedExactAddress,
      );

      expect(dedicated.accepted, isFalse);
      expect(dedicated.code, 'directed_target_unavailable');
      expect(mismatched.accepted, isFalse);
      expect(mismatched.code, 'directed_target_unavailable');
      expect(backend.connectCalls, isEmpty);
    });

    test('directed ready stays ephemeral until the user explicitly saves it',
        () async {
      final target = TuiDirectedClassicTarget(
        macAddress: macB,
        displayName: 'Configured Classic target',
        profile: DeviceProfile.band10Pro,
      );
      final directed = TuiApplication(
        backend: backend,
        savedDeviceRepository: devices,
        credentialStore: credentials,
        bindingMaterialStore: bindingMaterials,
        preferenceStore: preferences,
        directedClassicTarget: target,
      );
      addTearDown(directed.dispose);
      await directed.initialize();

      await directed.connectDirectedExactAddress();
      await directed.submitAuthKey(macB, authKeyB);
      final generation = backend.connectCalls.single.attemptGeneration!;
      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macB,
        connectionGeneration: generation,
      );
      await _settle();
      await _settle();

      expect(await devices.findByMacAddress(macB), isNull);
      expect(await credentials.readAuthKey(macB), isNull);
      expect(directed.snapshot.devices.single.saved, isFalse);

      final saved = await directed.saveDevice(macB);

      expect(saved.accepted, isTrue);
      expect((await devices.findByMacAddress(macB))?.displayName,
          'Configured Classic target');
      expect(await credentials.readAuthKey(macB), authKeyB);
      expect(directed.snapshot.devices.single.saved, isTrue);
    });

    test(
        'directed ready does not update an existing same-MAC record or authkey without explicit save',
        () async {
      final existing = SavedTuiDevice(
        displayName: 'Existing saved device',
        macAddress: macB,
        isSupported: true,
        profileId: DeviceProfile.band10Pro.family.name,
        lastConnectedAt: DateTime.utc(2026, 8, 16, 1),
      );
      await devices.save(existing);
      final target = TuiDirectedClassicTarget(
        macAddress: macB,
        displayName: 'Configured Classic target',
        profile: DeviceProfile.band10Pro,
      );
      final directed = TuiApplication(
        backend: backend,
        savedDeviceRepository: devices,
        credentialStore: credentials,
        bindingMaterialStore: bindingMaterials,
        preferenceStore: preferences,
        directedClassicTarget: target,
      );
      addTearDown(directed.dispose);
      await directed.initialize();

      await directed.connectDirectedExactAddress();
      await directed.submitAuthKey(macB, authKeyB);
      final generation = backend.connectCalls.single.attemptGeneration!;
      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macB,
        connectionGeneration: generation,
      );
      await _settle();
      await _settle();

      expect(await devices.findByMacAddress(macB), existing);
      expect(await credentials.readAuthKey(macB), isNull);

      final saved = await directed.saveDevice(macB);

      expect(saved.accepted, isTrue);
      expect((await devices.findByMacAddress(macB))?.displayName,
          'Configured Classic target');
      expect(await credentials.readAuthKey(macB), authKeyB);
    });

    test(
        'missing binding material still starts Classic transport with null binding',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      await bindingMaterials.removeBindingMaterial(macA);

      final result = await application.submitAuthKey(macA, authKeyA);

      expect(result.accepted, isTrue);
      expect(result.code, 'ok');
      expect(backend.providedKeys, [authKeyA]);
      expect(backend.connectCalls, hasLength(1));
      expect(backend.connectCalls.single.bindingMaterial, isNull);
      expect(application.snapshot.pendingAuthDeviceId, isNull);
    });

    test('pending auth remains bound to its MAC across stale backend snapshots',
        () async {
      await application.initialize();
      backend.publishDevices([
        _device(address: macA, name: 'Band A'),
        _device(address: macB, name: 'Band B'),
      ]);
      await application.connectDevice(macA);

      backend.publishConnection(
        TuiBackendConnectionState.authenticating,
        activeDeviceAddress: macB,
      );
      await _settle();

      expect(application.snapshot.activeDeviceId, macA);
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.awaitingAuthKey);

      final submitted = await application.submitAuthKey(macA, authKeyA);

      expect(submitted.accepted, isTrue);
      expect(backend.operations, ['provide:$authKeyA', 'connect:$macA']);
      expect(backend.connectCalls.single.name, 'Band A');
    });

    test('a newer pending target rejects input for the old generation',
        () async {
      await application.initialize();
      backend.publishDevices([
        _device(address: macA, name: 'Band A'),
        _device(address: macB, name: 'Band B'),
      ]);
      await application.connectDevice(macA);
      await application.connectDevice(macB);

      final stale = await application.submitAuthKey(macA, authKeyA);
      final current = await application.submitAuthKey(macB, authKeyB);

      expect(stale.accepted, isFalse);
      expect(stale.code, 'not_waiting_for_authkey');
      expect(current.accepted, isTrue);
      expect(backend.operations, ['provide:$authKeyB', 'connect:$macB']);
      expect(backend.connectCalls.single.name, 'Band B');
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
          TuiApplicationConnectionState.selected);
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
        connectionGeneration: backend.connectCalls.single.attemptGeneration!,
      );
      await _settle();
      expect(await credentials.readAuthKey(macA), authKeyA);
      expect(application.snapshot.devices.single.authKeyLabel, authKeyA);
    });

    test('ready for another MAC cannot persist the current pending key',
        () async {
      await application.initialize();
      backend.publishDevices([
        _device(address: macA),
        _device(address: macB, name: 'Xiaomi Smart Band 10 Pro'),
      ]);
      await application.saveDevice(macA);
      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);

      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macB,
      );
      await _settle();

      expect(await credentials.readAuthKey(macA), isNull);
      expect(await credentials.readAuthKey(macB), isNull);

      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        connectionGeneration: backend.connectCalls.single.attemptGeneration!,
      );
      await _settle();

      expect(await credentials.readAuthKey(macA), authKeyA);
      expect(await credentials.readAuthKey(macB), isNull);
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
      expect(await bindingMaterials.readBindingMaterial(macA), isNull);
      expect(application.snapshot.devices, isEmpty);
    });

    test('removing a pending-auth device retires its selection and generation',
        () async {
      await _saveSupportedDevice(devices, macA);
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);

      await application.connectDevice(macA);
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.waitingAuthkey);
      final pendingGeneration = application.snapshot.connectionGeneration;
      expect(application.snapshot.pendingAuthDeviceId, macA);
      expect(application.snapshot.activeDeviceId, macA);
      expect(application.snapshot.selectedDeviceId, macA);

      final result = await application.removeSavedDevice(macA);

      expect(result.accepted, isTrue);
      expect(application.snapshot.pendingAuthDeviceId, isNull);
      expect(application.snapshot.activeDeviceId, isNull);
      expect(application.snapshot.selectedDeviceId, isNull);
      expect(application.snapshot.connectionGeneration,
          greaterThan(pendingGeneration));
      expect(
          application.snapshot.connection, TuiApplicationConnectionState.idle);

      // A stale ready event from the retired generation must not reopen the
      // removed target or persist it as a connected saved device.
      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        connectionGeneration: pendingGeneration,
      );
      await _settle();

      expect(
          application.snapshot.connection, TuiApplicationConnectionState.idle);
      expect(application.snapshot.activeDeviceId, isNull);
      expect(application.snapshot.selectedDeviceId, isNull);
      expect(await devices.findByMacAddress(macA), isNull);
      expect(await credentials.readAuthKey(macA), isNull);
    });

    test('removing a connecting saved device retires and disconnects it',
        () async {
      await _saveSupportedDevice(devices, macA);
      await application.initialize();

      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);
      final removedGeneration = backend.connectCalls.single.attemptGeneration!;
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.connecting);

      final result = await application.removeSavedDevice(macA);

      expect(result.accepted, isTrue);
      expect(backend.disconnectCalls, 1);
      expect(application.snapshot.connectionGeneration,
          greaterThan(removedGeneration));
      expect(application.snapshot.activeDeviceId, isNull);
      expect(application.snapshot.selectedDeviceId, isNull);
      expect(application.snapshot.pendingAuthDeviceId, isNull);
      expect(await devices.findByMacAddress(macA), isNull);
      expect(await credentials.readAuthKey(macA), isNull);
      expect(await bindingMaterials.readBindingMaterial(macA), isNull);

      for (var index = 0; index < 2; index++) {
        backend.publishConnection(
          TuiBackendConnectionState.ready,
          activeDeviceAddress: macA,
          connectionGeneration: removedGeneration,
        );
      }
      await _settle();

      expect(
          application.snapshot.connection, TuiApplicationConnectionState.idle);
      expect(await devices.findByMacAddress(macA), isNull);
      expect(await credentials.readAuthKey(macA), isNull);
      expect(await bindingMaterials.readBindingMaterial(macA), isNull);
    });

    test('removing a ready saved device prevents late ready persistence',
        () async {
      await _saveSupportedDevice(devices, macA);
      await credentials.saveAuthKey(macA, authKeyA);
      await application.initialize();
      await application.connectDevice(macA);
      final removedGeneration = backend.connectCalls.single.attemptGeneration!;
      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        connectionGeneration: removedGeneration,
      );
      await _settle();
      expect(
          application.snapshot.connection, TuiApplicationConnectionState.ready);

      final result = await application.removeSavedDevice(macA);

      expect(result.accepted, isTrue);
      expect(backend.disconnectCalls, 1);
      expect(application.snapshot.activeDeviceId, isNull);
      expect(application.snapshot.selectedDeviceId, isNull);
      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        connectionGeneration: removedGeneration,
      );
      await _settle();

      expect(application.snapshot.connection,
          isNot(TuiApplicationConnectionState.ready));
      expect(await devices.findByMacAddress(macA), isNull);
      expect(await credentials.readAuthKey(macA), isNull);
      expect(await bindingMaterials.readBindingMaterial(macA), isNull);
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
          TuiApplicationConnectionState.selected);
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
      await application.submitAuthKey(macA, authKeyA);
      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
      );
      await _settle();

      await application.saveDevice(macA);

      final saved = await devices.findByMacAddress(macA);
      expect(saved?.lastConnectedAt, isNotNull);
    });

    test('saving during a stale ready snapshot does not stamp last connected',
        () async {
      await application.initialize();
      // A retired ready snapshot can be observed before a new auth-key attempt
      // selects the same MAC.  It must not make that new attempt eligible for
      // auto-connect history.
      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        connectionGeneration: 99,
      );
      backend.publishDevices([_device(address: macA)]);
      await _settle();

      await application.connectDevice(macA);
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.waitingAuthkey);

      final result = await application.saveDevice(macA);
      final saved = await devices.findByMacAddress(macA);

      expect(result.accepted, isTrue);
      expect(saved?.lastConnectedAt, isNull);
    });

    test('first successful ready connection saves device and authkey',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);

      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);
      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
      );
      await _settle();

      final saved = await devices.findByMacAddress(macA);
      expect(saved?.displayName, 'Xiaomi Smart Band 10');
      expect(saved?.lastConnectedAt, isNotNull);
      expect(await credentials.readAuthKey(macA), authKeyA);
      expect(application.snapshot.devices.single.saved, isTrue);
      expect(application.snapshot.devices.single.authKeyLabel, authKeyA);
    });

    test('ignores a foreign native tuple after connect was issued', () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);

      backend.publishForeignConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        connectionId: 'retired-connection',
        connectionGeneration: 900,
        identityGeneration: 900,
      );
      await _settle();
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.connecting);
      expect(await credentials.readAuthKey(macA), isNull);

      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        connectionGeneration: backend.connectCalls.single.attemptGeneration!,
      );
      await _settle();
      expect(
          application.snapshot.connection, TuiApplicationConnectionState.ready);
      expect(await credentials.readAuthKey(macA), authKeyA);
    });

    test('rebinds a fresh post-auth RFCOMM tuple within the same attempt',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);
      final attemptGeneration = backend.connectCalls.single.attemptGeneration!;

      backend.publishConnection(
        TuiBackendConnectionState.authenticating,
        activeDeviceAddress: macA,
        connectionGeneration: attemptGeneration,
      );
      await _settle();
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.authenticating);

      backend.publishRecoveryConnection(
        TuiBackendConnectionState.authenticating,
        activeDeviceAddress: macA,
        applicationGeneration: attemptGeneration,
        connectionGeneration: attemptGeneration + 1,
        connectionId: 'recovery-${attemptGeneration + 1}',
        identityGeneration: attemptGeneration,
      );
      await _settle();

      backend.publishRecoveryConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        applicationGeneration: attemptGeneration,
        connectionGeneration: attemptGeneration + 1,
        connectionId: 'recovery-${attemptGeneration + 1}',
        identityGeneration: attemptGeneration,
      );
      await _settle();

      expect(
          application.snapshot.connection, TuiApplicationConnectionState.ready);
      expect(await credentials.readAuthKey(macA), authKeyA);

      // A late event from the retired tuple must remain rejected.
      backend.publishRecoveryConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        applicationGeneration: attemptGeneration,
        connectionGeneration: attemptGeneration,
        connectionId: 'connection-$attemptGeneration',
        identityGeneration: attemptGeneration,
      );
      await _settle();
      expect(
          application.snapshot.connection, TuiApplicationConnectionState.ready);
    });

    test('post-auth tuple rebind retains the original Classic identity binding',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);
      final attemptGeneration = backend.connectCalls.single.attemptGeneration!;
      const candidate = 'classic:AABBCCDDEE01';

      backend.publishConnection(
        TuiBackendConnectionState.authenticating,
        activeDeviceAddress: macA,
        connectionGeneration: attemptGeneration,
      );
      await _settle();

      backend.publishRecoveryConnection(
        TuiBackendConnectionState.authenticating,
        activeDeviceAddress: macA,
        applicationGeneration: attemptGeneration,
        connectionGeneration: attemptGeneration + 1,
        connectionId: 'foreign-candidate',
        identityCandidateId: 'classic:foreign',
        identityGeneration: attemptGeneration,
      );
      await _settle();
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.authenticating);
      expect(await credentials.readAuthKey(macA), isNull);

      backend.publishRecoveryConnection(
        TuiBackendConnectionState.authenticating,
        activeDeviceAddress: macA,
        applicationGeneration: attemptGeneration,
        connectionGeneration: attemptGeneration + 1,
        connectionId: 'foreign-identity-generation',
        identityCandidateId: candidate,
        identityGeneration: attemptGeneration + 99,
      );
      await _settle();
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.authenticating);
      expect(await credentials.readAuthKey(macA), isNull);

      backend.publishRecoveryConnection(
        TuiBackendConnectionState.authenticating,
        activeDeviceAddress: macA,
        applicationGeneration: attemptGeneration,
        connectionGeneration: attemptGeneration + 1,
        connectionId: 'recovery-${attemptGeneration + 1}',
        identityCandidateId: candidate,
        identityGeneration: attemptGeneration,
      );
      backend.publishRecoveryConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        applicationGeneration: attemptGeneration,
        connectionGeneration: attemptGeneration + 1,
        connectionId: 'recovery-${attemptGeneration + 1}',
        identityCandidateId: candidate,
        identityGeneration: attemptGeneration,
      );
      await _settle();

      expect(
          application.snapshot.connection, TuiApplicationConnectionState.ready);
      expect(await credentials.readAuthKey(macA), authKeyA);
    });

    test('identity confirmation failure never persists a ready device',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);
      backend.failIdentityConfirmation = true;

      backend.publishProtocolReady(activeDeviceAddress: macA);
      await _settle();
      await _settle();

      expect(application.snapshot.connection,
          TuiApplicationConnectionState.failed);
      expect(await devices.findByMacAddress(macA), isNull);
      expect(await credentials.readAuthKey(macA), isNull);
      expect(backend.disconnectCalls, greaterThan(0));
    });

    test('a current backend failure retires its tuple before late ready',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);
      final failedGeneration = backend.connectCalls.single.attemptGeneration!;

      backend.publishFailure('rfcomm_open_failed');
      await _settle();

      expect(application.snapshot.connection,
          TuiApplicationConnectionState.failed);
      expect(application.snapshot.connectionGeneration,
          greaterThan(failedGeneration));

      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        connectionGeneration: failedGeneration,
      );
      await _settle();

      expect(application.snapshot.connection,
          TuiApplicationConnectionState.failed);
      expect(await devices.findByMacAddress(macA), isNull);
      expect(await credentials.readAuthKey(macA), isNull);
    });

    test('a failure retires the attempt but admits a fresh discovery snapshot',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);

      backend.publishFailure('rfcomm_open_failed');
      await _settle();
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.failed);
      expect(backend.disconnectCalls, 1);

      backend.publishUnscopedDiscovery(
        devices: [_device(address: macB, name: 'Fresh scan result')],
        scanning: true,
      );
      await _settle();

      expect(application.snapshot.scanning, isTrue);
      expect(application.snapshot.devices, hasLength(1));
      expect(application.snapshot.devices.single.macAddress, macB);
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.failed);
    });

    test('a correlated disconnect retires its tuple before late ready',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);
      final disconnectedGeneration =
          backend.connectCalls.single.attemptGeneration!;

      backend.publishConnection(
        TuiBackendConnectionState.disconnected,
        activeDeviceAddress: macA,
        connectionGeneration: disconnectedGeneration,
      );
      await _settle();

      expect(application.snapshot.connection,
          TuiApplicationConnectionState.failed);
      expect(application.snapshot.connectionGeneration,
          greaterThan(disconnectedGeneration));

      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        connectionGeneration: disconnectedGeneration,
      );
      await _settle();

      expect(application.snapshot.connection,
          TuiApplicationConnectionState.failed);
      expect(await devices.findByMacAddress(macA), isNull);
      expect(await credentials.readAuthKey(macA), isNull);
    });

    test('a tupleless correlated disconnect retires its live attempt',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);
      final disconnectedGeneration =
          backend.connectCalls.single.attemptGeneration!;

      backend.publishTuplelessDisconnect();
      await _settle();

      expect(application.snapshot.connection,
          TuiApplicationConnectionState.failed);
      expect(application.snapshot.connectionGeneration,
          greaterThan(disconnectedGeneration));

      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        connectionGeneration: disconnectedGeneration,
      );
      await _settle();

      expect(application.snapshot.connection,
          TuiApplicationConnectionState.failed);
      expect(await devices.findByMacAddress(macA), isNull);
      expect(await credentials.readAuthKey(macA), isNull);
    });

    test('a failure-bearing ready snapshot is terminal and never persists',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);
      final failedGeneration = backend.connectCalls.single.attemptGeneration!;

      backend.publishFailureReady(
        'authentication_failed',
        activeDeviceAddress: macA,
        connectionGeneration: failedGeneration,
      );
      await _settle();

      expect(application.snapshot.connection,
          TuiApplicationConnectionState.failed);
      expect(application.snapshot.connectionGeneration,
          greaterThan(failedGeneration));
      expect(await devices.findByMacAddress(macA), isNull);
      expect(await credentials.readAuthKey(macA), isNull);
    });

    test('a connect exception retires its issued attempt', () async {
      await _saveSupportedDevice(devices, macA);
      await credentials.saveAuthKey(macA, authKeyA);
      await application.initialize();
      backend.failConnect = true;

      final result = await application.connectDevice(macA);
      final failedGeneration = backend.connectCalls.single.attemptGeneration!;

      expect(result.accepted, isFalse);
      expect(result.code, 'connect_failed');
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.failed);
      expect(application.snapshot.connectionGeneration,
          greaterThan(failedGeneration));

      backend.publishConnection(
        TuiBackendConnectionState.ready,
        activeDeviceAddress: macA,
        connectionGeneration: failedGeneration,
      );
      await _settle();

      expect(application.snapshot.connection,
          TuiApplicationConnectionState.failed);
      expect((await devices.findByMacAddress(macA))?.lastConnectedAt, isNull);
    });

    test('an uncorrelated backend stream error does not replace an attempt',
        () async {
      await application.initialize();
      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      await application.submitAuthKey(macA, authKeyA);

      backend.publishUncorrelatedError(StateError('helper stream failed'));
      await _settle();

      expect(application.snapshot.connection,
          TuiApplicationConnectionState.connecting);
      expect(application.snapshot.activeDeviceId, macA);
      expect(application.snapshot.error, isNull);
    });

    test(
        'an uncorrelated backend stream error does not poison idle, selected, or scanning',
        () async {
      await application.initialize();
      backend.publishUncorrelatedError(StateError('idle helper stream failed'));
      await _settle();
      expect(
          application.snapshot.connection, TuiApplicationConnectionState.idle);
      expect(application.snapshot.error, isNull);

      backend.publishDevices([_device(address: macA)]);
      await application.connectDevice(macA);
      await application.disconnect();
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.selected);

      backend.publishUncorrelatedError(
          StateError('selected helper stream failed'));
      await _settle();
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.selected);
      expect(application.snapshot.error, isNull);

      await application.startScan();
      expect(application.snapshot.connection,
          TuiApplicationConnectionState.scanning);
      backend.publishUncorrelatedError(StateError('scan helper stream failed'));
      await _settle();

      expect(application.snapshot.connection,
          TuiApplicationConnectionState.scanning);
      expect(application.snapshot.error, isNull);
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
    required this.requireConfirmedIdentity,
    required this.directedExactAddress,
    required this.attemptGeneration,
    required this.bindingMaterial,
  });

  final String address;
  final String name;
  final DeviceProfile? profile;
  final bool requireConfirmedIdentity;
  final bool directedExactAddress;
  final int? attemptGeneration;
  final TuiBackendBindingMaterial? bindingMaterial;
}

final class _FakeBackend implements TuiBackendPort {
  _FakeBackend() : _snapshot = _snapshotFor();

  final StreamController<TuiBackendSnapshot> _controller =
      StreamController<TuiBackendSnapshot>.broadcast(sync: true);
  final List<_ConnectCall> connectCalls = [];
  final List<String> providedKeys = [];
  final List<String> operations = [];
  final List<int> confirmedGenerations = [];
  late TuiBackendSnapshot _snapshot;
  void Function(_ConnectCall call)? onConnect;
  void Function(_ConnectCall call)? onConnectStarted;
  void Function(String authKey)? onProvideAuthKey;
  int startScanCalls = 0;
  int clearAuthKeyCalls = 0;
  int disconnectCalls = 0;
  bool pauseDisconnect = false;
  bool failIdentityConfirmation = false;
  bool failConnect = false;
  Completer<void>? _disconnectCompleter;

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
    bool requireConfirmedIdentity = false,
    bool directedExactAddress = false,
    int? attemptGeneration,
    required TuiBackendBindingMaterial? bindingMaterial,
  }) async {
    final call = _ConnectCall(
      address: address,
      name: name,
      profile: profile,
      requireConfirmedIdentity: requireConfirmedIdentity,
      directedExactAddress: directedExactAddress,
      attemptGeneration: attemptGeneration,
      bindingMaterial: bindingMaterial,
    );
    connectCalls.add(call);
    operations.add('connect:$address');
    onConnectStarted?.call(call);
    _publish(_copy(
      connection: TuiBackendConnectionState.connecting,
      activeDeviceAddress: address,
      connectionGeneration: attemptGeneration,
      identityCandidateId: 'classic:${address.replaceAll(':', '')}',
      identityState: TuiBackendIdentityState.provisional,
      identityGeneration: attemptGeneration,
      connectionId: 'connection-${attemptGeneration ?? 0}',
      clearFailure: true,
    ));
    if (failConnect) {
      throw StateError('connect failed');
    }
    onConnect?.call(call);
  }

  @override
  Future<void> provideAuthKey(String authKey) async {
    providedKeys.add(authKey);
    operations.add('provide:$authKey');
    onProvideAuthKey?.call(authKey);
    _publish(_copy(authKeyLoaded: true));
  }

  @override
  Future<void> clearAuthKey() async {
    clearAuthKeyCalls++;
    _publish(_copy(authKeyLoaded: false));
  }

  @override
  Future<void> confirmActiveIdentity({required int attemptGeneration}) async {
    confirmedGenerations.add(attemptGeneration);
    operations.add('confirm:$attemptGeneration');
    if (failIdentityConfirmation) {
      throw StateError('identity confirmation failed');
    }
    _publish(_copy(
      identityState: TuiBackendIdentityState.confirmed,
      identityGeneration: attemptGeneration,
      connectionGeneration: attemptGeneration,
      protocolAuthenticated: true,
      connection: TuiBackendConnectionState.ready,
    ));
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    if (pauseDisconnect) {
      _disconnectCompleter = Completer<void>();
      await _disconnectCompleter!.future;
    }
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
    int? connectionGeneration,
  }) =>
      _publish(_copy(
        connection: connection,
        activeDeviceAddress: activeDeviceAddress,
        connectionId: connectionGeneration == null
            ? null
            : 'connection-$connectionGeneration',
        connectionGeneration: connectionGeneration,
        identityCandidateId: connectionGeneration == null
            ? null
            : 'classic:${activeDeviceAddress.replaceAll(':', '')}',
        identityGeneration: connectionGeneration,
        identityState: connection == TuiBackendConnectionState.ready
            ? TuiBackendIdentityState.confirmed
            : null,
        protocolAuthenticated:
            connection == TuiBackendConnectionState.ready ? true : null,
        clearFailure: true,
      ));

  void publishRecoveryConnection(
    TuiBackendConnectionState connection, {
    required String activeDeviceAddress,
    required int applicationGeneration,
    required int connectionGeneration,
    required String connectionId,
    String? identityCandidateId,
    int? identityGeneration,
  }) =>
      _publish(_copy(
        connection: connection,
        activeDeviceAddress: activeDeviceAddress,
        connectionId: connectionId,
        connectionGeneration: connectionGeneration,
        applicationAttemptGeneration: applicationGeneration,
        identityCandidateId: identityCandidateId ??
            'classic:${activeDeviceAddress.replaceAll(':', '')}',
        identityGeneration: identityGeneration ?? applicationGeneration,
        identityState: connection == TuiBackendConnectionState.ready
            ? TuiBackendIdentityState.confirmed
            : TuiBackendIdentityState.provisional,
        protocolAuthenticated: connection == TuiBackendConnectionState.ready,
        transportConnected: true,
        clearFailure: true,
      ));

  void publishForeignConnection(
    TuiBackendConnectionState connection, {
    required String activeDeviceAddress,
    required String connectionId,
    required int connectionGeneration,
    required int identityGeneration,
  }) =>
      _publish(_copy(
        connection: connection,
        activeDeviceAddress: activeDeviceAddress,
        connectionId: connectionId,
        connectionGeneration: connectionGeneration,
        identityCandidateId: 'classic:foreign',
        identityGeneration: identityGeneration,
        identityState: TuiBackendIdentityState.confirmed,
        protocolAuthenticated: true,
        transportConnected: true,
        clearFailure: true,
      ));

  void publishProtocolReady({required String activeDeviceAddress}) =>
      _publish(_copy(
        connection: TuiBackendConnectionState.authenticating,
        activeDeviceAddress: activeDeviceAddress,
        identityState: TuiBackendIdentityState.provisional,
        protocolAuthenticated: true,
        transportConnected: true,
        clearFailure: true,
      ));

  void publishLifecycle(
    TuiBackendConnectionState connection, {
    required String activeDeviceAddress,
    required bool transportConnected,
    TuiBackendInstallation? installation,
  }) =>
      _publish(_copy(
        connection: connection,
        activeDeviceAddress: activeDeviceAddress,
        transportConnected: transportConnected,
        identityState: connection == TuiBackendConnectionState.ready
            ? TuiBackendIdentityState.confirmed
            : null,
        protocolAuthenticated:
            connection == TuiBackendConnectionState.ready ? true : null,
        installation: installation,
        clearInstallation: installation == null,
        clearFailure: true,
      ));

  void publishFailure(String failureCode) => _publish(_copy(
        connection: TuiBackendConnectionState.disconnected,
        clearActiveDeviceAddress: true,
        transportConnected: false,
        failureCode: failureCode,
      ));

  void publishFailureReady(
    String failureCode, {
    required String activeDeviceAddress,
    required int connectionGeneration,
  }) =>
      _publish(_copy(
        connection: TuiBackendConnectionState.ready,
        activeDeviceAddress: activeDeviceAddress,
        transportConnected: true,
        connectionId: 'connection-$connectionGeneration',
        connectionGeneration: connectionGeneration,
        identityCandidateId:
            'classic:${activeDeviceAddress.replaceAll(':', '')}',
        identityGeneration: connectionGeneration,
        identityState: TuiBackendIdentityState.confirmed,
        protocolAuthenticated: true,
        failureCode: failureCode,
      ));

  void publishUncorrelatedError(Object error) => _controller.addError(error);

  void publishUnscopedDiscovery({
    required List<TuiBackendDevice> devices,
    required bool scanning,
  }) =>
      _publish(TuiBackendSnapshot(
        revision: _snapshot.revision + 1,
        helperState: _snapshot.helperState,
        scanning: scanning,
        transportConnected: false,
        connection: TuiBackendConnectionState.disconnected,
        devices: devices,
        authKeyLoaded: _snapshot.authKeyLoaded,
      ));

  void publishTuplelessDisconnect() => _publish(TuiBackendSnapshot(
        revision: _snapshot.revision + 1,
        helperState: _snapshot.helperState,
        scanning: false,
        transportConnected: false,
        connection: TuiBackendConnectionState.disconnected,
        devices: _snapshot.devices,
        authKeyLoaded: _snapshot.authKeyLoaded,
      ));

  void completeDisconnect() {
    pauseDisconnect = false;
    _disconnectCompleter?.complete();
  }

  void _publish(TuiBackendSnapshot value) {
    _snapshot = value;
    _controller.add(value);
  }

  TuiBackendSnapshot _copy({
    bool? scanning,
    bool? transportConnected,
    TuiBackendConnectionState? connection,
    List<TuiBackendDevice>? devices,
    bool? authKeyLoaded,
    String? activeDeviceAddress,
    bool clearActiveDeviceAddress = false,
    bool clearFailure = false,
    String? failureCode,
    TuiBackendInstallation? installation,
    bool clearInstallation = false,
    TuiBackendIdentityState? identityState,
    String? identityCandidateId,
    int? identityGeneration,
    String? connectionId,
    int? connectionGeneration,
    bool? protocolAuthenticated,
    int? applicationAttemptGeneration,
  }) =>
      TuiBackendSnapshot(
        revision: _snapshot.revision + 1,
        helperState: _snapshot.helperState,
        scanning: scanning ?? _snapshot.scanning,
        transportConnected: transportConnected ?? _snapshot.transportConnected,
        connection: connection ?? _snapshot.connection,
        devices: devices ?? _snapshot.devices,
        authKeyLoaded: authKeyLoaded ?? _snapshot.authKeyLoaded,
        identityCandidateId:
            identityCandidateId ?? _snapshot.identityCandidateId,
        identityState: identityState ?? _snapshot.identityState,
        identityGeneration: identityGeneration ?? _snapshot.identityGeneration,
        connectionId: connectionId ?? _snapshot.connectionId,
        connectionGeneration:
            connectionGeneration ?? _snapshot.connectionGeneration,
        protocolAuthenticated:
            protocolAuthenticated ?? _snapshot.protocolAuthenticated,
        applicationAttemptGeneration: applicationAttemptGeneration ??
            _snapshot.applicationAttemptGeneration,
        activeDeviceAddress: clearActiveDeviceAddress
            ? null
            : (activeDeviceAddress ?? _snapshot.activeDeviceAddress),
        failureCode:
            clearFailure ? null : (failureCode ?? _snapshot.failureCode),
        message: _snapshot.message,
        installation:
            clearInstallation ? null : (installation ?? _snapshot.installation),
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
