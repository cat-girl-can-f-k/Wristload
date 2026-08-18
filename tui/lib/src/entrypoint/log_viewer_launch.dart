/// Describes the process Terminal should open for the diagnostic log viewer.
///
/// A source entrypoint needs the Dart executable plus a source script, while a
/// compiled executable must re-enter itself through the logs subcommand.
class DiagnosticLogViewerLaunch {
  const DiagnosticLogViewerLaunch({
    required this.executable,
    required this.arguments,
  });

  final String executable;
  final List<String> arguments;
}

DiagnosticLogViewerLaunch buildDiagnosticLogViewerLaunch({
  required String launcherExecutable,
  required String journalPath,
  required bool isDartSourceEntrypoint,
  String? logViewerSourcePath,
}) {
  const viewerArguments = <String>['--follow', '--file'];
  if (!isDartSourceEntrypoint) {
    return DiagnosticLogViewerLaunch(
      executable: launcherExecutable,
      arguments: <String>['logs', ...viewerArguments, journalPath],
    );
  }

  if (logViewerSourcePath == null || logViewerSourcePath.isEmpty) {
    throw ArgumentError.value(
      logViewerSourcePath,
      'logViewerSourcePath',
      'A Dart source entrypoint requires the log viewer source path.',
    );
  }
  return DiagnosticLogViewerLaunch(
    executable: launcherExecutable,
    arguments: <String>[
      'run',
      logViewerSourcePath,
      ...viewerArguments,
      journalPath,
    ],
  );
}

/// Quotes one argument for the POSIX shell command passed to macOS Terminal.
///
/// A single quote is represented by ending the quoted segment, emitting it in
/// a double-quoted segment, then resuming the single-quoted segment.
String quoteForPosixShell(String value) =>
    "'${value.replaceAll("'", "'\"'\"'")}'";
