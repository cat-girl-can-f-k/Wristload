library;

import 'dart:io';

/// TUI state intentionally stays outside the Flutter application's directory.
Future<Directory> wristloadTuiApplicationSupportDirectory() async {
  if (!Platform.isMacOS) {
    throw UnsupportedError('Wristload TUI only supports macOS.');
  }
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError('HOME is unavailable; cannot locate Application Support.');
  }
  final directory = Directory(
    '$home${Platform.pathSeparator}Library${Platform.pathSeparator}'
    'Application Support${Platform.pathSeparator}WristloadTui',
  );
  await directory.create(recursive: true);
  return directory;
}
