import 'dart:io';

import 'install_metadata_reader.dart';
import 'install_models.dart';
import 'install_task.dart';

/// Prepares selected files for appending to an installation queue.
///
/// The implementation lives outside any page so the main queue and the
/// floating installation view enforce the same type, duplicate and metadata
/// rules.
typedef InstallMetadataLoader = Future<InstallMetadata> Function(
  InstallKind kind,
  String path,
);

class QueueFileImporter {
  QueueFileImporter({InstallMetadataLoader? metadataLoader})
      : _metadataLoader = metadataLoader ?? _readMetadata;

  final InstallMetadataLoader _metadataLoader;

  Future<QueueFileImportResult> prepare(
    Iterable<String> sourcePaths, {
    Iterable<String> existingPaths = const [],
  }) async {
    final knownPaths = {
      for (final path in existingPaths) normalizePath(path),
    };
    final requests = <InstallRequest>[];
    final failures = <QueueFileImportFailure>[];
    var duplicateCount = 0;
    var unsupportedCount = 0;

    for (final sourcePath in sourcePaths) {
      final path = File(sourcePath).absolute.path;
      final normalizedPath = normalizePath(path);
      if (knownPaths.contains(normalizedPath)) {
        duplicateCount++;
        continue;
      }

      final kind = kindForPath(path);
      if (kind == null) {
        unsupportedCount++;
        continue;
      }

      // Reserve before awaiting so duplicate paths from one drop stay unique.
      knownPaths.add(normalizedPath);
      try {
        final metadata = await _metadataLoader(kind, path);
        requests
            .add(InstallRequest(kind: kind, path: path, metadata: metadata));
      } on Object catch (error) {
        failures.add(QueueFileImportFailure(path: path, error: error));
      }
    }

    return QueueFileImportResult(
      requests: requests,
      duplicateCount: duplicateCount,
      unsupportedCount: unsupportedCount,
      failures: failures,
    );
  }

  static InstallKind? kindForPath(String path) {
    final extension = path.split('.').last.toLowerCase();
    return switch (extension) {
      'bin' || 'face' => InstallKind.watchface,
      'rpk' => InstallKind.quickApp,
      _ => null,
    };
  }

  static String normalizePath(String path) =>
      File(path).absolute.path.toLowerCase();

  static Future<InstallMetadata> _readMetadata(
    InstallKind kind,
    String path,
  ) =>
      InstallMetadataReader().read(kind, path);
}

class QueueFileImportResult {
  const QueueFileImportResult({
    required this.requests,
    required this.duplicateCount,
    required this.unsupportedCount,
    required this.failures,
  });

  final List<InstallRequest> requests;
  final int duplicateCount;
  final int unsupportedCount;
  final List<QueueFileImportFailure> failures;

  int get addedCount => requests.length;
}

class QueueFileImportFailure {
  const QueueFileImportFailure({required this.path, required this.error});

  final String path;
  final Object error;
}
