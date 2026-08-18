import 'dart:async';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wristload/application/device_controller.dart';
import 'package:wristload/domain/auth_key_binding.dart';
import 'package:wristload/domain/last_device_store.dart';
import 'package:wristload/platform/ble_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('wristload/rfcomm');
  const permissionChannel = MethodChannel('wristload/bluetooth_permission');
  const secureStoreChannel = MethodChannel('wristload/secure_store');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(permissionChannel, null);
    messenger.setMockMethodCallHandler(secureStoreChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('passes the complete Darwin identity to pair and connect', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'confirmIdentity') return null;
      return <String, Object>{
        'address': 'AA:BB:CC:DD:EE:FF',
        'name': 'Xiaomi Smart Band 9',
      };
    });
    final transport = BleTransport();
    final identifier = UUID.fromString('12345678-90ab-cdef-1234-567890abcdef');

    expect(
      await transport.pairDevice(
        identifier,
        advertisedName: ' Xiaomi Smart Band 9 ',
      ),
      'AA:BB:CC:DD:EE:FF',
    );
    expect(
      await transport.connectRfcomm(
        identifier,
        advertisedName: 'Xiaomi Smart Band 9',
      ),
      'AA:BB:CC:DD:EE:FF',
    );
    await transport.confirmRfcommIdentity(
      identifier,
      advertisedName: 'Xiaomi Smart Band 9',
    );

    expect(calls.map((call) => call.method), [
      'pair',
      'connect',
      'confirmIdentity',
    ]);
    for (final call in calls) {
      final identity = call.arguments as Map<Object?, Object?>;
      expect(identity['peripheralId'], '12345678-90ab-cdef-1234-567890abcdef');
      expect(identity['name'], 'Xiaomi Smart Band 9');
      expect(identity.containsKey('address'), isFalse);
    }
  });

  test(
    'requires an advertised name before invoking native macOS code',
    () async {
      var invoked = false;
      messenger.setMockMethodCallHandler(channel, (_) async {
        invoked = true;
        return null;
      });
      final transport = BleTransport();
      final identifier = UUID.fromString(
        '12345678-90ab-cdef-1234-567890abcdef',
      );

      await expectLater(
        transport.pairDevice(identifier),
        throwsA(isA<ArgumentError>()),
      );
      expect(invoked, isFalse);
    },
  );

  test('forgets only the saved Darwin-to-classic identity mapping', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final transport = BleTransport();
    final identifier = UUID.fromString('12345678-90ab-cdef-1234-567890abcdef');

    await transport.forgetRfcommIdentity(identifier);

    expect(received?.method, 'forgetIdentity');
    expect(received?.arguments, <String, Object>{
      'peripheralId': '12345678-90ab-cdef-1234-567890abcdef',
    });
  });

  for (final status in <BluetoothAuthorizationStatus>[
    BluetoothAuthorizationStatus.denied,
    BluetoothAuthorizationStatus.restricted,
  ]) {
    test(
      'retries ${status.name} macOS authorization once before settings state',
      () async {
        final calls = <MethodCall>[];
        messenger.setMockMethodCallHandler(permissionChannel, (call) async {
          calls.add(call);
          return status.name;
        });
        final controller = DeviceController();
        addTearDown(controller.dispose);

        await controller.bluetoothInitializationReady;

        expect(calls.map((call) => call.method), <String>[
          'requestBluetoothAuthorization',
          'requestBluetoothAuthorization',
          'getBluetoothAuthorizationStatus',
        ]);
        expect(controller.macOSBluetoothAuthorization, status);
        expect(controller.macOSBluetoothPrivacySettingsRequired, isTrue);
      },
    );
  }

  test(
    'uses the final macOS authorization status after the logical retry',
    () async {
      var requestCount = 0;
      messenger.setMockMethodCallHandler(permissionChannel, (call) async {
        if (call.method == 'requestBluetoothAuthorization') {
          requestCount++;
          return 'denied';
        }
        if (call.method == 'getBluetoothAuthorizationStatus') {
          return 'authorized';
        }
        throw PlatformException(code: 'unexpected_method');
      });
      final controller = DeviceController();
      addTearDown(controller.dispose);

      await controller.bluetoothInitializationReady;

      expect(requestCount, 2);
      expect(
        controller.macOSBluetoothAuthorization,
        BluetoothAuthorizationStatus.authorized,
      );
      expect(controller.macOSBluetoothPrivacySettingsRequired, isFalse);
    },
  );

  test(
    'an authorized macOS TCC result does not let a stale plugin state block scanning',
    () async {
      final transport = _MacOSBluetoothTestTransport(
        pluginState: BluetoothLowEnergyState.unauthorized,
        authorization: BluetoothAuthorizationStatus.authorized,
      );
      final controller = DeviceController(transport: transport);
      addTearDown(controller.dispose);

      await controller.bluetoothInitializationReady;

      expect(
        controller.macOSBluetoothAuthorization,
        BluetoothAuthorizationStatus.authorized,
      );
      expect(controller.macOSBluetoothPrivacySettingsRequired, isFalse);
      expect(controller.bluetoothUnavailable, isFalse);
      expect(controller.canScan, isTrue);
      expect(controller.bluetoothStateMessage, isNot(contains('权限未授权')));

      await controller.beginScan();

      expect(transport.startScanCalls, 1);
    },
  );

  test(
    'macOS initializes native TCC before constructing the BLE plugin manager',
    () async {
      final transport = _MacOSBluetoothTestTransport(
        pluginState: BluetoothLowEnergyState.poweredOn,
        authorization: BluetoothAuthorizationStatus.authorized,
      );
      final controller = DeviceController(transport: transport);
      addTearDown(controller.dispose);

      await controller.bluetoothInitializationReady;

      expect(transport.initializationOperations, <String>[
        'requestAuthorization',
        'getAuthorizationStatus',
        'stateChanged',
        'bluetoothState',
      ]);
    },
  );

  test(
    'a denied macOS TCC result blocks scanning even when the plugin reports powered on',
    () async {
      final transport = _MacOSBluetoothTestTransport(
        pluginState: BluetoothLowEnergyState.poweredOn,
        authorization: BluetoothAuthorizationStatus.denied,
      );
      final controller = DeviceController(transport: transport);
      addTearDown(controller.dispose);

      await controller.bluetoothInitializationReady;

      expect(controller.bluetoothState, BluetoothLowEnergyState.poweredOn);
      expect(controller.macOSBluetoothPrivacySettingsRequired, isTrue);
      expect(controller.bluetoothUnavailable, isTrue);
      expect(controller.canScan, isFalse);
      expect(controller.bluetoothStateMessage, contains('权限未授权'));

      await controller.beginScan();

      expect(transport.startScanCalls, 0);
    },
  );

  test(
    'refreshes macOS TCC after returning from settings without scanning or reconnecting',
    () async {
      final transport = _MacOSBluetoothTestTransport(
        pluginState: BluetoothLowEnergyState.poweredOn,
        authorization: BluetoothAuthorizationStatus.denied,
      );
      final controller = DeviceController(transport: transport);
      addTearDown(controller.dispose);

      await controller.bluetoothInitializationReady;
      controller.error = controller.bluetoothStateMessage;
      final operationCountBeforeRefresh =
          transport.initializationOperations.length;
      transport.authorization = BluetoothAuthorizationStatus.authorized;

      await controller.refreshMacOSBluetoothAuthorization();

      expect(
        controller.macOSBluetoothAuthorization,
        BluetoothAuthorizationStatus.authorized,
      );
      expect(controller.macOSBluetoothPrivacySettingsRequired, isFalse);
      expect(controller.canScan, isTrue);
      expect(controller.error, isNull);
      expect(transport.startScanCalls, 0);
      expect(
        transport.initializationOperations.skip(operationCountBeforeRefresh),
        <String>['getAuthorizationStatus'],
      );
    },
  );

  test(
    'does not treat an unresolved macOS authorization prompt as a denial',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(permissionChannel, (call) async {
        calls.add(call);
        return 'notDetermined';
      });
      final controller = DeviceController();
      addTearDown(controller.dispose);

      await controller.bluetoothInitializationReady;

      expect(calls.map((call) => call.method), <String>[
        'requestBluetoothAuthorization',
        'getBluetoothAuthorizationStatus',
      ]);
      expect(
        controller.macOSBluetoothAuthorization,
        BluetoothAuthorizationStatus.notDetermined,
      );
      expect(controller.macOSBluetoothPrivacySettingsRequired, isFalse);
    },
  );

  test(
    'startup auto-connect waits for macOS authorization before touching a saved device',
    () async {
      const id = '12345678-90ab-cdef-1234-567890abcdef';
      const key = '0123456789abcdef0123456789abcdef';
      final binding = AuthKeyBinding(
        id: id,
        name: 'Xiaomi Smart Band 9',
        uuid: id,
        updatedAt: DateTime.utc(2026, 8, 17),
      );
      await AuthKeyBindingStore().write([binding]);
      await LastDeviceStore().write(id: id, name: binding.name);
      final permissionRequestStarted = Completer<void>();
      final permissionDecision = Completer<Object?>();
      final secureStoreCalls = <MethodCall>[];
      final rfcommCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(permissionChannel, (call) async {
        switch (call.method) {
          case 'requestBluetoothAuthorization':
            if (!permissionRequestStarted.isCompleted) {
              permissionRequestStarted.complete();
            }
            return permissionDecision.future;
          case 'getBluetoothAuthorizationStatus':
            return 'authorized';
        }
        throw PlatformException(code: 'unexpected_permission_method');
      });
      messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
        secureStoreCalls.add(call);
        if (call.method == 'readFor' && call.arguments == id) return key;
        return null;
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        rfcommCalls.add(call);
        return <String, Object>{
          'address': 'AA:BB:CC:DD:EE:FF',
          'name': 'Xiaomi Smart Band 9',
        };
      });
      final controller = DeviceController();
      addTearDown(controller.dispose);

      await permissionRequestStarted.future;
      final reconnect = controller.autoConnectLastDevice();
      await Future<void>.delayed(Duration.zero);
      expect(
        secureStoreCalls.where((call) => call.method == 'readFor'),
        isEmpty,
      );
      expect(rfcommCalls, isEmpty);

      permissionDecision.complete('authorized');
      expect(await reconnect, isTrue);
      expect(
        secureStoreCalls.where((call) => call.method == 'readFor'),
        hasLength(1),
      );
    },
  );

  test(
    'a reconnect does not wait for writes queued by the old session',
    () async {
      final firstWriteStarted = Completer<void>();
      final releaseFirstWrite = Completer<void>();
      final nativeWrites = <int>[];
      addTearDown(() {
        if (!releaseFirstWrite.isCompleted) releaseFirstWrite.complete();
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'connect') {
          return <String, Object>{
            'address': 'AA:BB:CC:DD:EE:FF',
            'name': 'Xiaomi Smart Band 9',
          };
        }
        if (call.method == 'write') {
          final bytes = call.arguments as Uint8List;
          nativeWrites.add(bytes.first);
          if (bytes.first == 1) {
            firstWriteStarted.complete();
            await releaseFirstWrite.future;
          }
          return null;
        }
        return null;
      });

      final transport = BleTransport();
      final identifier = UUID.fromString(
        '12345678-90ab-cdef-1234-567890abcdef',
      );
      await transport.connectRfcomm(
        identifier,
        advertisedName: 'Xiaomi Smart Band 9',
      );

      final inFlight = transport.rfcommWrite(identifier, [1]);
      await firstWriteStarted.future;
      final queued = transport.rfcommWrite(identifier, [2]);
      final inFlightFailure = expectLater(inFlight, throwsStateError);
      final queuedFailure = expectLater(queued, throwsStateError);

      await transport.connectRfcomm(
        identifier,
        advertisedName: 'Xiaomi Smart Band 9',
      );
      await transport.rfcommWrite(identifier, [3]);
      expect(nativeWrites, [1, 3]);

      releaseFirstWrite.complete();
      await inFlightFailure;
      await queuedFailure;
      expect(nativeWrites, [1, 3]);
    },
  );
}

