import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wristload/domain/diagnostic_log_preferences.dart';
import 'package:wristload/domain/last_device_store.dart';
import 'package:wristload/domain/auto_connect_preference.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LastDeviceStore', () {
    test('returns null when no previous device is stored', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await LastDeviceStore().read(), isNull);
    });

    test('round-trips a trimmed device identity', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LastDeviceStore();

      await store.write(id: '  DEVICE-42  ', name: '  Band 10  ');

      final record = await store.read();
      expect(record, isNotNull);
      expect(record!.id, 'DEVICE-42');
      expect(record.name, 'Band 10');
    });

    test('missing or blank id is treated as no record', () async {
      SharedPreferences.setMockInitialValues({
        'last_connected_device_id': '   ',
        'last_connected_device_name': 'Band 10',
      });

      expect(await LastDeviceStore().read(), isNull);
    });

    test('clearFor only clears the matching id, case-insensitively', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LastDeviceStore();
      await store.write(id: 'DEVICE-42', name: 'Band 10');

      await store.clearFor('other-device');
      expect((await store.read())!.id, 'DEVICE-42');

      await store.clearFor('  device-42  ');
      expect(await store.read(), isNull);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.containsKey('last_connected_device_name'), isFalse);
    });

    test('clearFor is a no-op when storage has no record', () async {
      SharedPreferences.setMockInitialValues({});

      await LastDeviceStore().clearFor('DEVICE-42');

      expect(await LastDeviceStore().read(), isNull);
    });
  });

  group('DiagnosticLogPreferences', () {
    test('defaults auto-open logging to disabled', () async {
      SharedPreferences.setMockInitialValues({});

      expect(await DiagnosticLogPreferences().readAutoOpen(), isFalse);
    });

    test('round-trips auto-open logging preference', () async {
      SharedPreferences.setMockInitialValues({});
      final preferencesStore = DiagnosticLogPreferences();

      await preferencesStore.writeAutoOpen(true);
      expect(await preferencesStore.readAutoOpen(), isTrue);

      await preferencesStore.writeAutoOpen(false);
      expect(await preferencesStore.readAutoOpen(), isFalse);

      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('auto_open_diagnostic_log'), isFalse);
    });

    test('ignores a non-boolean stored value and uses the default', () async {
      SharedPreferences.setMockInitialValues({
        'auto_open_diagnostic_log': 'true',
      });

      expect(await DiagnosticLogPreferences().readAutoOpen(), isFalse);
    });
  });

  group('AutoConnectPreferenceStore', () {
    test('defaults to enabled and round-trips the value', () async {
      SharedPreferences.setMockInitialValues({});
      final store = AutoConnectPreferenceStore();

      expect(await store.read(), isTrue);
      await store.write(false);
      expect(await store.read(), isFalse);
      await store.write(true);
      expect(await store.read(), isTrue);
    });

    test(
      'ignores a non-boolean stored value and uses enabled default',
      () async {
        SharedPreferences.setMockInitialValues({
          AutoConnectPreferenceStore.key: 'false',
        });

        expect(await AutoConnectPreferenceStore().read(), isTrue);
      },
    );
  });
}
