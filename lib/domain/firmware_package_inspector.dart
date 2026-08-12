import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';

/// Read-only metadata extracted from a Xiaomi wearable firmware container.
///
/// [transmissionSupported] deliberately remains false until the independent
/// OTA channel has been verified from device-specific captures.
class FirmwarePackageInspection {
  FirmwarePackageInspection({
    required this.fileName,
    required this.fileSize,
    required this.entryCount,
    required this.declaredExpandedBytes,
    required this.manifestName,
    required this.target,
    required this.softwareVersion,
    required this.firmwareType,
    required List<String> partitionFiles,
    required List<String> referencedFiles,
    required List<String> missingFiles,
    required List<String> signatureFiles,
    required List<String> warnings,
    required List<String> errors,
  })  : partitionFiles = List.unmodifiable(partitionFiles),
        referencedFiles = List.unmodifiable(referencedFiles),
        missingFiles = List.unmodifiable(missingFiles),
        signatureFiles = List.unmodifiable(signatureFiles),
        warnings = List.unmodifiable(warnings),
        errors = List.unmodifiable(errors);

  final String fileName;
  final int fileSize;
  final int entryCount;
  final int declaredExpandedBytes;
  final String? manifestName;
  final String? target;
  final String? softwareVersion;
  final String? firmwareType;
  final List<String> partitionFiles;
  final List<String> referencedFiles;
  final List<String> missingFiles;
  final List<String> signatureFiles;
  final List<String> warnings;
  final List<String> errors;

  bool get isRecognized => manifestName != null;

  bool get packageStructureValid => isRecognized && errors.isEmpty;

  bool get hasSignatureMaterial => signatureFiles.isNotEmpty;

  bool get hasCompleteSignatureSet {
    final names = signatureFiles.map((name) => name.toLowerCase()).toSet();
    return names.any((name) => name.endsWith('/manifest.mf')) &&
        names.any((name) => name.endsWith('.sf')) &&
        names.any((name) => name.endsWith('.rsa'));
  }

  /// OTA transmission is intentionally unavailable while channel 6 is not
  /// documented by a complete, device-specific capture.
  bool get transmissionSupported => false;
}

class FirmwarePackageInspector {
  const FirmwarePackageInspector({
    this.maxArchiveBytes = 2 * 1024 * 1024 * 1024,
    this.maxEntries = 2048,
    this.maxExpandedBytes = 2 * 1024 * 1024 * 1024,
    this.maxManifestBytes = 1024 * 1024,
  });

  final int maxArchiveBytes;
  final int maxEntries;
  final int maxExpandedBytes;
  final int maxManifestBytes;

  /// Runs parsing away from the UI isolate. Only the selected manifest is
  /// decompressed; partition images remain untouched.
  Future<FirmwarePackageInspection> inspect(String path) =>
      Isolate.run(() => inspectSync(path));

