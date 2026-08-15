import 'package:shared_preferences/shared_preferences.dart';

/// Stores whether Wristload should reconnect the most recently authenticated
/// device during application startup.
class AutoConnectPreferenceStore {
  static const key = 'auto_connect_last_device';
  static const defaultEnabled = true;

  Future<bool> read() async {
    final preferences = await SharedPreferences.getInstance();
    try {
      return preferences.getBool(key) ?? defaultEnabled;
    } on TypeError {
      // A stale value from an older build must not prevent startup.
      return defaultEnabled;
    }
  }

  Future<void> write(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(key, enabled);
  }
}
