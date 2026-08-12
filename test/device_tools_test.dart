import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/domain/device_tools.dart';

void main() {
  group('unlock code', () {
    test('matches the old Vela 4 reference vector', () {
      expect(
        computeUnlockCode('abc123456789', 'aa:bb:cc:dd:ee:ff'),
        '8349607521',
      );
    });

    test('matches the newer Vela 5 reference vector', () {
      expect(
        computeUnlockCode(
          ' ABC123456789 ',
          'AA：BB：CC：DD：EE：FF',
          algorithm: UnlockAlgorithm.newer,
        ),
        '6164267340',
      );
    });

    test('always returns ten decimal digits', () {
      final code = computeUnlockCode('SN42', 'AABBCCDDEEFF');
      expect(code, matches(RegExp(r'^\d{10}$')));
    });

    test('rejects invalid SN and MAC values', () {
      expect(
        () => computeUnlockCode('SN1', 'AA:BB:CC:DD:EE:FF'),
        throwsFormatException,
      );
      expect(
        () => computeUnlockCode('SN42', 'AA:BB:CC:DD:EE'),
        throwsFormatException,
      );
    });
  });

  group('authkey ZIP extraction', () {
    test('prefers XiaomiFit.main.log and reads JSON product/token records', () {
      final bytes = _zip({
        'other.log': 'authkey=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'logs/XiaomiFit.main.log':
            '{"productName":"Watch S4","token":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"} '
                'mac=aa:bb:cc:dd:ee:ff',
      });

      final candidates = extractAuthKeysFromZip(bytes);

      expect(candidates.map((candidate) => candidate.key), [
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ]);
      expect(candidates.first.productName, 'Watch S4');
      expect(candidates.first.mac, 'AA:BB:CC:DD:EE:FF');
      expect(candidates.first.sourcePath, 'logs/XiaomiFit.main.log');
    });

    test('supports alternative key-value format and explicit anchors', () {
      final bytes = _zip({
        'XiaomiFit.main.log':
            "productName='Mi Band'; token='CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC'\n"
                'encrypt_key: dddddddddddddddddddddddddddddddd\n'
                'auth_key=EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE',
      });

      final candidates = extractAuthKeysFromZip(bytes);

      expect(candidates.map((candidate) => candidate.key), [
        'cccccccccccccccccccccccccccccccc',
        'dddddddddddddddddddddddddddddddd',
        'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      ]);
      expect(candidates.first.productName, 'Mi Band');
    });

    test('deduplicates authkeys across all supported forms', () {
      const key = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final bytes = _zip({
        'XiaomiFit.main.log':
            '{"productName":"Watch","token":"$key"} authkey=$key',
        'copy.log': 'auth_key=$key',
      });

      expect(extractAuthKeysFromZip(bytes).map((candidate) => candidate.key),
          [key]);
    });

    test('returns no candidates when no valid authkey is present', () {
      expect(extractAuthKeysFromZip(_zip({'XiaomiFit.main.log': 'token=bad'})),
          isEmpty);
    });
  });
}

List<int> _zip(Map<String, String> entries) {
  final archive = Archive();
  for (final MapEntry(:key, :value) in entries.entries) {
    final data = utf8.encode(value);
    archive.addFile(ArchiveFile(key, data.length, data));
  }
  return ZipEncoder().encode(archive)!;
}
