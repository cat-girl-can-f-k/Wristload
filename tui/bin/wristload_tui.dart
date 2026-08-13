import 'dart:io';

import 'package:wristload_tui/src/facade/tui_facade.dart';
import 'package:wristload_tui/src/frontend/app/tui_app.dart';
import 'package:wristload_tui/src/frontend/fixtures/tui_fixtures.dart';
import 'package:wristload_tui/src/frontend/port/fake_tui_frontend_port.dart';
import 'package:wristload_tui/src/frontend/port/tui_snapshot.dart';
import 'package:wristload_tui/src/frontend/terminal/console_terminal.dart';

const _defaultHelperPath = 'macos_bridge/build/wearable_macos_bridge';

const _fixtureNames = <String>[
  'base',
  'scanFinished',
  'queueWaiting',
  'awaitingAuthKey',
  'rfcommRebuildRequired',
  'ready',
  'queueRunningTransfer',
  'awaitingDevice100',
  'installSucceeded',
  'installFailed',
  'installStateUnknown',
  'recoveryAvailable',
  'pendingDecisions',
  'logs',
];

/// macOS-only Wristload terminal application.
///
/// The default mode starts the production facade. [--fixture] is deliberately
/// isolated from it and uses only synthetic snapshots for frontend work.
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

  final facade = TuiFacade.macos(
    helperPath: options.helperPath ?? _defaultHelperPath,
  );
  try {
    if (options.probe) {
      final result = await facade.initialize();
      final status = result.accepted ? 'OK' : 'FAILED';
      stdout.writeln('Helper probe ${status}: ${result.message}');
      if (!result.accepted) exitCode = 1;
      return;
    }

    await TuiApp(
      terminal: ConsoleTerminal(),
      port: facade,
      previewLabel: '',
    ).run();
  } finally {
    await facade.dispose();
  }
}

Future<void> _runFixture(String fixtureName) async {
  final port = FakeTuiFrontendPort(initial: _loadFixture(fixtureName));
  try {
    await TuiApp(
      terminal: ConsoleTerminal(),
      port: port,
      previewLabel: 'FAKE PREVIEW - no Bluetooth or installation',
    ).run();
  } finally {
    await port.dispose();
  }
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
  if (fixtureName != null && !_fixtureNames.contains(fixtureName)) {
    return _Options(
      error:
          'Unknown fixture: ${fixtureName}. Available: ${_fixtureNames.join(', ')}',
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
  stdout.writeln('Fixtures: ${_fixtureNames.join(', ')}');
}

TuiSnapshot _loadFixture(String name) => switch (name) {
      'scanFinished' => TuiFixtures.scanFinished(),
      'queueWaiting' => TuiFixtures.queueWaiting(),
      'awaitingAuthKey' => TuiFixtures.awaitingAuthKey(),
      'rfcommRebuildRequired' => TuiFixtures.rfcommRebuildRequired(),
      'ready' => TuiFixtures.ready(),
      'queueRunningTransfer' => TuiFixtures.queueRunningTransfer(),
      'awaitingDevice100' => TuiFixtures.awaitingDevice100(),
      'installSucceeded' => TuiFixtures.installSucceeded(),
      'installFailed' => TuiFixtures.installFailed(),
      'installStateUnknown' => TuiFixtures.installStateUnknown(),
      'recoveryAvailable' => TuiFixtures.recoveryAvailable(),
      'pendingDecisions' => TuiFixtures.pendingDecisions(),
      'logs' => TuiFixtures.logs(),
      _ => TuiFixtures.base(),
    };

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
