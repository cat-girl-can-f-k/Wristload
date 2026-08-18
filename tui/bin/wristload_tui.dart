import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:wristload_tui/src/application/tui_application.dart';
import 'package:wristload_tui/src/backend_next/macos_tui_backend_adapter.dart';
import 'package:wristload_tui/src/backend_next/tui_json_line_transport.dart';
import 'package:wristload_tui/src/diagnostics/log_viewer.dart';
import 'package:wristload_tui/src/entrypoint/log_viewer_launch.dart';
import 'package:wristload_tui/src/entrypoint/tui_launch_options.dart';
import 'package:wristload_tui/src/ui_next/application_port_adapter.dart';
import 'package:wristload_tui/src/ui_next/console_terminal.dart';
import 'package:wristload_tui/src/ui_next/fixture_port.dart';
import 'package:wristload_tui/src/ui_next/shell.dart';

/// Relative path used by the package script for the signed staged bundle.
///
/// The plain CMake executable is intentionally not a production default: it
/// has no stable macOS bundle identity and may not have Bluetooth TCC access.
const _defaultHelperPath =
    'macos_bridge/build-bundle/stage/wearable_macos_bridge.app/Contents/MacOS/wearable_macos_bridge';
const _defaultHelperBundleRelativePaths = <String>[
  'macos_bridge/build-bundle/stage/wearable_macos_bridge.app',
  'macos_bridge/build/stage/wearable_macos_bridge.app',
];

/// macOS-only Wristload terminal application.
///
/// The default mode starts the independent replacement TUI. [--fixture] is
/// deliberately isolated from production Bluetooth work and uses synthetic
/// replacement-UI snapshots.
Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty && arguments.first == 'logs') {
    await runDiagnosticLogViewer(arguments.skip(1).toList());
    return;
  }
  final options = TuiLaunchOptions.parse(
    arguments,
    fixtureNames: UiNextFixtures.names,
  );
  if (options.showHelp) {
    _printHelp();
    return;
  }
  if (options.error != null) {
    stderr.writeln(options.error);
    stderr.writeln('Use --help for usage.');
    exitCode = 64;
    return;
  }

  if (!options.probe && !stdin.hasTerminal) {
    stderr.writeln('wristload_tui: 需要交互式终端。');
    stderr.writeln('在管道或非终端环境中无法运行 TUI。');
    exitCode = 1;
    return;
  }

  if (options.fixtureName != null) {
    await _runFixture(options.fixtureName!);
    return;
  }

  late final String helperPath;
  if (options.helperPath != null) {
    // Explicit overrides are a deliberate development escape hatch. The
    // default path below remains restricted to a signed app bundle.
    helperPath = options.helperPath!;
  } else {
    try {
      helperPath = await _resolveDefaultHelperPath();
    } on Object catch (error) {
      stderr
          .writeln('wristload_tui: cannot start the default Bluetooth helper.');
      stderr.writeln(error);
      stderr.writeln(
        'Use tui/macos_bridge/scripts/package_bundle.sh --ad-hoc to build a signed staged bundle, or pass --helper <path> explicitly.',
      );
      exitCode = 1;
      return;
    }
  }
  if (options.probe) {
    final transport = TuiJsonLineMacBluetoothTransport(
      executablePath: helperPath,
    );
    try {
      await transport.start();
      stdout.writeln('Helper probe OK: JSONL helper handshake succeeded.');
    } on Object catch (error) {
      stdout.writeln('Helper probe FAILED: $error');
      exitCode = 1;
    } finally {
      await transport.dispose();
    }
    return;
  }

  final backend = MacOsTuiBackendAdapter(helperPath: helperPath);

  // The replacement path is intentionally self-contained:
  // UiNextShell -> application -> TUI macOS backend -> JSONL native helper.
  // UiNextShell owns port disposal, which propagates through the application
  // layer to the backend and native helper on normal exit and failures.
  final application = TuiApplication(
    backend: backend,
    directedClassicTarget: options.directedClassicTarget,
  );
  final port = TuiApplicationUiPortAdapter(application: application);
  await UiNextShell(
    terminal: UiConsoleTerminal(),
    port: port,
    logViewerLauncher: _launchLogViewer,
  ).run();
}

Future<void> _runFixture(String fixtureName) async {
  final port = FakeUiNextPort(initial: UiNextFixtures.load(fixtureName));
  await UiNextShell(
    terminal: UiConsoleTerminal(),
    port: port,
    logViewerLauncher: _launchLogViewer,
  ).run();
}

