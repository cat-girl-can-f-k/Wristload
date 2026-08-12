import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Owns the app-wide seed color and persists it independently of theme mode.
class ThemeController extends ChangeNotifier {
  ThemeController(
    Color initialSeed, {
    SharedPreferences? preferences,
  })  : _seedColor = initialSeed,
        _preferences = preferences;

  static const preferenceKey = 'theme_seed_color';
  static const defaultSeedColor = Color(0xFF6750A4);

  Color _seedColor;
  SharedPreferences? _preferences;

  Color get seedColor => _seedColor;

  static Future<ThemeController> create() async {
    final preferences = await SharedPreferences.getInstance();
    final value = preferences.getInt(preferenceKey);
    return ThemeController(
      value == null ? defaultSeedColor : Color(value),
      preferences: preferences,
    );
  }

  Future<void> setSeed(Color color) async {
    if (_seedColor.toARGB32() == color.toARGB32()) return;
    _seedColor = color;
    notifyListeners();
    final preferences = _preferences ??= await SharedPreferences.getInstance();
    await preferences.setInt(preferenceKey, color.toARGB32());
  }
}
