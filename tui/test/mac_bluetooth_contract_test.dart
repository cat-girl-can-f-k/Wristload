import 'package:test/test.dart';
import 'package:wristload_tui/src/transport/mac_bluetooth_transport.dart';

void main() {
  group('MacBluetoothAddress', () {
    test('normalizes all supported classic Bluetooth address forms', () {
      final hyphenated = MacBluetoothAddress.parse('aa-bb-cc-dd-ee-ff');
      final colonSeparated = MacBluetoothAddress.parse('AA:BB:CC:DD:EE:FF');
      final compact = MacBluetoothAddress.parse('aabbccddeeff');

      expect(hyphenated.key, 'AABBCCDDEEFF');
      expect(hyphenated.display, 'AA-BB-CC-DD-EE-FF');
      expect(colonSeparated, hyphenated);
      expect(compact, hyphenated);
    });

    test('rejects UUIDs, BLE identifiers, and malformed addresses', () {
      const invalid = [
        '00000000-0000-0000-0000-AABBCCDDEEFF',
        'AABBCCDDEE',
        'AA:BB:CC:DD:EE:GG',
        'AA-BB-CC-DD-EE-FF-00',
        'CoreBluetooth-identifier',
      ];

      for (final value in invalid) {
        expect(
          () => MacBluetoothAddress.parse(value),
          throwsA(isA<FormatException>()),
          reason: value,
        );
        expect(MacBluetoothAddress.tryParse(value), isNull, reason: value);
      }
    });
  });

  group('MacBluetoothDevice', () {
    test('merges paired and inquiry records by normalized classic address', () {
      final paired = MacBluetoothDevice(
        address: 'AA-BB-CC-DD-EE-FF',
        name: 'Band 9 Pro',
        paired: true,
        source: MacBluetoothDeviceSource.paired,
      );
      final inquiry = MacBluetoothDevice(
        address: 'aa:bb:cc:dd:ee:ff',
        name: 'Smart Band 9 Pro',
        rssi: -52,
        source: MacBluetoothDeviceSource.inquiry,
      );

      final merged = paired.merge(inquiry);
      expect(merged.address, 'AA-BB-CC-DD-EE-FF');
      expect(merged.addressKey, 'AABBCCDDEEFF');
      expect(merged.name, 'Smart Band 9 Pro');
      expect(merged.rssi, -52);
      expect(merged.paired, isTrue);
      expect(merged.source, MacBluetoothDeviceSource.paired);
      expect(merged, paired);
      expect(merged, inquiry);
    });

    test('refuses to merge records for different classic devices', () {
      final first = MacBluetoothDevice(address: 'AA-BB-CC-DD-EE-FF', name: 'A');
      final second =
          MacBluetoothDevice(address: '11-22-33-44-55-66', name: 'B');

      expect(() => first.merge(second), throwsArgumentError);
    });
  });
}