Future<void> _launchLogViewer() async {
  if (!Platform.isMacOS) {
    throw UnsupportedError('诊断日志查看器仅支持 macOS Terminal。');
  }
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError(
      'HOME is unavailable; cannot locate the diagnostic journal.',
    );
  }
  final journalPath = File(
    '$home/Library/Application Support/WristloadTui/diagnostics.jsonl',
  ).absolute.path;
  final sourceEntrypoint = _isDartSourceEntrypoint();
  String? viewerPath;
  if (sourceEntrypoint) {
    final packageRoot = _entrypointPackageRoot();
    viewerPath = File(
      '${packageRoot.path}/bin/wristload_logs.dart',
    ).absolute.path;
    if (!File(viewerPath).existsSync()) {
      throw StateError('日志查看器脚本不存在：$viewerPath');
    }
  }
  final launch = buildDiagnosticLogViewerLaunch(
    launcherExecutable: Platform.resolvedExecutable,
    journalPath: journalPath,
    isDartSourceEntrypoint: sourceEntrypoint,
    logViewerSourcePath: viewerPath,
  );
  final command = <String>[
    quoteForPosixShell(launch.executable),
    ...launch.arguments.map(quoteForPosixShell),
  ].join(' ');
  final appleScript =
      'tell application "Terminal" to do script ${_appleScriptQuote(command)}\n'
      'tell application "Terminal" to activate';
  final process = await Process.start(
    '/usr/bin/osascript',
    <String>['-e', appleScript],
  );
  late int resultCode;
  try {
    resultCode = await process.exitCode.timeout(const Duration(seconds: 8));
  } on TimeoutException {
    process.kill(ProcessSignal.sigterm);
    throw TimeoutException(
      'macOS Terminal did not acknowledge the log viewer within 8 seconds.',
      const Duration(seconds: 8),
    );
  }
  if (resultCode != 0) {
    final message =
        (await process.stderr.transform(const Utf8Decoder()).join()).trim();
    throw ProcessException(
      '/usr/bin/osascript',
      const <String>[],
      message.isEmpty ? 'macOS Terminal did not open the log viewer.' : message,
      resultCode,
    );
  }
}

bool _isDartSourceEntrypoint() => Platform.script.path.endsWith('.dart');

Future<String> _resolveDefaultHelperPath() async {
  final packageRoot = _entrypointPackageRoot();
  final checked = <String>[];
  final rejected = <String>[];
  for (final relativeBundle in _defaultHelperBundleRelativePaths) {
    final bundle = Directory('${packageRoot.path}/$relativeBundle').absolute;
    final executable = File(
      '${bundle.path}/Contents/MacOS/wearable_macos_bridge',
    ).absolute;
    checked.add(bundle.path);
    if (!bundle.existsSync() || !executable.existsSync()) continue;
    if (!await _hasValidCodeSignature(bundle.path)) {
      rejected.add(bundle.path);
      continue;
    }
    return executable.path;
  }
  final suffix = rejected.isEmpty
      ? ''
      : ' Found unsigned or invalid bundles: ${rejected.join(', ')}.';
  throw StateError(
    'No valid signed TUI helper bundle was found. Checked: ${checked.join(', ')}.$suffix',
  );
}

Future<bool> _hasValidCodeSignature(String bundlePath) async {
  if (!Platform.isMacOS) return false;
  try {
    final result = await Process.run(
      '/usr/bin/codesign',
      <String>['--verify', '--strict', '--verbose=2', bundlePath],
    );
    return result.exitCode == 0;
  } on Object {
    return false;
  }
}

Directory _entrypointPackageRoot() {
  final scriptDirectory = File.fromUri(Platform.script).absolute.parent;
  for (var directory = scriptDirectory;
      directory.path != directory.parent.path;
      directory = directory.parent) {
    if (File('${directory.path}/pubspec.yaml').existsSync()) return directory;
  }
  final current = Directory.current.absolute;
  if (File('${current.path}/pubspec.yaml').existsSync()) return current;
  final nested = Directory('${current.path}/tui');
  if (File('${nested.path}/pubspec.yaml').existsSync()) return nested.absolute;
  return scriptDirectory;
}

String _appleScriptQuote(String value) =>
    '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

void _printHelp() {
  stdout.writeln('Wristload TUI (macOS only)');
  stdout.writeln('');
  stdout.writeln('Usage:');
  stdout.writeln('  dart run bin/wristload_tui.dart [options]');
  stdout.writeln('  wristload_tui logs [log options]');
  stdout.writeln('');
  stdout.writeln('Options:');
  stdout.writeln('  --helper <path>     Override the macOS bridge executable.');
  stdout.writeln(
      '  --probe             Start helper and check its protocol handshake only.');
  stdout.writeln('  --fixture <name>    Run a synthetic frontend preview.');
  stdout.writeln(
    '  --directed-mac <MAC> --directed-name <name> --directed-profile <profile>',
  );
  stdout.writeln(
    '                      Add one process-local Classic target; select it and press g.',
  );
  stdout.writeln('  -h, --help          Show this help.');
  stdout.writeln('');
  stdout.writeln(
    'Default helper: signed ${_defaultHelperPath} (plain helper requires --helper)',
  );
  stdout.writeln('Fixtures: ${UiNextFixtures.names.join(', ')}');
}
