import 'dart:io';

import 'diagnostic_journal.dart';

/// Runs the standalone diagnostic journal viewer.
///
/// The script entrypoint and the compiled TUI logs subcommand share this code.
Future<void> runDiagnosticLogViewer(List<String> arguments) async {
  late final DiagnosticLogViewerOptions options;
  try {
    options = DiagnosticLogViewerOptions.parse(arguments);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln('Use --help for usage.');
    exitCode = 64;
    return;
  }
  if (options.help) {
    printDiagnosticLogViewerHelp();
    return;
  }

  final journalPath = options.path ?? _defaultDiagnosticJournalPath();
  final journal = DiagnosticJournal(File(journalPath));
  void write(DiagnosticEvent event) =>
      stdout.writeln(options.json ? event.toJsonLine() : event.displayText);
  if (options.follow) {
    await for (final event in journal.follow(initialLimit: options.tail)) {
      write(event);
    }
    return;
  }
  for (final event in await journal.read(limit: options.tail)) {
    write(event);
  }
}

void printDiagnosticLogViewerHelp() {
  stdout.writeln('Wristload TUI logs');
  stdout.writeln('Usage: wristload_tui logs [options]');
  stdout.writeln('   or: dart run bin/wristload_logs.dart [options]');
  stdout.writeln('  With no options, follows the default diagnostic journal.');
  stdout.writeln('  --follow        Keep following appended records.');
  stdout.writeln('  --file PATH     Read an explicit JSONL journal.');
  stdout.writeln(
      '  --tail COUNT    Show the newest COUNT records (default: 100).');
  stdout.writeln(
      '  --json          Emit JSONL instead of readable terminal lines.');
  stdout.writeln('  -h, --help      Show this help.');
}

class DiagnosticLogViewerOptions {
  const DiagnosticLogViewerOptions({
    required this.path,
    required this.follow,
    required this.json,
    required this.tail,
    required this.help,
  });

  factory DiagnosticLogViewerOptions.parse(List<String> args) {
    String? path;
    // Zero-argument invocation is the live diagnostic-log shortcut. Any
    // supplied option retains its explicit behavior unless it includes --follow.
    var follow = args.isEmpty;
    var json = false;
    var tail = 100;
    var help = false;
    for (var index = 0; index < args.length; index++) {
      switch (args[index]) {
        case '--follow':
          follow = true;
        case '--json':
          json = true;
        case '-h' || '--help':
          help = true;
        case '--file':
          if (++index >= args.length) {
            throw const FormatException('--file requires PATH.');
          }
          path = args[index];
        case '--tail':
          if (++index >= args.length) {
            throw const FormatException('--tail requires COUNT.');
          }
          tail = int.tryParse(args[index]) ?? -1;
          if (tail < 0) {
            throw const FormatException(
                '--tail must be a non-negative integer.');
          }
        default:
          throw FormatException('Unknown argument: ${args[index]}');
      }
    }
    return DiagnosticLogViewerOptions(
      path: path,
      follow: follow,
      json: json,
      tail: tail,
      help: help,
    );
  }

  /// An explicit journal path, if one was supplied.
  ///
  /// The default path intentionally stays unresolved until records are read so
  /// `--help` and `--file` remain usable in processes without HOME.
  final String? path;
  final bool follow;
  final bool json;
  final int tail;
  final bool help;
}

String _defaultDiagnosticJournalPath() {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError('HOME is unavailable; pass --file PATH.');
  }
  return '$home/Library/Application Support/WristloadTui/diagnostics.jsonl';
}
