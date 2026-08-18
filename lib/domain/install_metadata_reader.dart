/// 本地安装文件元数据读取器。
///
/// 所有候选清单都在内存中读取；不会解压到目录，也不会复制源文件。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import 'install_models.dart';
import 'install_task.dart';
import 'device_profile.dart';
import '../application/diagnostic_log_service.dart';
import '../platform/security_scoped_file_access.dart';

class InstallMetadataReader {
  /// Wearable packages are normally far smaller. A hard upper bound prevents
  /// an accidental multi-gigabyte read while keeping ample room for media-rich
  /// RPKs and watchfaces.
  static const maxSourceBytes = 256 * 1024 * 1024;
  static const maxArchiveEntries = 512;
  static const maxArchiveExpandedBytes = 512 * 1024 * 1024;
  static const maxManifestBytes = 1024 * 1024;
  static const maxWatchfaceResourceBytes = 128 * 1024 * 1024;

  static final _packageName = RegExp(
    r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
  );

  Future<InstallMetadata> read(
    InstallKind kind,
    String path, {
    ScopedFileRef? source,
  }) async {
    appLogger.trace(
      '安装文件元数据读取开始',
      category: DiagnosticLogCategory.installation,
      fields: <String, Object?>{
        'kind': kind.name,
        'extension': _extension(path),
      },
    );
    try {
      final value = await SecurityScopedFileAccess.instance.withAccess(
        source ?? ScopedFileRef(path: path),
        (resolved) => _readResolved(kind, resolved.path),
      );
      appLogger.info(
        '安装文件元数据读取完成',
        category: DiagnosticLogCategory.installation,
        fields: <String, Object?>{
          'kind': kind.name,
          'fileSize': value.fileSize,
          'hasFaceId': value.faceId != null,
          'hasPackageName': value.packageName != null,
          'resolutionCount': value.watchfaceResolutions.length,
          'containsLua': value.containsLua,
        },
      );
      return value;
    } on Object catch (error) {
      appLogger.error(
        '安装文件元数据读取失败',
        category: DiagnosticLogCategory.installation,
        fields: <String, Object?>{
          'kind': kind.name,
          'errorType': error.runtimeType.toString(),
        },
      );
      rethrow;
    }
  }

  /// Reads metadata while the caller keeps [lease] open.
  ///
  /// This avoids a nested macOS security-scope acquisition when a higher-level
  /// importer already needs the resolved path for validation and deduplication.
  Future<InstallMetadata> readWithLease(
    InstallKind kind,
    SecurityScopedFileLease lease,
  ) async {
    appLogger.trace(
      '安装文件元数据读取开始（复用安全作用域）',
      category: DiagnosticLogCategory.installation,
      fields: <String, Object?>{'kind': kind.name},
    );
    try {
      final value = await _readResolved(kind, lease.file.path);
      appLogger.info(
        '安装文件元数据读取完成（复用安全作用域）',
        category: DiagnosticLogCategory.installation,
        fields: <String, Object?>{
          'kind': kind.name,
          'fileSize': value.fileSize,
        },
      );
      return value;
    } on Object catch (error) {
      appLogger.error(
        '安装文件元数据读取失败（复用安全作用域）',
        category: DiagnosticLogCategory.installation,
        fields: <String, Object?>{
          'kind': kind.name,
          'errorType': error.runtimeType.toString(),
        },
      );
      rethrow;
    }
  }

  Future<InstallMetadata> _readResolved(InstallKind kind, String path) async {
    final value = await Isolate.run<Map<String, Object?>>(
      () => _readMetadataInWorker(kind.index, path),
    );
    return InstallMetadata(
      fileName: value['fileName']! as String,
      fileSize: value['fileSize']! as int,
      md5Hex: value['md5Hex']! as String,
      sha256Hex: value['sha256Hex']! as String,
      faceId: value['faceId'] as String?,
      packageName: value['packageName'] as String?,
      versionCode: value['versionCode'] as int?,
      watchfaceResolutions: [
        for (final item in value['resolutions']! as List<Object?>)
          WatchfaceResolution(
            (item as List<Object?>)[0]! as int,
            item[1]! as int,
          ),
      ],
      containsLua: value['containsLua']! as bool,
    );
  }

