import 'package:shared_preferences/shared_preferences.dart';

class OobeStore {
  static const key = 'oobe_completed';

  Future<bool> readCompleted() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(key) ?? false;
  }

  Future<void> markCompleted() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(key, true);
  }

  Future<void> markNotCompleted() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(key, false);
  }
}
