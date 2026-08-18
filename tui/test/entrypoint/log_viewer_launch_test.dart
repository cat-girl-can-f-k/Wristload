import 'dart:io';

import 'package:test/test.dart';
import 'package:wristload_tui/src/entrypoint/log_viewer_launch.dart';

void main() {
  test('source entrypoint launches the standalone Dart log viewer', () {
    final launch = buildDiagnosticLogViewerLaunch(
      launcherExecutable: '/opt/dart/bin/dart',
      journalPath: '/tmp/diagnostics.jsonl',
      isDartSourceEntrypoint: true,
      logViewerSourcePath: '/repo/tui/bin/wristload_logs.dart',
    );

    expect(launch.executable, '/opt/dart/bin/dart');
    expect(launch.arguments, <String>[
      'run',
      '/repo/tui/bin/wristload_logs.dart',
      '--follow',
      '--file',
      '/tmp/diagnostics.jsonl',
    ]);
  });

  test('compiled entrypoint re-enters its logs subcommand', () {
    final launch = buildDiagnosticLogViewerLaunch(
      launcherExecutable: '/repo/tui/build/wristload_tui',
      journalPath: '/tmp/diagnostics.jsonl',
      isDartSourceEntrypoint: false,
    );

    expect(launch.executable, '/repo/tui/build/wristload_tui');
    expect(launch.arguments, <String>[
      'logs',
      '--follow',
      '--file',
      '/tmp/diagnostics.jsonl',
    ]);
    expect(launch.arguments, isNot(contains('run')));
  });

  test('source entrypoint rejects a missing log viewer source path', () {
    expect(
      () => buildDiagnosticLogViewerLaunch(
        launcherExecutable: '/opt/dart/bin/dart',
        journalPath: '/tmp/diagnostics.jsonl',
        isDartSourceEntrypoint: true,
      ),
      throwsArgumentError,
    );
  });

  test('quotes apostrophes as one POSIX shell argument', () async {
    const original = "/tmp/wristload's diagnostics.jsonl";
    final quoted = quoteForPosixShell(original);

    expect(quoted, r"""'/tmp/wristload'"'"'s diagnostics.jsonl'""");

    final result = await Process.run(
      '/bin/sh',
      <String>[
        '-c',
        r'eval "set -- $1"; printf %s "$1"',
        '--',
        quoted,
      ],
    );
    expect(result.exitCode, 0);
    expect(result.stdout, original);
  });
}
