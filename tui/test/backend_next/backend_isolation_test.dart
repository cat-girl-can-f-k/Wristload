import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('backend_next recursively owns its backend and transport layers', () {
    final files = Directory('lib/src/backend_next')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList()
      ..sort((left, right) => left.path.compareTo(right.path));

    expect(files, isNotEmpty);
    for (final file in files) {
      final source = file.readAsStringSync();
      for (final forbidden in const <String>[
        "import '../backend/",
        "import '../../backend/",
        "import '../transport/",
        "import '../../transport/",
        "import '../frontend/",
        "import '../../frontend/",
        'package:flutter/',
        'WristloadBackend',
        'TuiFrontendPort',
      ]) {
        expect(
          source,
          isNot(contains(forbidden)),
          reason: file.path + ' must not contain ' + forbidden,
        );
      }
    }
  });
}