  static String _extension(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final dot = name.lastIndexOf('.');
    return dot >= 0 && dot + 1 < name.length
        ? name.substring(dot + 1).toLowerCase()
        : '';
  }

  Future<InstallMetadata> _readDirect(InstallKind kind, String path) async {
    final file = File(path);
    final length = await file.length();
    if (length <= 0) throw const FormatException('安装文件为空');
    if (length > maxSourceBytes) {
      throw const FormatException('安装文件超过 256 MB 安全上限');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) throw const FormatException('安装文件为空');
    final fileName = path.split(RegExp(r'[/\\]')).last;
    final digest = md5.convert(bytes).toString();
    final strongDigest = sha256.convert(bytes).toString();
    return switch (kind) {
      InstallKind.watchface => _readWatchface(
        bytes,
        fileName,
        digest,
        strongDigest,
      ),
      InstallKind.quickApp => _readRpk(bytes, fileName, digest, strongDigest),
    };
  }

  InstallMetadata _readWatchface(
    Uint8List bytes,
    String fileName,
    String digest,
    String strongDigest,
  ) {
    final resource = _resourceFromArchive(bytes) ?? bytes;
    final faceId = _faceIdFromResource(resource);
    final inspection = _inspectWatchface(resource);
    return InstallMetadata(
      fileName: fileName,
      fileSize: bytes.length,
      md5Hex: digest,
      sha256Hex: strongDigest,
      faceId: faceId,
      watchfaceResolutions: inspection.resolutions,
      containsLua: inspection.containsLua,
    );
  }

  InstallMetadata _readRpk(
    Uint8List bytes,
    String fileName,
    String digest,
    String strongDigest,
  ) {
    final archive = decodeZipArchive(bytes, 'RPK');
    final isBinQuickApp = _extension(fileName) == 'bin';
    var hasManifest = false;
    var hasRuntime = false;
    final manifests = <({String packageName, int? versionCode})>[];
    for (final entry in archive.files) {
      final name = entry.name.toLowerCase();
      if (isBinQuickApp &&
          entry.isFile &&
          (name == 'app.js' ||
              name.endsWith('/app.js') ||
              name == 'app.jsc' ||
              name.endsWith('/app.jsc'))) {
        readVerifiedArchiveEntry(
          entry,
          maxWatchfaceResourceBytes,
          'Quick App 运行时文件',
        );
        hasRuntime = true;
      }
      if (!entry.isFile ||
          !(name == 'manifest.json' ||
              name.endsWith('/manifest.json') ||
              name == 'app.json')) {
        continue;
      }
      try {
        final isManifest =
            name == 'manifest.json' || name.endsWith('/manifest.json');
        final value = jsonDecode(
          utf8.decode(
            readVerifiedArchiveEntry(entry, maxManifestBytes, 'RPK 清单'),
          ),
        );
        if (isManifest) hasManifest = true;
        if (value is Map) {
          final manifest = value.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          final rawPackage =
              manifest['package'] ?? manifest['packageName'] ?? manifest['id'];
          if (rawPackage is! String || !_packageName.hasMatch(rawPackage)) {
            continue;
          }
          final rawVersion = manifest['versionCode'];
          final parsedVersion = rawVersion is int
              ? rawVersion
              : int.tryParse('$rawVersion');
          manifests.add((
            packageName: rawPackage,
            versionCode:
                parsedVersion != null &&
                    parsedVersion > 0 &&
                    parsedVersion <= maxRpkVersionCode
                ? parsedVersion
                : null,
          ));
        }
      } on FormatException {
        // 尝试下一个候选清单。
      }
    }
    if (isBinQuickApp && (!hasManifest || !hasRuntime)) {
      throw const FormatException(
        'BIN 快应用必须同时包含 manifest.json 与 app.js 或 app.jsc，已拒绝安装',
      );
    }
    if (manifests.isEmpty) {
      throw const FormatException('RPK 清单未包含有效包名，已拒绝安装');
    }
    final packageNames = manifests.map((item) => item.packageName).toSet();
    if (packageNames.length != 1) {
      throw const FormatException('RPK 包含互相冲突的包名，已拒绝安装');
    }
    final versions = manifests
        .map((item) => item.versionCode)
        .whereType<int>()
        .toSet();
    if (versions.length > 1) {
      throw const FormatException('RPK 清单包含互相冲突的版本号，已拒绝安装');
    }
    return InstallMetadata(
      fileName: fileName,
      fileSize: bytes.length,
      md5Hex: digest,
      sha256Hex: strongDigest,
      packageName: packageNames.single,
      versionCode: versions.firstOrNull,
    );
  }

