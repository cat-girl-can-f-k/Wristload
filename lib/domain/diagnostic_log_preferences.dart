import 'package:shared_preferences/shared_preferences.dart';

class DiagnosticLogPreferences {
  static const _autoOpenKey = 'auto_open_diagnostic_log';

  Future<bool> readAutoOpen() async {
    final preferences = await SharedPreferences.getInstance();
    // Preferences can outlive a setting's historical representation. A bad
    // value must not prevent the application from starting.
    try {
      return preferences.getBool(_autoOpenKey) ?? false;
    } on TypeError {
      return false;
    }
  }

  Future<void> writeAutoOpen(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_autoOpenKey, value);
  }
}
