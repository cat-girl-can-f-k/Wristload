import 'dart:async';

import 'package:bluetooth_low_energy_windows/src/api.g.dart';
import 'package:bluetooth_low_energy_windows/src/central_manager_impl.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const initializeName =
      'dev.flutter.pigeon.bluetooth_low_energy_windows.'
      'CentralManagerHostApi.initialize';
  const stateName =
      'dev.flutter.pigeon.bluetooth_low_energy_windows.'
      'CentralManagerHostApi.getState';
  const startName =
      'dev.flutter.pigeon.bluetooth_low_energy_windows.'
      'CentralManagerHostApi.startDiscovery';
  const codec = CentralManagerHostApi.pigeonChannelCodec;
  const initializeChannel = BasicMessageChannel<Object?>(initializeName, codec);
  const stateChannel = BasicMessageChannel<Object?>(stateName, codec);
  const startChannel = BasicMessageChannel<Object?>(startName, codec);

  late TestDefaultBinaryMessenger messenger;

  setUp(() {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockDecodedMessageHandler<Object?>(
      stateChannel,
      (_) async => <Object?>[BluetoothLowEnergyStateArgs.on],
    );
  });

  tearDown(() {
    CentralManagerFlutterApi.setUp(null);
    messenger.setMockDecodedMessageHandler<Object?>(initializeChannel, null);
    messenger.setMockDecodedMessageHandler<Object?>(stateChannel, null);
    messenger.setMockDecodedMessageHandler<Object?>(startChannel, null);
  });

  test(
    'first discovery waits until native watcher initialization completes',
    () async {
      final initializationGate = Completer<void>();
      var initializationCompleted = false;
      var startCalled = false;
      var startRacedInitialization = false;

      messenger.setMockDecodedMessageHandler<Object?>(initializeChannel, (
        _,
      ) async {
        await initializationGate.future;
        initializationCompleted = true;
        return <Object?>[null];
      });
      messenger.setMockDecodedMessageHandler<Object?>(startChannel, (_) async {
        startCalled = true;
        startRacedInitialization = !initializationCompleted;
        return <Object?>[null];
      });

      final manager = CentralManagerImpl();
      final discovery = manager.startDiscovery();
      await Future<void>.delayed(Duration.zero);

      expect(startCalled, isFalse);
      initializationGate.complete();
      await discovery;

      expect(startCalled, isTrue);
      expect(startRacedInitialization, isFalse);
    },
  );

  test('initialization failure prevents discovery from starting', () async {
    var startCalled = false;
    messenger.setMockDecodedMessageHandler<Object?>(
      initializeChannel,
      (_) async => throw StateError('watcher initialization failed'),
    );
    messenger.setMockDecodedMessageHandler<Object?>(startChannel, (_) async {
      startCalled = true;
      return <Object?>[null];
    });

    final manager = CentralManagerImpl();

    await expectLater(manager.startDiscovery(), throwsA(isA<StateError>()));
    expect(startCalled, isFalse);
  });
}
