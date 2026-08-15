import 'package:shared_preferences/shared_preferences.dart';
import '../application/diagnostic_log_service.dart';

/// Persists only the user-facing floating-window preference and its last
/// on-screen position. Window bounds are validated by the coordinator before
/// they are restored.
class FloatingWindowPreferences {
  static const _enabledKey = 'floating_install_window_enabled';
  static const _xKey = 'floating_install_window_x';
  static const _yKey = 'floating_install_window_y';

  Future<bool> readEnabled() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final value = preferences.getBool(_enabledKey) ?? false;
      appLogger.debug('读取浮动窗口开关完成', category: DiagnosticLogCategory.storage, fields: <String, Object?>{'enabled': value});
      return value;
    } on Object catch (error) {
      appLogger.error('读取浮动窗口开关失败', category: DiagnosticLogCategory.storage, fields: <String, Object?>{'errorType': error.runtimeType.toString()});
      rethrow;
    }
  }

  Future<void> writeEnabled(bool enabled) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_enabledKey, enabled);
      appLogger.info('浮动窗口开关写入完成', category: DiagnosticLogCategory.storage, fields: <String, Object?>{'enabled': enabled});
    } on Object catch (error) {
      appLogger.error('浮动窗口开关写入失败', category: DiagnosticLogCategory.storage, fields: <String, Object?>{'errorType': error.runtimeType.toString()});
      rethrow;
    }
  }

  Future<FloatingWindowPosition?> readPosition() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final x = preferences.getDouble(_xKey);
      final y = preferences.getDouble(_yKey);
      if (x == null || y == null) {
        appLogger.trace('浮动窗口位置未保存', category: DiagnosticLogCategory.storage);
        return null;
      }
      appLogger.debug('读取浮动窗口位置完成', category: DiagnosticLogCategory.storage, fields: <String, Object?>{'hasPosition': true});
      return FloatingWindowPosition(x: x, y: y);
    } on Object catch (error) {
      appLogger.error('读取浮动窗口位置失败', category: DiagnosticLogCategory.storage, fields: <String, Object?>{'errorType': error.runtimeType.toString()});
      rethrow;
    }
  }

  Future<void> writePosition(FloatingWindowPosition position) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setDouble(_xKey, position.x);
      await preferences.setDouble(_yKey, position.y);
      appLogger.trace('浮动窗口位置写入完成', category: DiagnosticLogCategory.storage);
    } on Object catch (error) {
      appLogger.error('浮动窗口位置写入失败', category: DiagnosticLogCategory.storage, fields: <String, Object?>{'errorType': error.runtimeType.toString()});
      rethrow;
    }
  }
}

class FloatingWindowPosition {
  const FloatingWindowPosition({required this.x, required this.y});

  final double x;
  final double y;
}