  Uint8List? _resourceFromArchive(Uint8List bytes) {
    if (!_looksLikeZip(bytes)) return null;
    final archive = decodeZipArchive(bytes, '表盘');
    for (final entry in archive.files) {
      if (entry.isFile && entry.name.toLowerCase().endsWith('resource.bin')) {
        return Uint8List.fromList(
          readVerifiedArchiveEntry(
            entry,
            maxWatchfaceResourceBytes,
            '表盘 resource.bin',
          ),
        );
      }
    }
    return null;
  }

  bool _looksLikeZip(Uint8List bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07) &&
      (bytes[3] == 0x04 || bytes[3] == 0x06 || bytes[3] == 0x08);

  /// Decodes ZIP central-directory metadata within the shared installation
  /// package limits. Callers must CRC-check every entry they actually read via
  /// [readVerifiedArchiveEntry].
  static Archive decodeZipArchive(Uint8List bytes, String label) {
    try {
      // Do not use verify:true here: archive 3.x verifies by expanding every
      // entry, allowing an unrelated ZIP bomb entry to consume memory. Only
      // the selected manifest/resource entry is expanded and CRC-checked.
      final archive = ZipDecoder().decodeBytes(bytes, verify: false);
      if (archive.files.length > maxArchiveEntries) {
        throw const FormatException('ZIP 条目数量超过安全上限');
      }
      var expandedBytes = 0;
      for (final entry in archive.files) {
        if (entry.name.length > 1024 || entry.size < 0) {
          throw const FormatException('ZIP 条目元数据无效');
        }
        expandedBytes += entry.size;
        if (expandedBytes > maxArchiveExpandedBytes) {
          throw const FormatException('ZIP 声明的解压总量超过 512 MB 安全上限');
        }
      }
      return archive;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw FormatException('$label 不是可读取的 ZIP 容器');
    }
  }

  /// Expands a selected archive entry with a byte limit and verifies its CRC.
  static List<int> readVerifiedArchiveEntry(
    ArchiveFile entry,
    int limit,
    String label,
  ) {
    if (entry.size > limit) {
      throw FormatException('$label 超过安全上限');
    }
    final rawContent = entry.content;
    if (rawContent is! List<int>) {
      throw FormatException('$label 内容类型无效');
    }
    final content = rawContent;
    if (content.length > limit || content.length != entry.size) {
      throw FormatException('$label 解压长度无效');
    }
    final expectedCrc = entry.crc32;
    if (expectedCrc != null && getCrc32(content) != expectedCrc) {
      throw FormatException('$label CRC 校验失败');
    }
    return content;
  }