class _MacOSBluetoothTestTransport extends BleTransport {
  _MacOSBluetoothTestTransport({
    required this.pluginState,
    required this.authorization,
  });

  final BluetoothLowEnergyState pluginState;
  BluetoothAuthorizationStatus authorization;
  final List<String> initializationOperations = <String>[];
  final StreamController<BluetoothLowEnergyStateChangedEventArgs>
  _stateChanges =
      StreamController<BluetoothLowEnergyStateChangedEventArgs>.broadcast();
  int startScanCalls = 0;

  @override
  BluetoothLowEnergyState get bluetoothState {
    initializationOperations.add('bluetoothState');
    return pluginState;
  }

  @override
  Stream<BluetoothLowEnergyStateChangedEventArgs> get bluetoothStateChanged {
    initializationOperations.add('stateChanged');
    return _stateChanges.stream;
  }

  @override
  Stream<DiscoveredEventArgs> get discoveries =>
      const Stream<DiscoveredEventArgs>.empty();

  @override
  Future<BluetoothAuthorizationStatus>
  requestMacOSBluetoothAuthorization() async {
    initializationOperations.add('requestAuthorization');
    return authorization;
  }

  @override
  Future<BluetoothAuthorizationStatus>
  getMacOSBluetoothAuthorizationStatus() async {
    initializationOperations.add('getAuthorizationStatus');
    return authorization;
  }

  @override
  Future<void> startScan() async {
    startScanCalls++;
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> disposeRfcommStream() async {
    await _stateChanges.close();
  }
}
