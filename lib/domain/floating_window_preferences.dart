import 'package:shared_preferences/shared_preferences.dart';

/// Persists only the user-facing floating-window preference and its last
/// on-screen position. Window bounds are validated by the coordinator before
/// they are restored.
class FloatingWindowPreferences {
  static const _enabledKey = 'floating_install_window_enabled';
  static const _xKey = 'floating_install_window_x';
  static const _yKey = 'floating_install_window_y';

  Future<bool> readEnabled() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_enabledKey) ?? false;
  }

  Future<void> writeEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_enabledKey, enabled);
  }

  Future<FloatingWindowPosition?> readPosition() async {
    final preferences = await SharedPreferences.getInstance();
    final x = preferences.getDouble(_xKey);
    final y = preferences.getDouble(_yKey);
    if (x == null || y == null) return null;
    return FloatingWindowPosition(x: x, y: y);
  }

  Future<void> writePosition(FloatingWindowPosition position) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setDouble(_xKey, position.x);
    await preferences.setDouble(_yKey, position.y);
  }
}

class FloatingWindowPosition {
  const FloatingWindowPosition({required this.x, required this.y});

  final double x;
  final double y;
}
