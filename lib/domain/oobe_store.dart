import 'package:shared_preferences/shared_preferences.dart';
import '../application/diagnostic_log_service.dart';

class OobeStore {
  static const key = 'oobe_completed';

  Future<bool> readCompleted() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final value = preferences.getBool(key) ?? false;
      appLogger.debug(
        '读取首次运行状态完成',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{'completed': value},
      );
      return value;
    } on Object catch (error) {
      appLogger.error(
        '读取首次运行状态失败',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      rethrow;
    }
  }

  Future<void> markCompleted() async {
    await _write(true);
  }

  Future<void> markNotCompleted() async {
    await _write(false);
  }

  Future<void> _write(bool value) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(key, value);
      appLogger.info(
        '首次运行状态写入完成',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{'completed': value},
      );
    } on Object catch (error) {
      appLogger.error(
        '首次运行状态写入失败',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      rethrow;
    }
  }
}
