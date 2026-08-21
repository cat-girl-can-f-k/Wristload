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
  const eventChannel = EventChannel('wristload/rfcomm/events');
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
    messenger.setMockStreamHandler(eventChannel, null);
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
        'generation': 1,
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
          'generation': 1,
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
    'a reconnect invalidates old writes but serializes the next generation',
    () async {
      final firstWriteStarted = Completer<void>();
      final releaseFirstWrite = Completer<void>();
      final nativeWrites = <int>[];
      var connectGeneration = 0;
      addTearDown(() {
        if (!releaseFirstWrite.isCompleted) releaseFirstWrite.complete();
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'connect') {
          return <String, Object>{
            'address': 'AA:BB:CC:DD:EE:FF',
            'name': 'Xiaomi Smart Band 9',
            'generation': ++connectGeneration,
          };
        }
        if (call.method == 'write') {
          final arguments = call.arguments as Map<Object?, Object?>;
          final bytes = arguments['data']! as Uint8List;
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
      final nextGenerationWrite = transport.rfcommWrite(identifier, [3]);
      await Future<void>.delayed(Duration.zero);
      expect(nativeWrites, [1]);

      releaseFirstWrite.complete();
      await inFlightFailure;
      await queuedFailure;
      await nextGenerationWrite;
      expect(nativeWrites, [1, 3]);
    },
  );

  test(
    'macOS RFCOMM writes for separate devices use independent lanes',
    () async {
      final firstWriteStarted = Completer<void>();
      final releaseFirstWrite = Completer<void>();
      final secondWriteCompleted = Completer<void>();
      final writes = <String>[];
      addTearDown(() {
        if (!releaseFirstWrite.isCompleted) releaseFirstWrite.complete();
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'connect') {
          return <String, Object>{
            'address': 'AA:BB:CC:DD:EE:FF',
            'name': 'Xiaomi Smart Band 9',
            'generation': 1,
          };
        }
        if (call.method == 'write') {
          final arguments = call.arguments as Map<Object?, Object?>;
          final peripheral = arguments['peripheralId']! as String;
          final bytes = arguments['data']! as Uint8List;
          writes.add('$peripheral:${bytes.first}');
          if (bytes.first == 1) {
            firstWriteStarted.complete();
            await releaseFirstWrite.future;
          } else {
            secondWriteCompleted.complete();
          }
        }
        return null;
      });

      final transport = BleTransport();
      final first = UUID.fromString('12345678-90ab-cdef-1234-567890abcdef');
      final second = UUID.fromString('abcdefab-cdef-1234-5678-1234567890ab');
      await transport.connectRfcomm(
        first,
        advertisedName: 'Xiaomi Smart Band 9',
      );
      await transport.connectRfcomm(
        second,
        advertisedName: 'Xiaomi Smart Band 9',
      );

      final firstWrite = transport.rfcommWrite(first, [1]);
      await firstWriteStarted.future;
      await transport.rfcommWrite(second, [2]);
      expect(secondWriteCompleted.isCompleted, isTrue);
      expect(writes, <String>['${first}:1', '${second}:2']);

      releaseFirstWrite.complete();
      await firstWrite;
    },
  );

  test('macOS tagged RX reaches only its owning RFCOMM session', () async {
    MockStreamHandlerEventSink? nativeEvents;
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (_, events) => nativeEvents = events),
    );
    final transport = BleTransport();
    final first = UUID.fromString('12345678-90ab-cdef-1234-567890abcdef');
    final second = UUID.fromString('abcdefab-cdef-1234-5678-1234567890ab');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'connect') return null;
      return <String, Object>{
        'address': 'AA:BB:CC:DD:EE:FF',
        'name': 'Xiaomi Smart Band 9',
        'generation': 1,
      };
    });
    await transport.connectRfcomm(first, advertisedName: 'Xiaomi Smart Band 9');
    await transport.connectRfcomm(
      second,
      advertisedName: 'Xiaomi Smart Band 9',
    );
    final firstPackets = <Uint8List>[];
    final secondPackets = <Uint8List>[];
    final firstSubscription = transport
        .rfcommDataFor(first)
        .listen(firstPackets.add);
    final secondSubscription = transport
        .rfcommDataFor(second)
        .listen(secondPackets.add);
    addTearDown(firstSubscription.cancel);
    addTearDown(secondSubscription.cancel);
    addTearDown(transport.disposeRfcommStream);

    transport.listenRfcommData();
    await Future<void>.delayed(Duration.zero);
    expect(nativeEvents, isNotNull);

    nativeEvents!.success(<String, Object>{
      'kind': 'data',
      'event': 'read',
      'peripheral': second.toString().toUpperCase(),
      'generation': 1,
      'wireHex': '0A 0B',
    });
    await Future<void>.delayed(Duration.zero);

    expect(firstPackets, isEmpty);
    expect(secondPackets, hasLength(1));
    expect(secondPackets.single, Uint8List.fromList(<int>[0x0A, 0x0B]));
  });

  test('macOS adopts a new native generation before connect returns', () async {
    MockStreamHandlerEventSink? nativeEvents;
    final connectStarted = Completer<void>();
    final connectReply = Completer<Object?>();
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (_, events) => nativeEvents = events),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'connect') return null;
      if (!connectStarted.isCompleted) connectStarted.complete();
      return connectReply.future;
    });
    final transport = BleTransport();
    final device = UUID.fromString('12345678-90ab-cdef-1234-567890abcdef');
    final packets = <Uint8List>[];
    final subscription = transport.rfcommDataFor(device).listen(packets.add);
    addTearDown(subscription.cancel);
    addTearDown(transport.disposeRfcommStream);

    transport.listenRfcommData();
    await Future<void>.delayed(Duration.zero);
    expect(nativeEvents, isNotNull);

    final connecting = transport.connectRfcomm(
      device,
      advertisedName: 'Xiaomi Smart Band 9',
    );
    await connectStarted.future;
    nativeEvents!.success(<String, Object>{
      'kind': 'native',
      'event': 'sdp_started',
      'peripheral': device.toString(),
      'generation': 4,
    });
    nativeEvents!.success(<String, Object>{
      'kind': 'data',
      'event': 'read',
      'peripheral': device.toString(),
      'generation': 4,
      'wireHex': '0A',
    });
    await Future<void>.delayed(Duration.zero);

    expect(packets, hasLength(1));
    expect(packets.single, Uint8List.fromList(<int>[0x0A]));
    connectReply.complete(<String, Object>{
      'address': 'AA:BB:CC:DD:EE:FF',
      'name': 'Xiaomi Smart Band 9',
      'generation': 4,
    });
    await connecting;
  });

  test('macOS drops late packets from a previous native generation', () async {
    MockStreamHandlerEventSink? nativeEvents;
    var generation = 0;
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (_, events) => nativeEvents = events),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'connect') {
        return <String, Object>{
          'address': 'AA:BB:CC:DD:EE:FF',
          'name': 'Xiaomi Smart Band 9',
          'generation': ++generation,
        };
      }
      return null;
    });
    final transport = BleTransport();
    final device = UUID.fromString('12345678-90ab-cdef-1234-567890abcdef');
    final packets = <Uint8List>[];
    final subscription = transport.rfcommDataFor(device).listen(packets.add);
    addTearDown(subscription.cancel);
    addTearDown(transport.disposeRfcommStream);

    transport.listenRfcommData();
    await Future<void>.delayed(Duration.zero);
    expect(nativeEvents, isNotNull);

    await transport.connectRfcomm(
      device,
      advertisedName: 'Xiaomi Smart Band 9',
    );
    nativeEvents!.success(<String, Object>{
      'kind': 'data',
      'event': 'read',
      'peripheral': device.toString(),
      'generation': 1,
      'wireHex': '01',
    });
    await Future<void>.delayed(Duration.zero);

    await transport.disconnectRfcomm(device);
    await transport.connectRfcomm(
      device,
      advertisedName: 'Xiaomi Smart Band 9',
    );
    nativeEvents!.success(<String, Object>{
      'kind': 'data',
      'event': 'read',
      'peripheral': device.toString(),
      'generation': 1,
      'wireHex': '02',
    });
    nativeEvents!.success(<String, Object>{
      'kind': 'data',
      'event': 'read',
      'peripheral': device.toString(),
      'generation': 2,
      'wireHex': '03',
    });
    await Future<void>.delayed(Duration.zero);

    expect(packets, hasLength(2));
    expect(packets[0], Uint8List.fromList(<int>[0x01]));
    expect(packets[1], Uint8List.fromList(<int>[0x03]));
  });

  test('macOS tagged close reaches only its owning RFCOMM session', () async {
    MockStreamHandlerEventSink? nativeEvents;
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(onListen: (_, events) => nativeEvents = events),
    );
    final transport = BleTransport();
    final first = UUID.fromString('12345678-90ab-cdef-1234-567890abcdef');
    final second = UUID.fromString('abcdefab-cdef-1234-5678-1234567890ab');
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'connect') return null;
      return <String, Object>{
        'address': 'AA:BB:CC:DD:EE:FF',
        'name': 'Xiaomi Smart Band 9',
        'generation': 1,
      };
    });
    await transport.connectRfcomm(first, advertisedName: 'Xiaomi Smart Band 9');
    await transport.connectRfcomm(
      second,
      advertisedName: 'Xiaomi Smart Band 9',
    );
    final firstClosed = <RfcommClosedEvent>[];
    final secondClosed = <RfcommClosedEvent>[];
    final firstSubscription = transport
        .rfcommClosedFor(first)
        .listen(firstClosed.add);
    final secondSubscription = transport
        .rfcommClosedFor(second)
        .listen(secondClosed.add);
    addTearDown(firstSubscription.cancel);
    addTearDown(secondSubscription.cancel);
    addTearDown(transport.disposeRfcommStream);

    transport.listenRfcommData();
    await Future<void>.delayed(Duration.zero);
    expect(nativeEvents, isNotNull);

    nativeEvents!.success(<String, Object>{
      'kind': 'closed',
      'event': 'closed',
      'peripheral': first.toString().toUpperCase(),
      'generation': 1,
      'code': 'rfcomm_closed',
      'message': 'Remote close',
    });
    await Future<void>.delayed(Duration.zero);

    expect(firstClosed, hasLength(1));
    expect(firstClosed.single.peripheralId, first.toString().toUpperCase());
    expect(firstClosed.single.code, 'rfcomm_closed');
    expect(firstClosed.single.generation, 1);
    expect(secondClosed, isEmpty);
  });

  test(
    'macOS rejects untagged RX from device-scoped RFCOMM sessions',
    () async {
      MockStreamHandlerEventSink? nativeEvents;
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (_, events) => nativeEvents = events,
        ),
      );
      final transport = BleTransport();
      final device = UUID.fromString('12345678-90ab-cdef-1234-567890abcdef');
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != 'connect') return null;
        return <String, Object>{
          'address': 'AA:BB:CC:DD:EE:FF',
          'name': 'Xiaomi Smart Band 9',
          'generation': 1,
        };
      });
      await transport.connectRfcomm(
        device,
        advertisedName: 'Xiaomi Smart Band 9',
      );
      final packets = <Uint8List>[];
      final subscription = transport.rfcommDataFor(device).listen(packets.add);
      addTearDown(subscription.cancel);
      addTearDown(transport.disposeRfcommStream);

      transport.listenRfcommData();
      await Future<void>.delayed(Duration.zero);
      expect(nativeEvents, isNotNull);

      nativeEvents!.success(<String, Object>{
        'kind': 'data',
        'event': 'read',
        'wireHex': '0A 0B',
      });
      await Future<void>.delayed(Duration.zero);

      expect(packets, isEmpty);
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
