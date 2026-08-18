import 'dart:io';

import 'package:test/test.dart';

void main() {
  final project = Directory.current.path;
  final entrypoint = File('${project}/bin/wristload_tui.dart');

  test('entrypoint documents production, probe, helper, and fixture modes', () {
    final source = entrypoint.readAsStringSync();

    expect(source, contains('MacOsTuiBackendAdapter'));
    expect(source, contains('TuiLaunchOptions.parse('));
    expect(source, contains('fixtureNames: UiNextFixtures.names'));
    expect(
      source,
      contains('directedClassicTarget: options.directedClassicTarget'),
    );
    expect(source,
        contains('TuiApplicationUiPortAdapter(application: application)'));
    expect(source, contains('UiNextShell('));
    expect(source, contains('UiConsoleTerminal()'));
    expect(source, contains('--helper'));
    expect(source, contains('--probe'));
    expect(source, contains('--fixture'));
    expect(source, contains('_defaultHelperPath'));
    expect(source, contains('_resolveDefaultHelperPath()'));
    expect(
      source,
      contains(
          'wearable_macos_bridge.app/Contents/MacOS/wearable_macos_bridge'),
    );
    expect(source, contains('_hasValidCodeSignature'));
    expect(source, contains('/usr/bin/codesign'));
    expect(source, contains('File.fromUri(Platform.script)'));
    expect(source, contains('JsonLineMacBluetoothTransport'));
    expect(source, contains('await transport.start()'));
  });

  test('entrypoint launches the standalone JSONL follower in macOS Terminal',
      () {
    final source = entrypoint.readAsStringSync();

    expect(source, contains('logViewerLauncher: _launchLogViewer'));
    expect(source, contains('bin/wristload_logs.dart'));
    expect(source, contains("arguments.first == 'logs'"));
    expect(source, contains('runDiagnosticLogViewer'));
    expect(source, contains('buildDiagnosticLogViewerLaunch'));
    expect(source, contains('isDartSourceEntrypoint: sourceEntrypoint'));
    expect(source, contains('launcherExecutable: Platform.resolvedExecutable'));
    expect(source, contains('...launch.arguments.map(quoteForPosixShell)'));
    expect(source, contains('diagnostics.jsonl'));
    expect(source, contains('/usr/bin/osascript'));
    expect(source, contains('tell application "Terminal"'));
    expect(source, contains('Duration(seconds: 8)'));
    expect(source, contains('process.kill(ProcessSignal.sigterm)'));
  });

  test('explicit helper override remains authoritative', () {
    final source = entrypoint.readAsStringSync();

    expect(source, contains('if (options.helperPath != null)'));
    expect(source, contains('helperPath = options.helperPath!'));
    expect(source, contains('helperPath = await _resolveDefaultHelperPath()'));
    expect(source, isNot(contains('_parseOptions(arguments)')));
  });

  test('default helper rejects unsigned plain executables', () {
    final source = entrypoint.readAsStringSync();

    expect(source, contains('plain helper requires --helper'));
    expect(
      source,
      isNot(
        contains(
          "const _defaultHelperPath = 'macos_bridge/build/wearable_macos_bridge'",
        ),
      ),
    );
    expect(source, contains('No valid signed TUI helper bundle was found.'));
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

  test('entrypoint delegates option validation to the isolated launch contract',
      () {
    final source = entrypoint.readAsStringSync();

    expect(source, contains("src/entrypoint/tui_launch_options.dart"));
    expect(source, contains('--directed-mac'));
    expect(source, contains('--directed-name'));
    expect(source, contains('--directed-profile'));
    expect(source, contains('process-local Classic target'));
    expect(source, contains('press g'));
    expect(source, contains('exitCode = 64'));
  });
}