  FirmwarePackageInspection inspectSync(String path) {
    final extension = _extension(path);
    if (extension != 'zip' && extension != 'bin') {
      throw const FormatException('固件包仅支持 .zip / .bin');
    }

    final file = File(path);
    if (!file.existsSync()) {
      throw const FormatException('固件文件不存在');
    }
    final fileSize = file.lengthSync();
    if (fileSize < 4) {
      throw const FormatException('固件文件过短，不是 ZIP 容器');
    }
    if (fileSize > maxArchiveBytes) {
      throw FormatException(
        '固件包超过 ${_formatBytes(maxArchiveBytes)} 安全上限',
      );
    }

    final header = file.openSync(mode: FileMode.read);
    late List<int> signature;
    try {
      signature = header.readSync(4);
    } finally {
      header.closeSync();
    }
    if (!_hasZipSignature(signature)) {
      throw const FormatException('所选文件不是 ZIP 固件容器');
    }

    final input = InputFileStream(path, bufferSize: 64 * 1024);
    try {
      final decoder = ZipDecoder();
      final archive = decoder.decodeBuffer(input, verify: false);
      final directoryEntryCount = decoder.directory.fileHeaders.length;
      if (directoryEntryCount > maxEntries) {
        throw FormatException('ZIP 条目数量超过 $maxEntries 项安全上限');
      }
      return _inspectArchive(
        archive,
        fileName: _fileName(path),
        fileSize: fileSize,
        directoryEntryCount: directoryEntryCount,
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('固件包不是可读取的 ZIP 容器');
    } finally {
      input.closeSync();
    }
  }

  FirmwarePackageInspection _inspectArchive(
    Archive archive, {
    required String fileName,
    required int fileSize,
    required int directoryEntryCount,
  }) {
    final entries = <String, ArchiveFile>{};
    final displayNames = <String, String>{};
    final errors = <String>[];
    final warnings = <String>[];
    var expandedBytes = 0;

    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      if (entry.name.length > 1024 || entry.size < 0) {
        throw const FormatException('ZIP 条目元数据无效');
      }
      final normalized = _normalizeEntryName(entry.name);
      if (normalized == null) {
        errors.add('ZIP 包含不安全路径：${entry.name}');
        continue;
      }
      expandedBytes += entry.size;
      if (expandedBytes > maxExpandedBytes) {
        throw FormatException(
          'ZIP 声明的解压总量超过 ${_formatBytes(maxExpandedBytes)} 安全上限',
        );
      }
      final key = normalized.toLowerCase();
      if (entries.containsKey(key)) {
        errors.add('ZIP 包含重复路径：$normalized');
        continue;
      }
      entries[key] = entry;
      displayNames[key] = normalized;
    }

    final jsonManifests = _findManifestKeys(entries, 'ota.json');
    final shellManifests = _findManifestKeys(entries, 'ota.sh');
    String? manifestKey;
    if (jsonManifests.isNotEmpty) {
      manifestKey = jsonManifests.first;
      if (jsonManifests.length > 1) {
        errors.add('固件包包含多个 ota.json 清单');
      }
      if (shellManifests.isNotEmpty) {
        warnings.add('同时发现 ota.json 与 ota.sh，优先读取 ota.json');
      }
    } else if (shellManifests.isNotEmpty) {
      manifestKey = shellManifests.first;
      if (shellManifests.length > 1) {
        errors.add('固件包包含多个 ota.sh 清单');
      }
    }

    final allBinFiles = displayNames.entries
        .where((entry) => entry.key.endsWith('.bin'))
        .map((entry) => entry.value)
        .toList()
      ..sort();
    final signatureFiles = displayNames.entries
        .where((entry) {
          final name = entry.key;
          return name.startsWith('meta-inf/') &&
              (name.endsWith('/manifest.mf') ||
                  name.endsWith('.sf') ||
                  name.endsWith('.rsa'));
        })
        .map((entry) => entry.value)
        .toList()
      ..sort();

    String? target;
    String? softwareVersion;
    String? firmwareType;
    final referencedFiles = <String>[];
    final resolvedPartitions = <String>[];
    final missingFiles = <String>[];

    if (manifestKey == null) {
      errors.add('未找到 ota.json 或 ota.sh 固件清单');
    } else {
      final manifestEntry = entries[manifestKey]!;
      try {
        final manifestText = _readTextEntry(manifestEntry);
        if (manifestKey.endsWith('ota.json')) {
          final parsed = _parseJsonManifest(manifestText);
          target = parsed.target;
          softwareVersion = parsed.softwareVersion;
          firmwareType = parsed.firmwareType;
          referencedFiles.addAll(parsed.references);
        } else {
          referencedFiles.addAll(_parseShellReferences(manifestText));
          if (referencedFiles.isEmpty) {
            warnings.add('ota.sh 未识别到明确分区引用，将仅列出包内 .bin 文件');
          }
        }
      } on FormatException catch (error) {
        errors.add(error.message);
      }

      final manifestDirectory = manifestKey.contains('/')
          ? manifestKey.substring(0, manifestKey.lastIndexOf('/') + 1)
          : '';
      for (final reference in referencedFiles) {
        final normalized = _normalizeReference(reference);
        if (normalized == null) {
          missingFiles.add(reference);
          continue;
        }
        final direct = normalized.toLowerCase();
        final relative = '$manifestDirectory$normalized'.toLowerCase();
        final resolvedKey = entries.containsKey(direct)
            ? direct
            : entries.containsKey(relative)
                ? relative
                : null;
        if (resolvedKey == null) {
          missingFiles.add(reference);
        } else {
          final resolved = displayNames[resolvedKey]!;
          if (!resolvedPartitions.contains(resolved)) {
            resolvedPartitions.add(resolved);
          }
        }
      }
    }

    if (allBinFiles.isEmpty) {
      errors.add('固件包内未发现分区 .bin 文件');
    }
    if (missingFiles.isNotEmpty) {
      errors.add('清单引用了 ${missingFiles.length} 个不存在的文件');
    }
    if (signatureFiles.isNotEmpty) {
      warnings.add('仅发现签名材料，尚未验证证书链或包签名');
    } else {
      warnings.add('未发现 META-INF 签名材料');
    }

    return FirmwarePackageInspection(
      fileName: fileName,
      fileSize: fileSize,
      entryCount: directoryEntryCount,
      declaredExpandedBytes: expandedBytes,
      manifestName: manifestKey == null ? null : displayNames[manifestKey],
      target: target,
      softwareVersion: softwareVersion,
      firmwareType: firmwareType,
      partitionFiles:
          resolvedPartitions.isEmpty ? allBinFiles : resolvedPartitions,
      referencedFiles: referencedFiles,
      missingFiles: missingFiles,
      signatureFiles: signatureFiles,
      warnings: warnings,
      errors: errors,
    );
  }

