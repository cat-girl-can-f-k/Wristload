import 'dart:io';

import 'package:test/test.dart';

void main() {
  final project = Directory.current.path;
  final entrypoint = File('${project}/bin/wristload_tui.dart');

  test('entrypoint documents production, probe, helper, and fixture modes', () {
    final source = entrypoint.readAsStringSync();

    expect(source, contains('MacOsTuiBackendAdapter'));
    expect(source, contains('TuiApplication(backend: backend)'));
    expect(source,
        contains('TuiApplicationUiPortAdapter(application: application)'));
    expect(source, contains('UiNextShell('));
    expect(source, contains('UiConsoleTerminal()'));
    expect(source, contains('--helper'));
    expect(source, contains('--probe'));
    expect(source, contains('--fixture'));
    expect(source, contains('_defaultHelperPath'));
    expect(source, contains('JsonLineMacBluetoothTransport'));
    expect(source, contains('await transport.start()'));
  });

  test('entrypoint isolates probe cleanup from replacement-shell cleanup', () {
    final source = entrypoint.readAsStringSync();
    expect(source, contains('finally {'));
    expect(source, contains('await transport.dispose()'));
    expect(source, contains('UiNextShell owns port disposal'));
  });

  test('fixture path uses only replacement UI contracts', () {
    final source = entrypoint.readAsStringSync();

    expect(source, contains('FakeUiNextPort'));
    expect(source, contains('UiNextFixtures.load(fixtureName)'));
    expect(source, contains('UiConsoleTerminal()'));
    expect(source, isNot(contains('/src/frontend/')));
    expect(source, isNot(contains('TuiApp(')));
    expect(source, isNot(contains('TuiFixtures.')));
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
