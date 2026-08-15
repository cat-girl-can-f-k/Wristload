import 'dart:io';

import 'package:wristload_tui/src/application/tui_application.dart';
import 'package:wristload_tui/src/backend_next/macos_tui_backend_adapter.dart';
import 'package:wristload_tui/src/backend_next/tui_json_line_transport.dart';
import 'package:wristload_tui/src/ui_next/application_port_adapter.dart';
import 'package:wristload_tui/src/ui_next/console_terminal.dart';
import 'package:wristload_tui/src/ui_next/fixture_port.dart';
import 'package:wristload_tui/src/ui_next/shell.dart';

const _defaultHelperPath = 'macos_bridge/build/wearable_macos_bridge';

/// macOS-only Wristload terminal application.
///
/// The default mode starts the independent replacement TUI. [--fixture] is
/// deliberately isolated from production Bluetooth work and uses synthetic
/// replacement-UI snapshots.
Future<void> main(List<String> arguments) async {
  final options = _parseOptions(arguments);
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

  final helperPath = options.helperPath ?? _defaultHelperPath;
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
  final application = TuiApplication(backend: backend);
  final port = TuiApplicationUiPortAdapter(application: application);
  await UiNextShell(
    terminal: UiConsoleTerminal(),
    port: port,
  ).run();
}

Future<void> _runFixture(String fixtureName) async {
  final port = FakeUiNextPort(initial: UiNextFixtures.load(fixtureName));
  await UiNextShell(
    terminal: UiConsoleTerminal(),
    port: port,
  ).run();
}

_Options _parseOptions(List<String> arguments) {
  String? helperPath;
  String? fixtureName;
  var probe = false;
  var showHelp = false;

  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == '--help' || argument == '-h') {
      showHelp = true;
    } else if (argument == '--probe') {
      probe = true;
    } else if (argument == '--helper') {
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        return const _Options(error: '--helper requires a path.');
      }
      helperPath = arguments[index];
    } else if (argument == '--fixture') {
      if (++index >= arguments.length || arguments[index].startsWith('-')) {
        return const _Options(error: '--fixture requires a fixture name.');
      }
      fixtureName = arguments[index];
    } else {
      return _Options(error: 'Unknown argument: ${argument}');
    }
  }

  if (probe && fixtureName != null) {
    return const _Options(error: '--probe cannot be combined with --fixture.');
  }
  if (fixtureName != null && !UiNextFixtures.names.contains(fixtureName)) {
    return _Options(
      error:
          'Unknown fixture: ${fixtureName}. Available: ${UiNextFixtures.names.join(', ')}',
    );
  }
  return _Options(
    helperPath: helperPath,
    fixtureName: fixtureName,
    probe: probe,
    showHelp: showHelp,
  );
}

void _printHelp() {
  stdout.writeln('Wristload TUI (macOS only)');
  stdout.writeln('');
  stdout.writeln('Usage:');
  stdout.writeln('  dart run bin/wristload_tui.dart [options]');
  stdout.writeln('');
  stdout.writeln('Options:');
  stdout.writeln('  --helper <path>     Override the macOS bridge executable.');
  stdout.writeln(
      '  --probe             Start helper and check its protocol handshake only.');
  stdout.writeln('  --fixture <name>    Run a synthetic frontend preview.');
  stdout.writeln('  -h, --help          Show this help.');
  stdout.writeln('');
  stdout.writeln('Default helper: ${_defaultHelperPath}');
  stdout.writeln('Fixtures: ${UiNextFixtures.names.join(', ')}');
}

class _Options {
  const _Options({
    this.helperPath,
    this.fixtureName,
    this.probe = false,
    this.showHelp = false,
    this.error,
  });

  final String? helperPath;
  final String? fixtureName;
  final bool probe;
  final bool showHelp;
  final String? error;
}
