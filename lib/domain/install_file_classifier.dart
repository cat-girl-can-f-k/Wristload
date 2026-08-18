/// Content-based classification for files accepted by the macOS GUI installer.
///
/// File extensions are only used to limit which files are opened. A `.bin` ZIP
/// is inspected under the same archive limits as metadata extraction so a Quick
/// App cannot be mistaken for a watchface merely because of its suffix.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

import 'install_metadata_reader.dart';
import '../platform/security_scoped_file_access.dart';

enum InstallableFileType { firmware, quickApp, watchface, unsupported }

/// The result of inspecting a user-selected source.
///
/// On macOS [source] carries the resolved path and any security-scoped
/// bookmark refreshed while the archive was inspected. Callers that later
/// import the file must use this source instead of the original selection.
class InstallFileClassification {
  const InstallFileClassification({required this.type, required this.source});

  final InstallableFileType type;
  final ScopedFileRef source;
}

/// Identifies an installable source without extracting it to disk.
///
/// Firmware has precedence over Quick App because a firmware archive can carry
/// arbitrary application-like files but must never be sent through the app or
/// watchface transfer path.
class InstallFileClassifier {
  const InstallFileClassifier();

  /// Classifies [source] while acquiring its security-scoped macOS access.
  ///
  /// [classifySource] is preferred by flows which subsequently import the
  /// selection because it preserves an updated macOS bookmark.
  Future<InstallableFileType> classify(ScopedFileRef source) async =>
      (await classifySource(source)).type;

  /// Classifies [source] and returns the resolved source that was inspected.
  ///
  /// Resolving a stale bookmark can produce both a new path and a replacement
  /// bookmark. Returning them together prevents a later queue import from
  /// opening the original, stale bookmark again.
  Future<InstallFileClassification> classifySource(ScopedFileRef source) async {
    final lease = await SecurityScopedFileAccess.instance.acquire(source);
    try {
      return InstallFileClassification(
        type: await classifyWithLease(lease),
        source: lease.file,
      );
    } finally {
      await lease.close();
    }
  }

  /// Classifies a path while a higher-level importer already holds [lease].
  ///
  /// This avoids a nested security-scope acquisition for file-picker and drag
  /// sources on macOS.
  Future<InstallableFileType> classifyWithLease(
    SecurityScopedFileLease lease,
  ) => classifyResolvedPath(lease.file.path);

  /// Classifies an accessible path away from the UI isolate.
  Future<InstallableFileType> classifyResolvedPath(String path) =>
      Isolate.run(() => _classifySync(path));

  /// Whether a filename is eligible for content classification.
  ///
  /// A `.zip` is only accepted when its contents identify it as firmware.
  static bool supportsPath(String path) => switch (_extension(path)) {
    'bin' || 'face' || 'rpk' || 'zip' => true,
    _ => false,
  };

  static InstallableFileType _classifySync(String path) {
    switch (_extension(path)) {
      case 'rpk':
        return _classifyRpk(path);
      case 'face':
        return _classifyArchiveOrWatchface(path, '表盘安装包');
      case 'bin':
        return _classifyArchiveOrWatchface(path, 'BIN 安装包');
      case 'zip':
        return _classifyZip(path);
      default:
        return InstallableFileType.unsupported;
    }
  }

  /// `.bin` and `.face` may be raw watchface resources. If either is a ZIP,
  /// its contents always take precedence so firmware and Quick Apps cannot be
  /// misrouted by a filename suffix.
  static InstallableFileType _classifyArchiveOrWatchface(
    String path,
    String label,
  ) {
    final archive = _readZipArchive(path, label);
    if (archive == null) return InstallableFileType.watchface;
    return _classifyArchive(archive);
  }

