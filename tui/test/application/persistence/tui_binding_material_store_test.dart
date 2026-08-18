import 'dart:convert';

import 'package:test/test.dart';
import 'package:wristload_tui/src/application/persistence/tui_binding_material_store.dart';

void main() {
  group('TuiBindingMaterial', () {
    test('preserves explicit values while redacting diagnostic text', () {
      final material = TuiBindingMaterial(
        appDeviceId: '  app-device-7  ',
        oob: '  oob-token-7  ',
      );

      expect(material.appDeviceId, 'app-device-7');
      expect(material.oob, 'oob-token-7');
      expect(material.hasOob, isTrue);
      expect(material.toString(), isNot(contains('app-device-7')));
      expect(material.toString(), isNot(contains('oob-token-7')));
    });

    test('does not create OOB material from an empty value', () {
      final material = TuiBindingMaterial(
        appDeviceId: 'app-device-7',
        oob: '   ',
      );

      expect(material.oob, isNull);
      expect(material.hasOob, isFalse);
    });

    test('rejects empty, control, and oversized identity values', () {
      expect(() => normalizeTuiAppDeviceId('   '), throwsFormatException);
      expect(
        () => normalizeTuiAppDeviceId(
          'app' + String.fromCharCode(10) + 'device',
        ),
        throwsFormatException,
      );
      expect(
        () => normalizeTuiBindingOob('oob' + String.fromCharCode(0)),
        throwsFormatException,
      );
      expect(() => normalizeTuiAppDeviceId('x' * 257), throwsFormatException);
    });
  });

  group('InMemoryTuiBindingMaterialStore', () {
    test('normalizes MAC aliases and keeps records independently scoped',
        () async {
      final store = InMemoryTuiBindingMaterialStore();

      await store.saveBindingMaterial(
        'aa-bb-cc-dd-ee-ff',
        appDeviceId: 'app-device-a',
        oob: 'oob-a',
      );
      await store.saveBindingMaterial(
        'AA:BB:CC:DD:EE:00',
        appDeviceId: 'app-device-b',
      );
      await store.saveBindingMaterial(
        'AA:BB:CC:DD:EE:FF',
        appDeviceId: 'app-device-a-replaced',
        oob: 'oob-a-replaced',
      );

      expect(
        await store.readBindingMaterial('AA-BB-CC-DD-EE-FF'),
        TuiBindingMaterial(
          appDeviceId: 'app-device-a-replaced',
          oob: 'oob-a-replaced',
        ),
      );
      expect(
        await store.readBindingMaterial('aa:bb:cc:dd:ee:00'),
        TuiBindingMaterial(appDeviceId: 'app-device-b'),
      );
      expect(await store.readBindingMaterial('11:22:33:44:55:66'), isNull);

      await store.removeBindingMaterial('aa-bb-cc-dd-ee-ff');
      await store.removeBindingMaterial('AA:BB:CC:DD:EE:FF');
      expect(await store.readBindingMaterial('AA:BB:CC:DD:EE:FF'), isNull);
      expect(await store.readBindingMaterial('AA:BB:CC:DD:EE:00'), isNotNull);
    });

    test('never substitutes a MAC address for missing appDeviceId', () async {
      final store = InMemoryTuiBindingMaterialStore();

      expect(await store.readBindingMaterial('AA:BB:CC:DD:EE:FF'), isNull);
    });
  });

  group('MacKeychainTuiBindingMaterialStore', () {
    const appDeviceId = 'app-device-7';
    const oob = 'oob-token-7';
    final calls = <List<String>>[];

    setUp(calls.clear);

    test('uses a dedicated service and normalized account for a round trip',
        () async {
      String? savedPayload;
      final store = MacKeychainTuiBindingMaterialStore(
        commandRunner: (arguments) async {
          calls.add(List<String>.from(arguments));
          if (arguments.first == 'add-generic-password') {
            savedPayload = arguments.last;
          }
          if (arguments.first == 'find-generic-password') {
            return TuiBindingKeychainCommandResult(
              exitCode: 0,
              stdout: '$savedPayload\n',
            );
          }
          return const TuiBindingKeychainCommandResult(exitCode: 0);
        },
      );

      await store.saveBindingMaterial(
        'aa-bb-cc-dd-ee-ff',
        appDeviceId: appDeviceId,
        oob: oob,
      );
      final loaded = await store.readBindingMaterial('AA:BB:CC:DD:EE:FF');

      expect(
        loaded,
        TuiBindingMaterial(appDeviceId: appDeviceId, oob: oob),
      );
      expect(calls[0].first, 'add-generic-password');
      expect(
        calls[0][calls[0].indexOf('-s') + 1],
        MacKeychainTuiBindingMaterialStore.defaultServiceName,
      );
      expect(calls[0][calls[0].indexOf('-a') + 1], 'AA:BB:CC:DD:EE:FF');
      expect(
        MacKeychainTuiBindingMaterialStore.defaultServiceName,
        isNot('com.anemo.wristload.tui.authkey'),
      );
      final payload = jsonDecode(calls[0].last) as Map<String, dynamic>;
      expect(payload.keys.toSet(), {'version', 'appDeviceId', 'oob'});
      expect(payload['appDeviceId'], appDeviceId);
      expect(payload['oob'], oob);
    });

    test('treats missing items and repeated removal as harmless', () async {
      final store = MacKeychainTuiBindingMaterialStore(
        commandRunner: (arguments) async {
          calls.add(List<String>.from(arguments));
          return const TuiBindingKeychainCommandResult(exitCode: 44);
        },
      );

      expect(await store.readBindingMaterial('AA:BB:CC:DD:EE:FF'), isNull);
      await store.removeBindingMaterial('AA:BB:CC:DD:EE:FF');
      expect(calls, hasLength(2));
    });

    test('validates values before invoking Keychain', () async {
      var invocationCount = 0;
      final store = MacKeychainTuiBindingMaterialStore(
        commandRunner: (_) async {
          invocationCount++;
          return const TuiBindingKeychainCommandResult(exitCode: 0);
        },
      );

      await expectLater(
        store.saveBindingMaterial(
          'AA:BB:CC:DD:EE:FF',
          appDeviceId: 'bad' + String.fromCharCode(10) + 'identity',
          oob: oob,
        ),
        throwsFormatException,
      );
      await expectLater(
        store.saveBindingMaterial(
          'AA:BB:CC:DD:EE:FF',
          appDeviceId: appDeviceId,
          oob: 'bad' + String.fromCharCode(0) + 'oob',
        ),
        throwsFormatException,
      );
      expect(invocationCount, 0);
    });

    test('does not leak values through command failures', () async {
      final store = MacKeychainTuiBindingMaterialStore(
        commandRunner: (_) async =>
            const TuiBindingKeychainCommandResult(exitCode: 1),
      );

      final error = await _captureError(
        () => store.saveBindingMaterial(
          'AA:BB:CC:DD:EE:FF',
          appDeviceId: appDeviceId,
          oob: oob,
        ),
      );
      expect(error, isA<TuiBindingMaterialStoreException>());
      expect(error.toString(), isNot(contains(appDeviceId)));
      expect(error.toString(), isNot(contains(oob)));
    });

    test('rejects malformed Keychain payloads without exposing contents',
        () async {
      final store = MacKeychainTuiBindingMaterialStore(
        commandRunner: (_) async => TuiBindingKeychainCommandResult(
          exitCode: 0,
          stdout: jsonEncode(<String, Object?>{
            'version': 1,
            'appDeviceId': appDeviceId,
            'oob': oob,
            'unexpected': 'value',
          }),
        ),
      );

      final error = await _captureError(
        () async {
          await store.readBindingMaterial('AA:BB:CC:DD:EE:FF');
        },
      );
      expect(error, isA<TuiBindingMaterialStoreException>());
      expect(error.toString(), isNot(contains(appDeviceId)));
      expect(error.toString(), isNot(contains(oob)));
    });

    test('rejects reuse of the authkey Keychain service', () {
      expect(
        () => MacKeychainTuiBindingMaterialStore(
          serviceName: 'com.anemo.wristload.tui.authkey',
        ),
        throwsArgumentError,
      );
    });
  });
}

Future<Object> _captureError(Future<void> Function() operation) async {
  try {
    await operation();
    return StateError('Operation unexpectedly succeeded.');
  } on Object catch (error) {
    return error;
  }
}