  String _readTextEntry(ArchiveFile entry) {
    if (entry.size > maxManifestBytes) {
      throw FormatException(
        '固件清单超过 ${_formatBytes(maxManifestBytes)} 安全上限',
      );
    }
    final raw = entry.content;
    if (raw is! List<int> || raw.length != entry.size) {
      throw const FormatException('固件清单解压长度无效');
    }
    final expectedCrc = entry.crc32;
    if (expectedCrc != null && getCrc32(raw) != expectedCrc) {
      throw const FormatException('固件清单 CRC 校验失败');
    }
    try {
      return utf8.decode(raw);
    } on FormatException {
      throw const FormatException('固件清单不是有效 UTF-8 文本');
    }
  }

  _JsonManifestData _parseJsonManifest(String text) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const FormatException('ota.json 格式无效');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('ota.json 根节点必须为对象');
    }

    final references = <String>[];
    final sections = decoded['sections'];
    if (sections is List) {
      for (final section in sections) {
        if (section is! Map) continue;
        final value = section['location_path'];
        if (value is String && value.trim().isNotEmpty) {
          final reference = value.trim();
          if (!references.contains(reference)) references.add(reference);
        }
      }
    }

    return _JsonManifestData(
      target: _firstString(decoded, const [
        'magic_string',
        'device_model',
        'device',
        'product',
        'target',
      ]),
      softwareVersion: _firstString(decoded, const [
        'sw_version',
        'firmware_version',
        'version',
        'ota_version',
      ]),
      firmwareType: _firstString(decoded, const ['firmware_type']),
      references: references,
    );
  }

  List<String> _parseShellReferences(String text) {
    final references = <String>[];
    final pattern = RegExp(
      r'/ota/([A-Za-z0-9._+\/-]+\.bin)\b',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(text)) {
      final value = match.group(1)!.replaceAll('\\', '/');
      if (!references.contains(value)) references.add(value);
    }
    return references;
  }

  List<String> _findManifestKeys(
    Map<String, ArchiveFile> entries,
    String fileName,
  ) {
    final result = entries.keys
        .where((key) => key == fileName || key.endsWith('/$fileName'))
        .toList();
    result.sort((a, b) {
      if (a == fileName) return -1;
      if (b == fileName) return 1;
      return a.compareTo(b);
    });
    return result;
  }

  static String? _firstString(
    Map<String, dynamic> object,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = object[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
      if (value is num || value is bool) return value.toString();
    }
    return null;
  }

  static String? _normalizeEntryName(String input) {
    var name = input.replaceAll('\\', '/');
    while (name.startsWith('./')) {
      name = name.substring(2);
    }
    if (name.isEmpty ||
        name.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(name)) {
      return null;
    }
    final parts = name.split('/');
    if (parts.any((part) => part == '..' || part.isEmpty)) return null;
    return parts.where((part) => part != '.').join('/');
  }

  static String? _normalizeReference(String input) {
    var value = input.trim().replaceAll('\\', '/');
    while (value.startsWith('./')) {
      value = value.substring(2);
    }
    if (value.startsWith('/ota/')) value = value.substring(5);
    if (value.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(value)) {
      return null;
    }
    final parts = value.split('/');
    if (parts.any((part) => part == '..' || part.isEmpty)) return null;
    return parts.where((part) => part != '.').join('/');
  }

  static bool _hasZipSignature(List<int> bytes) =>
      bytes.length == 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      ((bytes[2] == 0x03 && bytes[3] == 0x04) ||
          (bytes[2] == 0x05 && bytes[3] == 0x06) ||
          (bytes[2] == 0x07 && bytes[3] == 0x08));

  static String _extension(String path) {
    final name = _fileName(path);
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
  }

  static String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
}

class _JsonManifestData {
  const _JsonManifestData({
    required this.target,
    required this.softwareVersion,
    required this.firmwareType,
    required this.references,
  });

  final String? target;
  final String? softwareVersion;
  final String? firmwareType;
  final List<String> references;
}
