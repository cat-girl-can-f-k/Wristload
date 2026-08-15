import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wristload_tui/src/application/persistence/saved_device_repository.dart';
import 'package:wristload_tui/src/application/persistence/saved_tui_device.dart';
import 'package:wristload_tui/src/application/persistence/tui_credential_store.dart';
import 'package:wristload_tui/src/application/persistence/tui_preference_store.dart';

void main() {
  group('SavedTuiDevice', () {
    test('normalizes stable Bluetooth MAC identities', () {
      expect(
        SavedTuiDevice.normalizeMacAddress('aa-bb-cc-dd-ee-ff'),
        'AA:BB:CC:DD:EE:FF',
      );
      expect(
        SavedTuiDevice.normalizeMacAddress('AA:bb:CC:dd:EE:ff'),
        'AA:BB:CC:DD:EE:FF',
      );
    });

    test('rejects non-MAC identities', () {
      expect(
        () => SavedTuiDevice.normalizeMacAddress('device-uuid'),
        throwsFormatException,
      );
    });
  });

  group('JsonSavedDeviceRepository', () {
    late Directory temporaryDirectory;
    late File file;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'wristload-tui-persistence-',
      );
      file = File('${temporaryDirectory.path}/saved_devices.json');
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    test('saves, replaces by MAC, loads, and removes a saved device', () async {
      final repository = JsonSavedDeviceRepository(file: file);
      await repository.save(
        SavedTuiDevice(
          displayName: 'Xiaomi Smart Band 10 Pro',
          macAddress: 'aa:bb:cc:dd:ee:ff',
          isSupported: true,
        ),
      );
      await repository.save(
        SavedTuiDevice(
          displayName: 'Xiaomi Smart Band 10 Pro (renamed)',
          macAddress: 'AA-BB-CC-DD-EE-FF',
          isSupported: true,
        ),
      );

      expect(await repository.load(), hasLength(1));
      expect(
        (await repository.findByMacAddress('aa-bb-cc-dd-ee-ff'))?.displayName,
        'Xiaomi Smart Band 10 Pro (renamed)',
      );

      await repository.removeByMacAddress('AA:BB:CC:DD:EE:FF');
      expect(await repository.load(), isEmpty);
    });

    test(
        'writes a complete final JSON document without a delete-then-write gap',
        () async {
      final repository = JsonSavedDeviceRepository(file: file);
      await repository.save(
        SavedTuiDevice(
          displayName: 'First band',
          macAddress: '00:00:00:00:00:01',
          isSupported: true,
        ),
      );
      await repository.save(
        SavedTuiDevice(
          displayName: 'Second band',
          macAddress: '00:00:00:00:00:02',
          isSupported: false,
        ),
      );

      expect(jsonDecode(await file.readAsString()), isA<List>());
      expect(await File('${file.path}.tmp').exists(), isFalse);
      expect((await repository.load()).map((device) => device.displayName), [
        'First band',
        'Second band',
      ]);
    });
  });

  group('TuiCredentialStore', () {
    test('in-memory credentials stay bound to normalized device MAC', () async {
      final store = InMemoryTuiCredentialStore();
      const keyA = '00112233445566778899AABBCCDDEEFF';
      const keyB = 'FFEEDDCCBBAA99887766554433221100';

      await store.saveAuthKey('aa-bb-cc-dd-ee-ff', keyA);
      await store.saveAuthKey('AA:BB:CC:DD:EE:00', keyB);

      expect(await store.readAuthKey('AA:BB:CC:DD:EE:FF'), keyA);
      expect(await store.readAuthKey('AA-BB-CC-DD-EE-00'), keyB);
      await store.removeAuthKey('aa:bb:cc:dd:ee:ff');
      expect(await store.readAuthKey('AA:BB:CC:DD:EE:FF'), isNull);
      expect(await store.readAuthKey('AA:BB:CC:DD:EE:00'), keyB);
    });

    test('Keychain failures do not expose the supplied authkey', () async {
      const suppliedKey = '00112233445566778899AABBCCDDEEFF';
      final store = MacKeychainCredentialStore(
        commandRunner: (_) async => const KeychainCommandResult(exitCode: 1),
      );

      await expectLater(
        store.saveAuthKey('AA:BB:CC:DD:EE:FF', suppliedKey),
        throwsA(
          isA<TuiCredentialStoreException>().having(
            (error) => error.toString(),
            'message',
            isNot(contains(suppliedKey)),
          ),
        ),
      );
    });
  });

  group('TuiPreferenceStore', () {
    late Directory temporaryDirectory;
    late TuiPreferenceStore store;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'wristload-tui-preferences-',
      );
      store = TuiPreferenceStore(
        file: File('${temporaryDirectory.path}/preferences.json'),
      );
    });

    tearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    test('defaults to automatic connection and the black-blue theme', () async {
      final preferences = await store.load();
      expect(preferences.autoConnectLastDevice, isTrue);
      expect(preferences.themeId, TuiPreferences.defaultThemeId);
    });

    test('persists auto-connect and theme independently', () async {
      await store.setAutoConnectLastDevice(false);
      await store.setThemeId('midnight-cyan');

      final preferences = await store.load();
      expect(preferences.autoConnectLastDevice, isFalse);
      expect(preferences.themeId, 'midnight-cyan');
    });
  });
}
