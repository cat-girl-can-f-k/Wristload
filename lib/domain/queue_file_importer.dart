import 'dart:io';

import 'package:flutter/foundation.dart';

import 'install_metadata_reader.dart';
import 'install_file_classifier.dart';
import 'install_models.dart';
import 'install_task.dart';
import '../application/diagnostic_log_service.dart';
import '../platform/security_scoped_file_access.dart';

/// Prepares selected files for appending to an installation queue.
///
/// The implementation lives outside any page so the main queue and the
/// floating installation view enforce the same type, duplicate and metadata
/// rules.
typedef InstallMetadataLoader =
    Future<InstallMetadata> Function(InstallKind kind, String path);

typedef InstallFileClassificationLoader =
    Future<InstallableFileType> Function(String path);

class QueueFileImporter {
  QueueFileImporter({
    InstallMetadataLoader? metadataLoader,
    InstallFileClassificationLoader? classificationLoader,
  }) : _metadataLoader = metadataLoader,
       _classificationLoader = classificationLoader;

  final InstallMetadataLoader? _metadataLoader;
  final InstallFileClassificationLoader? _classificationLoader;

  Future<QueueFileImportResult> prepare(
    Iterable<Object> sourcePaths, {
    Iterable<String> existingPaths = const [],
    InstallKind? expectedKind,
  }) async {
    final sourceList = sourcePaths.toList(growable: false);
    final knownPaths = {for (final path in existingPaths) normalizePath(path)};
    appLogger.trace(
      '安装队列导入开始',
      category: DiagnosticLogCategory.installation,
      fields: <String, Object?>{
        'sourceCount': sourceList.length,
        'existingCount': knownPaths.length,
        'expectedKind': expectedKind?.name,
      },
    );
    final requests = <InstallRequest>[];
    final failures = <QueueFileImportFailure>[];
    var duplicateCount = 0;
    var unsupportedCount = 0;

    for (final input in sourceList) {
      final source = switch (input) {
        ScopedFileRef ref => ref,
        String path => ScopedFileRef(path: path),
        _ => throw ArgumentError.value(input, 'sourcePaths'),
      };
      final selectedPath = File(source.path).absolute.path;
      final normalizedSource = ScopedFileRef(
        path: selectedPath,
        bookmark: source.bookmark,
      );
      final isMacOS = defaultTargetPlatform == TargetPlatform.macOS;
      final shouldResolveMacBookmark = isMacOS && normalizedSource.hasBookmark;
      // A macOS bookmark may resolve a stale filename to a file whose current
      // extension is supported. Defer type filtering until after the lease is
      // acquired in that case. Unbookmarked external paths remain cheap
      // unsupported entries instead of prompting for access.
      final isSupported = isMacOS
          ? InstallFileClassifier.supportsPath(selectedPath) ||
                shouldResolveMacBookmark
          : kindForPath(selectedPath) != null;
      if (!isSupported) {
        unsupportedCount++;
        appLogger.warning(
          '安装队列导入跳过不支持的文件类型',
          category: DiagnosticLogCategory.installation,
          fields: <String, Object?>{'extension': _extension(selectedPath)},
        );
        continue;
      }
      var failurePath = selectedPath;
      try {
        if (isMacOS && !normalizedSource.hasBookmark) {
          throw StateError('拖入文件缺少 macOS 持久访问权限，请改用文件选择器');
        }
        final lease = await SecurityScopedFileAccess.instance.acquire(
          normalizedSource,
        );
        try {
          final resolvedPath = File(lease.file.path).absolute.path;
          failurePath = resolvedPath;
          final normalizedPath = normalizePath(resolvedPath);
          if (knownPaths.contains(normalizedPath)) {
            duplicateCount++;
            appLogger.info(
              '安装队列导入跳过重复文件',
              category: DiagnosticLogCategory.installation,
              fields: <String, Object?>{'extension': _extension(resolvedPath)},
            );
            continue;
          }

          final classification = isMacOS
              ? await _classifyResolved(resolvedPath)
              : _classificationForLegacyPath(resolvedPath);
          final kind = switch (classification) {
            InstallableFileType.quickApp => InstallKind.quickApp,
            InstallableFileType.watchface => InstallKind.watchface,
            InstallableFileType.firmware ||
            InstallableFileType.unsupported => null,
          };
          if (kind == null) {
            unsupportedCount++;
            appLogger.warning(
              '安装队列导入解析后类型不支持',
              category: DiagnosticLogCategory.installation,
              fields: <String, Object?>{
                'extension': _extension(resolvedPath),
                'classification': classification.name,
              },
            );
            continue;
          }
          if (expectedKind != null && kind != expectedKind) {
            throw const FormatException('解析后的文件类型与当前安装目标不一致，请重新选择文件');
          }

          // Reserve before metadata parsing so repeated sources in one import
          // remain unique while parsing awaits its worker isolate.
          knownPaths.add(normalizedPath);
          final loader = _metadataLoader;
          final metadata = loader == null
              ? await InstallMetadataReader().readWithLease(kind, lease)
              : await loader(kind, resolvedPath);
          final resolvedSource = ScopedFileRef(
            path: resolvedPath,
            bookmark: lease.file.bookmark,
          );
          final preparedRequest = InstallRequest(
            kind: kind,
            path: resolvedPath,
            metadata: metadata,
            source: resolvedSource,
          );
          requests.add(preparedRequest);
          appLogger.info(
            '安装队列文件元数据读取完成',
            category: DiagnosticLogCategory.installation,
            fields: <String, Object?>{
              'kind': kind.name,
              'fileSize': metadata.fileSize,
              'extension': _extension(resolvedPath),
            },
          );
        } finally {
          try {
            await lease.close();
          } on Object catch (error) {
            // Cleanup failure must not replace the import result. Do not log
            // paths or opaque bookmark contents.
            appLogger.error(
              '文件访问权限释放失败，已保留导入结果',
              category: DiagnosticLogCategory.security,
              fields: <String, Object?>{
                'errorType': error.runtimeType.toString(),
              },
            );
          }
        }
      } on Object catch (error) {
        failures.add(QueueFileImportFailure(path: failurePath, error: error));
        appLogger.error(
          '安装队列导入失败',
          category: DiagnosticLogCategory.installation,
          fields: <String, Object?>{
            'errorType': error.runtimeType.toString(),
            'extension': _extension(failurePath),
          },
        );
      }
    }
    appLogger.info(
      '安装队列导入完成',
      category: DiagnosticLogCategory.installation,
      fields: <String, Object?>{
        'addedCount': requests.length,
        'duplicateCount': duplicateCount,
        'unsupportedCount': unsupportedCount,
        'failureCount': failures.length,
      },
    );

    return QueueFileImportResult(
      requests: requests,
      duplicateCount: duplicateCount,
      unsupportedCount: unsupportedCount,
      failures: failures,
    );
  }