  /// RPK is a ZIP-based container. A non-ZIP `.rpk` is never claimed to be a
  /// Quick App; a valid archive still follows the common firmware/Quick App/
  /// watchface precedence used by drag-and-drop.
  static InstallableFileType _classifyRpk(String path) {
    final archive = _readZipArchive(path, 'RPK 安装包');
    if (archive == null) {
      throw const FormatException('所选 .rpk 文件不是可读取的 ZIP 容器');
    }
    return _classifyArchive(archive);
  }

  static InstallableFileType _classifyZip(String path) {
    final archive = _readZipArchive(path, '固件 ZIP 包');
    if (archive == null) {
      throw const FormatException('所选 .zip 文件不是可读取的 ZIP 容器');
    }
    final type = _classifyArchive(archive);
    return type == InstallableFileType.firmware
        ? InstallableFileType.firmware
        : InstallableFileType.unsupported;
  }

  static Archive? _readZipArchive(String path, String label) {
    final file = File(path);
    final size = file.lengthSync();
    if (size <= 0) throw const FormatException('安装文件为空');
    if (size > InstallMetadataReader.maxSourceBytes) {
      throw const FormatException('安装文件超过 256 MB 安全上限');
    }

    final input = file.openSync(mode: FileMode.read);
    late Uint8List bytes;
    try {
      bytes = Uint8List.fromList(input.readSync(size));
    } finally {
      input.closeSync();
    }
    if (!_looksLikeZip(bytes)) return null;
    return InstallMetadataReader.decodeZipArchive(bytes, label);
  }

  static InstallableFileType _classifyArchive(Archive archive) {
    final entries = <String, ArchiveFile>{};
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final normalized = InstallMetadataReader.normalizeArchiveEntryPath(
        entry.name,
      );
      if (normalized == null) {
        throw FormatException('ZIP 包含不安全路径：${entry.name}');
      }
      final key = normalized.toLowerCase();
      if (entries.containsKey(key)) {
        throw FormatException('ZIP 包含重复路径：$normalized');
      }
      entries[key] = entry;
    }

    final otaEntries = _entriesNamed(entries, 'ota.sh');
    if (otaEntries.isNotEmpty) {
      for (final entry in otaEntries) {
        InstallMetadataReader.readVerifiedArchiveEntry(
          entry,
          InstallMetadataReader.maxManifestBytes,
          '固件 ota.sh',
        );
      }
      return InstallableFileType.firmware;
    }

    final manifests = _entriesNamed(entries, 'manifest.json');
    final runtimes = <ArchiveFile>[
      ..._entriesNamed(entries, 'app.js'),
      ..._entriesNamed(entries, 'app.jsc'),
    ];
    if (manifests.isNotEmpty && runtimes.isNotEmpty) {
      // Presence must refer to readable, CRC-valid file entries; merely
      // listing these names in ZIP metadata is insufficient.
      for (final entry in manifests) {
        InstallMetadataReader.readVerifiedArchiveEntry(
          entry,
          InstallMetadataReader.maxManifestBytes,
          'Quick App manifest.json',
        );
      }
      for (final entry in runtimes) {
        InstallMetadataReader.readVerifiedArchiveEntry(
          entry,
          InstallMetadataReader.maxWatchfaceResourceBytes,
          'Quick App 运行时文件',
        );
      }
      return InstallableFileType.quickApp;
    }

    return InstallableFileType.watchface;
  }

  static List<ArchiveFile> _entriesNamed(
    Map<String, ArchiveFile> entries,
    String name,
  ) => entries.entries
      .where((entry) => entry.key == name || entry.key.endsWith('/$name'))
      .map((entry) => entry.value)
      .toList(growable: false);

  static bool _looksLikeZip(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      ((bytes[2] == 0x03 && bytes[3] == 0x04) ||
          (bytes[2] == 0x05 && bytes[3] == 0x06) ||
          (bytes[2] == 0x07 && bytes[3] == 0x08));

  static String _extension(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    return dot < 0 || dot + 1 == name.length
        ? ''
        : name.substring(dot + 1).toLowerCase();
  }
}
