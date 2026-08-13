import 'dart:io';

import 'package:test/test.dart';

void main() {
  final project = Directory.current.path;
  final entrypoint = File('${project}/bin/wristload_tui.dart');

  test('entrypoint documents production, probe, helper, and fixture modes', () {
    final source = entrypoint.readAsStringSync();

    expect(source, contains('TuiFacade.macos'));
    expect(source, contains('--helper'));
    expect(source, contains('--probe'));
    expect(source, contains('--fixture'));
    expect(source, contains('_defaultHelperPath'));
  });

  test('entrypoint disposes production and fake ports', () {
    final source = entrypoint.readAsStringSync();
    expect(source, contains('finally {'));
    expect(source, contains('await facade.dispose()'));
    expect(source, contains('await port.dispose()'));
  });

  test('entrypoint rejects contradictory and incomplete command arguments', () {
    final source = entrypoint.readAsStringSync();

    expect(source, contains('--probe cannot be combined with --fixture.'));
    expect(source, contains('--helper requires a path.'));
    expect(source, contains('--fixture requires a fixture name.'));
    expect(source, contains('Unknown fixture:'));
    expect(source, contains('exitCode = 64'));
  });
}