  /// Prepares one interactively selected file and fails instead of silently
  /// returning queue-import counters.
  Future<InstallRequest> prepareSingle(
    Object source, {
    required InstallKind expectedKind,
  }) async {
    final result = await prepare([source], expectedKind: expectedKind);
    if (result.failures.isNotEmpty) {
      throw result.failures.single.error;
    }
    if (result.unsupportedCount != 0) {
      throw const FormatException('不支持的安装文件类型');
    }
    if (result.requests.length != 1) {
      throw StateError('无法导入所选安装文件');
    }
    return result.requests.single;
  }

  /// Fast extension-only hint for non-macOS import paths.
  ///
  /// macOS callers must classify `.bin` content while holding a
  /// security-scoped lease. Other platforms retain the established extension
  /// contract and never read a `.bin` merely to determine its queue kind.
  static InstallKind? kindForPath(String path) {
    final extension = path.split('.').last.toLowerCase();
    return switch (extension) {
      'bin' || 'face' => InstallKind.watchface,
      'rpk' => InstallKind.quickApp,
      _ => null,
    };
  }

  static InstallableFileType _classificationForLegacyPath(String path) =>
      switch (kindForPath(path)) {
        InstallKind.quickApp => InstallableFileType.quickApp,
        InstallKind.watchface => InstallableFileType.watchface,
        null => InstallableFileType.unsupported,
      };

  Future<InstallableFileType> _classifyResolved(String path) {
    final loader = _classificationLoader;
    if (loader != null) return loader(path);
    // Existing tests and embedders may inject a metadata loader with virtual
    // paths. Preserve that seam without weakening real-file classification.
    if (_metadataLoader != null && !File(path).existsSync()) {
      final extension = _extension(path);
      if (extension == 'bin')
        return Future.value(InstallableFileType.watchface);
    }
    return const InstallFileClassifier().classifyResolvedPath(path);
  }

  static String normalizePath(String path) {
    final absolutePath = File(path).absolute.path;
    return defaultTargetPlatform == TargetPlatform.windows
        ? absolutePath.toLowerCase()
        : absolutePath;
  }

  static String _extension(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    return dot >= 0 && dot + 1 < name.length
        ? name.substring(dot + 1).toLowerCase()
        : '';
  }
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
