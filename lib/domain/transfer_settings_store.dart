import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../application/diagnostic_log_service.dart';

/// Persists small, non-sensitive transfer preferences in the app data folder.
/// No device key, session key, or transferred file content is stored here.
class TransferSettingsStore {
  static const _fileName = 'transfer_settings.json';
  Future<void> _writeQueue = Future<void>.value();

  Future<TransferSettings> read() async {
    appLogger.trace('读取传输设置开始', category: DiagnosticLogCategory.storage);
    try {
      final file = await _file();
      if (!await file.exists()) {
        appLogger.debug('传输设置文件不存在，使用默认值', category: DiagnosticLogCategory.storage);
        return const TransferSettings();
      }
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic>) {
        appLogger.warning('传输设置格式无效，使用默认值', category: DiagnosticLogCategory.storage);
        return const TransferSettings();
      }
      final settings = TransferSettings(
        segmentIntervalMs: value['segmentIntervalMs'] as int?,
        massWindowSize: value['massWindowSize'] as int?,
        autoTimeSync: value['autoTimeSync'] as bool?,
      );
      appLogger.debug('传输设置读取完成', category: DiagnosticLogCategory.storage, fields: <String, Object?>{
        'hasInterval': settings.segmentIntervalMs != null,
        'hasWindow': settings.massWindowSize != null,
        'hasAutoTimeSync': settings.autoTimeSync != null,
      });
      return settings;
    } on Object catch (error) {
      appLogger.error('传输设置读取失败：$error', category: DiagnosticLogCategory.storage, fields: <String, Object?>{'errorType': error.runtimeType.toString()});
      return const TransferSettings();
    }
  }

  Future<void> write({
    required int segmentIntervalMs,
    required int massWindowSize,
    bool autoTimeSync = false,
  }) {
    // Sliders can submit several changes before the previous rename finishes.
    // Serialize delete/rename pairs so one write cannot remove another write's
    // temporary file or leave the queue permanently failed.
    final next = _writeQueue.then<void>(
      (_) => _writeNow(segmentIntervalMs, massWindowSize, autoTimeSync),
      onError: (_) =>
          _writeNow(segmentIntervalMs, massWindowSize, autoTimeSync),
    );
    _writeQueue = next;
    return next;
  }

  Future<void> _writeNow(
    int segmentIntervalMs,
    int massWindowSize,
    bool autoTimeSync,
  ) async {
    appLogger.trace('写入传输设置开始', category: DiagnosticLogCategory.storage, fields: <String, Object?>{
      'segmentIntervalMs': segmentIntervalMs,
      'massWindowSize': massWindowSize,
      'autoTimeSync': autoTimeSync,
    });
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'segmentIntervalMs': segmentIntervalMs,
        'massWindowSize': massWindowSize,
        'autoTimeSync': autoTimeSync,
      }),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
    appLogger.info('传输设置写入完成', category: DiagnosticLogCategory.storage);
  }

  Future<File> _file() async {
    final directory = await getApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}$_fileName');
  }
}

class TransferSettings {
  const TransferSettings({
    this.segmentIntervalMs,
    this.massWindowSize,
    this.autoTimeSync,
  });

  final int? segmentIntervalMs;
  final int? massWindowSize;
  final bool? autoTimeSync;
}
