import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wristload/application/device_controller.dart';
import 'package:wristload/domain/auth_key_binding.dart';
import 'package:wristload/platform/ble_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStoreChannel = MethodChannel('wristload/secure_store');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> secureStoreCalls;
  Future<Object?> Function(MethodCall call)? secureStoreOverride;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    SharedPreferences.setMockInitialValues({});
    secureStoreCalls = <MethodCall>[];
    secureStoreOverride = null;
    messenger.setMockMethodCallHandler(secureStoreChannel, (call) async {
      secureStoreCalls.add(call);
      final override = secureStoreOverride;
      if (override != null) return override(call);
      switch (call.method) {
        case 'read':
        case 'readFor':
          return null;
        case 'write':
        case 'writeFor':
        case 'delete':
        case 'deleteFor':
          return null;
      }
      throw MissingPluginException('Unexpected secure store call: ${call.method}');
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(secureStoreChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('deleting a saved device leaves the active connection untouched',
      () async {
    final transport = _SavedDeviceTransport();
    final device = _TestPeripheral(
      UUID.fromString('12345678-90ab-cdef-1234-567890abcdef'),
    );
    final controller = DeviceController(transport: transport)
      ..connectedDevice = device
      ..connectedDeviceName = 'Xiaomi Smart Band 10'
      ..authKey = '0123456789abcdef0123456789abcdef'
      ..sessionReady = true;
    addTearDown(controller.dispose);

    await controller.rememberAuthKeyBinding(
      id: device.uuid.toString(),
      name: 'Xiaomi Smart Band 10',
      key: '0123456789abcdef0123456789abcdef',
    );

    expect(await controller.deleteSavedDevice(device.uuid), isTrue);

    expect(controller.authKey, isNull);
    expect(controller.authKeyBindings, isEmpty);
    expect(await AuthKeyBindingStore().read(), isEmpty);
    expect(transport.forgottenIdentity, [device.uuid.toString()]);
    expect(transport.disconnectCalls, isEmpty);
    expect(controller.connectedDevice, same(device));
    expect(controller.sessionReady, isTrue);
  });

  test('deleting a historical device preserves the active device credential',
      () async {
    const activeKey = '0123456789abcdef0123456789abcdef';
    const historicalKey = 'fedcba9876543210fedcba9876543210';
    final transport = _SavedDeviceTransport();
    final activeDevice = _TestPeripheral(
      UUID.fromString('12345678-90ab-cdef-1234-567890abcdef'),
    );
    final historicalDevice = _TestPeripheral(
      UUID.fromString('abcdef12-3456-7890-abcd-ef1234567890'),
    );
    final controller = DeviceController(transport: transport)
      ..connectedDevice = activeDevice
      ..connectedDeviceName = 'Xiaomi Smart Band 10'
      ..authKey = activeKey
      ..sessionReady = true;
    addTearDown(controller.dispose);

    await controller.rememberAuthKeyBinding(
      id: activeDevice.uuid.toString(),
      name: '当前设备',
      key: activeKey,
    );
    await controller.rememberAuthKeyBinding(
      id: historicalDevice.uuid.toString(),
      name: '历史设备',
      key: historicalKey,
    );
    secureStoreCalls.clear();

    expect(
      await controller.deleteSavedDeviceById(historicalDevice.uuid.toString()),
      isTrue,
    );

    expect(controller.authKey, activeKey);
    expect(controller.connectedDevice, same(activeDevice));
    expect(controller.sessionReady, isTrue);
    expect(
      controller.authKeyBindings.map((binding) => binding.id).toList(),
      [activeDevice.uuid.toString()],
    );
    expect(
      secureStoreCalls.where(
        (call) =>
            call.method == 'deleteFor' &&
            call.arguments == historicalDevice.uuid.toString(),
      ),
      hasLength(1),
    );
    expect(
      secureStoreCalls.where((call) => call.method == 'delete'),
      isEmpty,
    );
    expect(transport.forgottenIdentity, [historicalDevice.uuid.toString()]);
  });

  test('manual authkey stays in memory until device authentication succeeds',
      () async {
    final controller = DeviceController(transport: _SavedDeviceTransport());
    addTearDown(controller.dispose);

    expect(
      await controller.setAuthKey(
        '0123456789abcdef0123456789abcdef',
        deviceId: '12345678-90ab-cdef-1234-567890abcdef',
      ),
      isTrue,
    );

    expect(controller.hasAuthKey, isTrue);
    expect(
      secureStoreCalls.where(
        (call) => call.method == 'write' || call.method == 'writeFor',
      ),
      isEmpty,
    );
  });

  test('queued delete wins over an in-flight saved-device write', () async {
    const key = '0123456789abcdef0123456789abcdef';
    final writeStarted = Completer<void>();
    final allowWrite = Completer<void>();
    final storedKeys = <String, String>{};
    final transport = _SavedDeviceTransport();
    final device = _TestPeripheral(
      UUID.fromString('12345678-90ab-cdef-1234-567890abcdef'),
    );
    secureStoreOverride = (call) async {
      switch (call.method) {
        case 'writeFor':
          final arguments = Map<Object?, Object?>.from(call.arguments as Map);
          final id = arguments['id']! as String;
          final value = arguments['value']! as String;
          if (!writeStarted.isCompleted) writeStarted.complete();
          await allowWrite.future;
          storedKeys[id] = value;
          return null;
        case 'deleteFor':
          storedKeys.remove(call.arguments as String);
          return null;
        case 'readFor':
          return storedKeys[call.arguments as String];
        case 'read':
        case 'write':
        case 'delete':
          return null;
      }
      throw MissingPluginException('Unexpected secure store call: ' + call.method);
    };
    final controller = DeviceController(transport: transport);
    addTearDown(controller.dispose);

    final save = controller.rememberAuthKeyBinding(
      id: device.uuid.toString(),
      name: 'Xiaomi Smart Band 10',
      key: key,
    );
    await writeStarted.future;
    final delete = controller.deleteSavedDevice(device.uuid);

    allowWrite.complete();
    await save;
    expect(await delete, isTrue);

    expect(await controller.readAuthKeyFor(device.uuid.toString()), isNull);
    expect(controller.authKeyBindings, isEmpty);
    expect(await AuthKeyBindingStore().read(), isEmpty);
    expect(
      secureStoreCalls.map((call) => call.method),
      containsAllInOrder(<String>['writeFor', 'deleteFor']),
    );
    expect(transport.forgottenIdentity, <String>[device.uuid.toString()]);
  });

  test('saving a historical binding does not change the active session key',
      () async {
    const activeKey = '0123456789abcdef0123456789abcdef';
    const historicalKey = 'fedcba9876543210fedcba9876543210';
    final activeDevice = _TestPeripheral(
      UUID.fromString('12345678-90ab-cdef-1234-567890abcdef'),
    );
    final historicalDevice = _TestPeripheral(
      UUID.fromString('abcdef12-3456-7890-abcd-ef1234567890'),
    );
    final controller = DeviceController(transport: _SavedDeviceTransport())
      ..connectedDevice = activeDevice
      ..connectedDeviceName = '当前设备'
      ..authKey = activeKey
      ..sessionReady = true;
    addTearDown(controller.dispose);

    await controller.rememberAuthKeyBinding(
      id: historicalDevice.uuid.toString(),
      name: '历史设备',
      key: historicalKey,
    );

    expect(controller.authKey, activeKey);
    expect(controller.connectedDevice, same(activeDevice));
    expect(controller.sessionReady, isTrue);
  });
}

final class _SavedDeviceTransport extends BleTransport {
  final List<String> forgottenIdentity = [];
  final List<String> disconnectCalls = [];

  @override
  Future<void> forgetRfcommIdentity(UUID uuid) async {
    forgottenIdentity.add(uuid.toString());
  }

  @override
  Future<void> disconnectRfcomm(UUID uuid) async {
    disconnectCalls.add('rfcomm:${uuid.toString()}');
  }

  @override
  Future<void> disconnect(Peripheral peripheral) async {
    disconnectCalls.add('gatt:${peripheral.uuid.toString()}');
  }
}

final class _TestPeripheral implements Peripheral {
  const _TestPeripheral(this.uuid);

  @override
  final UUID uuid;
}
