/// Shared GATT constants and checksums used by the verified V2 transport.
library;

/// MI Wear GATT UUIDs used only for discovery/version inspection.
abstract final class SarGatt {
  static const String serviceUuid = '0000fe95-0000-1000-8000-00805f9b34fb';
  static const String versionUuid = '00000050-0000-1000-8000-00805f9b34fb';
  static const String writeUuid = '0000005f-0000-1000-8000-00805f9b34fb';
  static const String notifyUuid = '0000005e-0000-1000-8000-00805f9b34fb';
}

/// CRC-16/IBM (reflected polynomial 0xA001, initial value 0).
int computeCrc16(List<int> data, {int? length}) {
  final len = length ?? data.length;
  if (len < 0 || len > data.length) {
    throw RangeError.range(len, 0, data.length, 'length');
  }
  var crc = 0;
  for (var i = 0; i < len; i++) {
    crc = (_crc16Table[(crc ^ data[i]) & 0xFF]) ^ (crc >>> 8);
  }
  return crc & 0xFFFF;
}

final List<int> _crc16Table = List<int>.generate(256, (index) {
  var crc = index;
  for (var bit = 0; bit < 8; bit++) {
    crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xA001 : crc >>> 1;
  }
  return crc & 0xFFFF;
});
