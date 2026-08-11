import 'package:flutter_test/flutter_test.dart';
import 'package:miwearable_install_tool/domain/protocol/transport_constants.dart';

void main() {
  group('Standard BLE battery level', () {
    test('accepts only a present percentage in the 0 to 100 range', () {
      expect(parseBatteryLevel(const [0]), 0);
      expect(parseBatteryLevel(const [82]), 82);
      expect(parseBatteryLevel(const [100]), 100);
      expect(parseBatteryLevel(const [82, 0xff]), 82);
    });

    test('keeps missing and malformed values unknown', () {
      expect(parseBatteryLevel(const []), isNull);
      expect(parseBatteryLevel(const [-1]), isNull);
      expect(parseBatteryLevel(const [101]), isNull);
      expect(parseBatteryLevel(const [255]), isNull);
    });
  });
}
