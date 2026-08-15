import 'package:shared_preferences/shared_preferences.dart';

import '../application/diagnostic_log_service.dart';
import 'install_task.dart';

enum InstallPreference { watchface, quickApp, both }

class InstallPreferenceStore {
  static const key = 'preferred_install_target';

  Future<InstallKind> read() async {
    appLogger.trace('读取安装目标偏好开始', category: DiagnosticLogCategory.storage);
    return switch (await readPreference()) {
      InstallPreference.quickApp => InstallKind.quickApp,
      _ => InstallKind.watchface,
    };
  }

  Future<InstallPreference> readPreference() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(key);
      final value = switch (raw) {
        'quickapp' => InstallPreference.quickApp,
        'both' => InstallPreference.both,
        _ => InstallPreference.watchface,
      };
      appLogger.debug(
        '读取安装目标偏好完成',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{'value': value.name, 'rawValid': raw != null},
      );
      return value;
    } on Object catch (error) {
      appLogger.error(
        '读取安装目标偏好失败',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      rethrow;
    }
  }

  Future<void> write(InstallKind target) async {
    await writePreference(target == InstallKind.watchface
        ? InstallPreference.watchface
        : InstallPreference.quickApp);
  }

  Future<void> writePreference(InstallPreference target) async {
    final raw = switch (target) {
      InstallPreference.watchface => 'watchface',
      InstallPreference.quickApp => 'quickapp',
      InstallPreference.both => 'both',
    };
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(key, raw);
      appLogger.info(
        '安装目标偏好写入完成',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{'value': target.name},
      );
    } on Object catch (error) {
      appLogger.error(
        '安装目标偏好写入失败',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      rethrow;
    }
  }
}
