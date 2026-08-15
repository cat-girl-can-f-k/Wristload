import 'package:shared_preferences/shared_preferences.dart';

/// Persists only the identity needed to match a device during the next scan.
/// No authkey or session material is stored here.
class LastDeviceRecord {
  const LastDeviceRecord({required this.id, required this.name});

  final String id;
  final String name;
}

class LastDeviceStore {
  static const _idKey = 'last_connected_device_id';
  static const _nameKey = 'last_connected_device_name';

  Future<LastDeviceRecord?> read() async {
    final preferences = await SharedPreferences.getInstance();
    final id = preferences.getString(_idKey)?.trim();
    if (id == null || id.isEmpty) return null;
    return LastDeviceRecord(
      id: id,
      name: preferences.getString(_nameKey)?.trim() ?? '',
    );
  }

  Future<void> write({required String id, required String name}) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_idKey, id.trim());
    await preferences.setString(_nameKey, name.trim());
  }

  Future<void> clearFor(String id) async {
    final current = await read();
    if (current == null ||
        current.id.toLowerCase() != id.trim().toLowerCase()) {
      return;
    }
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_idKey);
    await preferences.remove(_nameKey);
  }
}
