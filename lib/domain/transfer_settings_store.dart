import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persists small, non-sensitive transfer preferences in the app data folder.
/// No device key, session key, or transferred file content is stored here.
class TransferSettingsStore {
  static const _fileName = 'transfer_settings.json';
  Future<void> _writeQueue = Future<void>.value();

  Future<TransferSettings> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const TransferSettings();
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic>) return const TransferSettings();
      return TransferSettings(
        segmentIntervalMs: value['segmentIntervalMs'] as int?,
        massWindowSize: value['massWindowSize'] as int?,
        autoTimeSync: value['autoTimeSync'] as bool?,
      );
    } on Object {
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
