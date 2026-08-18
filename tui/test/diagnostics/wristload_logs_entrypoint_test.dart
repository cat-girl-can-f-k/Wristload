import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File journal;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wristload-log-viewer-');
    journal = File('${directory.path}/diagnostics.jsonl');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('prints readable terminal lines and preserves JSON mode', () async {
    await journal.writeAsString(jsonEncode(<String, Object?>{
          'timestamp': '2026-08-15T08:00:00Z',
          'severity': 'info',
          'category': 'raw_rx',
          'component': 'wristload.RfcommDriver',
          'message': 'RFCOMM RX',
          'transport': 'classic-rfcomm',
          'endpoint': 'channel:7',
          'direction': 'rx',
          'byteCount': 3,
          'hex': 'ba dc fe',
        }) +
        '\n');

    final readable = await _runViewer(<String>[
      '--file',
      journal.path,
    ]);
    expect(readable.exitCode, 0);
    expect(readable.stdout, contains('[raw_rx]'));
    expect(readable.stdout, contains('transport=classic-rfcomm'));
    expect(readable.stdout, contains('hex=ba dc fe'));

    final raw = await _runViewer(<String>[
      '--json',
      '--file',
      journal.path,
    ]);
    expect(raw.exitCode, 0);
    expect(jsonDecode(raw.stdout.toString().trim()), isA<Map>());
  });

  test('the primary TUI entrypoint exposes the same logs subcommand', () async {
    await journal.writeAsString(jsonEncode(<String, Object?>{
          'timestamp': '2026-08-15T08:00:00Z',
          'severity': 'info',
          'category': 'system',
          'message': 'subcommand works',
        }) +
        '\n');

    final result = await Process.run(
      Platform.resolvedExecutable,
      <String>[
        'run',
        'bin/wristload_tui.dart',
        'logs',
        '--json',
        '--file',
        journal.path,
      ],
      workingDirectory: Directory.current.path,
    );

    expect(result.exitCode, 0);
    expect(jsonDecode(result.stdout.toString().trim()), isA<Map>());
  });

  test('help and explicit files do not require HOME', () async {
    await journal.writeAsString(jsonEncode(<String, Object?>{
          'timestamp': '2026-08-15T08:00:00Z',
          'severity': 'info',
          'category': 'system',
          'message': 'explicit journal works',
        }) +
        '\n');
    final environment = Map<String, String>.from(Platform.environment)
      ..remove('HOME');

    final help = await Process.run(
      Platform.resolvedExecutable,
      <String>['run', 'bin/wristload_logs.dart', '--help'],
      workingDirectory: Directory.current.path,
      environment: environment,
      includeParentEnvironment: false,
    );
    expect(help.exitCode, 0);
    expect(help.stdout, contains('Wristload TUI logs'));

    final explicitFile = await Process.run(
      Platform.resolvedExecutable,
      <String>['run', 'bin/wristload_logs.dart', '--file', journal.path],
      workingDirectory: Directory.current.path,
      environment: environment,
      includeParentEnvironment: false,
    );
    expect(explicitFile.exitCode, 0);
    expect(explicitFile.stdout, contains('explicit journal works'));
  });

  test('follow emits a record appended by an independent writer', () async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      <String>[
        'run',
        'bin/wristload_logs.dart',
        '--follow',
        '--file',
        journal.path
      ],
      workingDirectory: Directory.current.path,
    );
    addTearDown(() => process.kill(ProcessSignal.sigterm));
    final line = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await journal.writeAsString(jsonEncode(<String, Object?>{
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'severity': 'warning',
          'category': 'disconnect',
          'message': 'remote closed',
          'disconnectReason': 'remote',
        }) +
        '\n');

    expect(await line, contains('remote closed'));
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(const Duration(seconds: 5));
  });

  test('no options follows the default diagnostic journal', () async {
    final home = Directory('${directory.path}/home');
    final defaultJournal = File(
      '${home.path}/Library/Application Support/WristloadTui/diagnostics.jsonl',
    );
    await defaultJournal.parent.create(recursive: true);
    await defaultJournal.create();
    final environment = Map<String, String>.from(Platform.environment)
      ..['HOME'] = home.path;
    final process = await Process.start(
      Platform.resolvedExecutable,
      <String>['run', 'bin/wristload_logs.dart'],
      workingDirectory: Directory.current.path,
      environment: environment,
    );
    addTearDown(() => process.kill(ProcessSignal.sigterm));
    final line = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await defaultJournal.writeAsString(jsonEncode(<String, Object?>{
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'severity': 'info',
          'category': 'system',
          'message': 'default journal follows',
        }) +
        '\n');

    expect(await line, contains('default journal follows'));
    process.kill(ProcessSignal.sigterm);
    await process.exitCode.timeout(const Duration(seconds: 5));
  });
}

Future<ProcessResult> _runViewer(List<String> args) => Process.run(
      Platform.resolvedExecutable,
      <String>['run', 'bin/wristload_logs.dart', ...args],
      workingDirectory: Directory.current.path,
    );
