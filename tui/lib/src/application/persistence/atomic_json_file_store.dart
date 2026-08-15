/// Small atomic JSON file primitive for TUI-only application state.
///
/// The replacement never deletes the live file first: on macOS and other
/// POSIX systems, rename replaces it atomically, so a concurrent reader sees
/// either the complete previous JSON document or the complete new document.
library;

import 'dart:io';

/// Writes complete JSON documents using a sibling temporary file.
class AtomicJsonFileStore {
  AtomicJsonFileStore({
    File? file,
    Future<File> Function()? fileResolver,
  })  : assert(
          file != null || fileResolver != null,
          'Either file or fileResolver is required.',
        ),
        assert(
          file == null || fileResolver == null,
          'Specify file or fileResolver, not both.',
        ),
        _fileResolver = fileResolver ?? (() async => file!);

  final Future<File> Function() _fileResolver;

  Future<String?> read() async {
    final file = await _fileResolver();
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  Future<void> write(String contents) async {
    final file = await _fileResolver();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');

    await temporary.writeAsString(contents, flush: true);
    try {
      // POSIX rename atomically replaces the target without an observable
      // missing-file interval. The TUI only supports macOS at runtime.
      await temporary.rename(file.path);
    } on Object {
      // Do not include document contents in failures: callers may persist
      // device metadata and should not accidentally turn it into diagnostics.
      if (await temporary.exists()) {
        await temporary.delete();
      }
      rethrow;
    }
  }
}