  /// Canonicalizes a ZIP file entry name and rejects paths that could escape
  /// the package root. Directory entries are intentionally handled by callers.
  static String? normalizeArchiveEntryPath(String input) {
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

  String? _faceIdFromResource(Uint8List bytes) {
    // 已验证的表盘工具从资源头部读取数值 ID。读取固定候选区并只接受数字，
    // 不把文件名或随机 UUID 冒充设备侧 faceId。
    if (bytes.length < 56 || bytes[0] != 0x5a || bytes[1] != 0xa5) return null;
    final raw = bytes.sublist(40, 56);
    final zero = raw.indexOf(0);
    final value = ascii
        .decode(
          raw.sublist(0, zero < 0 ? raw.length : zero),
          allowInvalid: true,
        )
        .trim();
    return RegExp(r'^\d+$').hasMatch(value) ? value : null;
  }

  ({List<WatchfaceResolution> resolutions, bool containsLua}) _inspectWatchface(
    Uint8List bytes,
  ) {
    const known = <WatchfaceResolution>[
      WatchfaceResolution(336, 480),
      WatchfaceResolution(212, 520),
      WatchfaceResolution(432, 514),
      WatchfaceResolution(464, 464),
    ];
    final resolutions = [
      for (final resolution in known)
        if (_containsResolution(bytes, resolution)) resolution,
    ];
    return (
      resolutions: resolutions,
      containsLua: _containsAsciiIgnoreCase(bytes, 'lua'),
    );
  }

  bool _containsResolution(Uint8List bytes, WatchfaceResolution resolution) {
    final width = resolution.width;
    final height = resolution.height;
    if (_containsAsciiIgnoreCase(bytes, '${width}x$height') ||
        _containsAsciiIgnoreCase(bytes, '$width*$height') ||
        _containsBytes(bytes, _utf16le('${width}x$height'))) {
      return true;
    }
    return _containsBytes(bytes, [
          width & 0xff,
          width >> 8,
          height & 0xff,
          height >> 8,
        ]) ||
        _containsBytes(bytes, [
          width & 0xff,
          width >> 8,
          0,
          0,
          height & 0xff,
          height >> 8,
          0,
          0,
        ]);
  }

  bool _containsAsciiIgnoreCase(Uint8List bytes, String value) {
    final pattern = ascii.encode(value.toLowerCase());
    if (bytes.length < pattern.length) return false;
    for (var offset = 0; offset <= bytes.length - pattern.length; offset++) {
      var matches = true;
      for (var index = 0; index < pattern.length; index++) {
        final byte = bytes[offset + index];
        final lower = byte >= 0x41 && byte <= 0x5a ? byte + 0x20 : byte;
        if (lower != pattern[index]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }

  bool _containsBytes(Uint8List bytes, List<int> pattern) {
    if (bytes.length < pattern.length) return false;
    for (var offset = 0; offset <= bytes.length - pattern.length; offset++) {
      var matches = true;
      for (var index = 0; index < pattern.length; index++) {
        if (bytes[offset + index] != pattern[index]) {
          matches = false;
          break;
        }
      }
      if (matches) return true;
    }
    return false;
  }

  List<int> _utf16le(String value) => [
    for (final unit in value.codeUnits) ...[unit & 0xff, unit >> 8],
  ];
}

/// Isolate boundary uses only primitives and lists. This avoids accidentally
/// capturing WidgetsBinding, BuildContext, file handles, or another unsendable
/// Flutter object in the worker message.
Future<Map<String, Object?>> _readMetadataInWorker(
  int kindIndex,
  String path,
) async {
  if (kindIndex < 0 || kindIndex >= InstallKind.values.length) {
    throw const FormatException('未知安装文件类型');
  }
  final metadata = await InstallMetadataReader()._readDirect(
    InstallKind.values[kindIndex],
    path,
  );
  return <String, Object?>{
    'fileName': metadata.fileName,
    'fileSize': metadata.fileSize,
    'md5Hex': metadata.md5Hex,
    'sha256Hex': metadata.sha256Hex,
    'faceId': metadata.faceId,
    'packageName': metadata.packageName,
    'versionCode': metadata.versionCode,
    'resolutions': <Object?>[
      for (final resolution in metadata.watchfaceResolutions)
        <Object?>[resolution.width, resolution.height],
    ],
    'containsLua': metadata.containsLua,
  };
}
