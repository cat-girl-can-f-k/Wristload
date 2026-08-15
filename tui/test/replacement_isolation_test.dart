import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('replacement UI and production entrypoint do not import legacy or GUI',
      () {
    final sources = <String>[
      _readTree(Directory('lib/src/ui_next')),
      File('bin/wristload_tui.dart').readAsStringSync(),
    ].join('\n');

    for (final forbidden in const <String>[
      '/src/frontend/',
      "import '../frontend/",
      'package:flutter/',
      'presentation/',
      'controller/',
      'TuiFacade',
      'TuiApp(',
    ]) {
      expect(sources, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  test('application and TUI macOS backend have no Flutter GUI dependency', () {
    final sources = <String>[
      _readTree(Directory('lib/src/application')),
      _readTree(Directory('lib/src/backend_next')),
    ].join('\n');

    for (final forbidden in const <String>[
      "import '../frontend/",
      'package:flutter/',
      'presentation/',
      'controller/',
      'WidgetsBinding',
    ]) {
      expect(sources, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}

String _readTree(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .where((file) => file.path.endsWith('.dart'))
    .map((file) => file.readAsStringSync())
    .join('\n');
