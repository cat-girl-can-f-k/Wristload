/// 安装任务的纯数据模型。
///
/// 模型不包含 authkey、会话密钥或文件副本，因此可安全用于可恢复检查点。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'install_task.dart';
import 'device_profile.dart';
import '../platform/security_scoped_file_access.dart';

/// The official install API carries versionCode as a signed 32-bit integer.
const int maxRpkVersionCode = 0x7fffffff;

class InstallMetadata {
  const InstallMetadata({
    required this.fileName,
    required this.fileSize,
    required this.md5Hex,
    required this.sha256Hex,
    this.faceId,
    this.packageName,
    this.versionCode,
    this.watchfaceResolutions = const [],
    this.containsLua = false,
  });

  final String fileName;
  final int fileSize;
  final String md5Hex;
  final String sha256Hex;
  final String? faceId;
  final String? packageName;
  final int? versionCode;
  final List<WatchfaceResolution> watchfaceResolutions;
  final bool containsLua;

  InstallMetadata copyWith({
    String? faceId,
    int? versionCode,
  }) =>
      InstallMetadata(
        fileName: fileName,
        fileSize: fileSize,
        md5Hex: md5Hex,
        sha256Hex: sha256Hex,
        faceId: faceId ?? this.faceId,
        packageName: packageName,
        versionCode: versionCode ?? this.versionCode,
        watchfaceResolutions: watchfaceResolutions,
        containsLua: containsLua,
      );
}

class InstallRequest {
  const InstallRequest({
    required this.kind,
    required this.path,
    required this.metadata,
    this.source,
    this.unsupportedLuaConfirmed = false,
    this.watchfaceResolutionConfirmed = false,
  });

  final InstallKind kind;
  final String path;
  final InstallMetadata metadata;
  final ScopedFileRef? source;
  final bool unsupportedLuaConfirmed;
  final bool watchfaceResolutionConfirmed;

  /// Updates interactive install choices without discarding the resolved
  /// path and persistent file-access bookmark.
  InstallRequest copyWith({
    InstallMetadata? metadata,
    bool? unsupportedLuaConfirmed,
    bool? watchfaceResolutionConfirmed,
  }) =>
      InstallRequest(
        kind: kind,
        path: path,
        metadata: metadata ?? this.metadata,
        source: source,
        unsupportedLuaConfirmed:
            unsupportedLuaConfirmed ?? this.unsupportedLuaConfirmed,
        watchfaceResolutionConfirmed:
            watchfaceResolutionConfirmed ?? this.watchfaceResolutionConfirmed,
      );
}

/// 只保存已确认状态，用于断线后重新协商断点；绝不保存密钥或文件内容。
class InstallCheckpoint {
  const InstallCheckpoint({
    required this.kind,
    required this.path,
    required this.fileSize,
    required this.md5Hex,
    required this.sha256Hex,
    required this.dataType,
    required this.lastAcknowledgedSegment,
    required this.phase,
    this.faceId,
    this.packageName,
    this.versionCode,
    this.bookmark,
  });

  final InstallKind kind;
  final String path;
  final int fileSize;
  final String md5Hex;
  final String sha256Hex;
  final int dataType;
  final int lastAcknowledgedSegment;
  final String phase;
  final String? faceId;
  final String? packageName;
  final int? versionCode;
  final Uint8List? bookmark;

  Map<String, Object?> toJson() => {
        'kind': kind == InstallKind.watchface ? 'watchface' : 'quickapp',
        'path': path,
        'fileSize': fileSize,
        'md5Hex': md5Hex,
        'sha256Hex': sha256Hex,
        'dataType': dataType,
        'lastAcknowledgedSegment': lastAcknowledgedSegment,
        'phase': phase,
        'faceId': faceId,
        'packageName': packageName,
        'versionCode': versionCode,
        if (bookmark != null) 'bookmark': base64Encode(bookmark!),
      };

  /// 解析检查点 JSON；字段缺失或越界时返回 null（不可恢复）。
  static InstallCheckpoint? fromJson(Map<String, Object?> value) {
    final kind = switch (value['kind']) {
      'watchface' => InstallKind.watchface,
      'quickapp' || 'quickApp' => InstallKind.quickApp,
      _ => null,
    };
    final pathValue = value['path'];
    final fileSizeValue = value['fileSize'];
    final md5Value = value['md5Hex'];
    final sha256Value = value['sha256Hex'];
    final dataTypeValue = value['dataType'];
    final segmentValue = value['lastAcknowledgedSegment'];
    final phaseValue = value['phase'];
    final faceIdValue = value['faceId'];
    final packageNameValue = value['packageName'];
    final versionCodeValue = value['versionCode'];
    final expectedDataType = kind == InstallKind.watchface ? 0x10 : 0x40;
    if (kind == null ||
        pathValue is! String ||
        pathValue.isEmpty ||
        fileSizeValue is! int ||
        fileSizeValue <= 0 ||
        md5Value is! String ||
        !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(md5Value) ||
        sha256Value is! String ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256Value) ||
        dataTypeValue is! int ||
        dataTypeValue != expectedDataType ||
        segmentValue is! int ||
        segmentValue < 0 ||
        phaseValue is! String ||
        (phaseValue != 'transferring' && phaseValue != 'awaitingDevice') ||
        (faceIdValue != null && faceIdValue is! String) ||
        (packageNameValue != null && packageNameValue is! String) ||
        (versionCodeValue != null && versionCodeValue is! int)) {
      return null;
    }
    Uint8List? bookmark;
    final encodedBookmark = value['bookmark'];
    if (encodedBookmark != null) {
      if (encodedBookmark is! String ||
          encodedBookmark.length > maxSecurityScopedBookmarkBytes * 2) {
        return null;
      }
      try {
        bookmark = Uint8List.fromList(base64Decode(encodedBookmark));
      } on FormatException {
        return null;
      }
      if (bookmark.isEmpty ||
          bookmark.length > maxSecurityScopedBookmarkBytes) return null;
    }
    return InstallCheckpoint(
      kind: kind,
      path: pathValue,
      fileSize: fileSizeValue,
      md5Hex: md5Value.toLowerCase(),
      sha256Hex: sha256Value.toLowerCase(),
      dataType: dataTypeValue,
      lastAcknowledgedSegment: segmentValue,
      phase: phaseValue,
      faceId: faceIdValue as String?,
      packageName: packageNameValue as String?,
      versionCode: versionCodeValue as int?,
      bookmark: bookmark,
    );
  }
}

/// 安装队列条目状态。
enum QueueStage { waiting, installing, done, failed, cancelled, stateUnknown }

/// 安装队列条目（主页选择文件后入队，队列页串行执行）。
class QueueEntry {
  QueueEntry({required this.request, this.stage = QueueStage.waiting});

  InstallRequest request;
  QueueStage stage;
  String? message;
  int failureAttempts = 0;

  bool get isFailure =>
      stage == QueueStage.failed ||
      stage == QueueStage.cancelled ||
      stage == QueueStage.stateUnknown;

  /// Failed packages stay available until the user removes them. Retrying sends
  /// the same package again and lets MassPrepare negotiate a device-side resume
  /// offset, rather than silently dropping the item after a fixed attempt cap.
  bool get canRetry => isFailure;
}

/// Result of the debug cleanup probe that follows a cancelled installation.
/// The device reports status 1 while it is still disposing the previous
/// transfer; the probe stops at the first different status.
class DebugCleanupReport {
  const DebugCleanupReport({
    required this.startedAt,
    required this.finishedAt,
    required this.pollCount,
    required this.finalStatus,
    this.error,
  });

  final DateTime startedAt;
  final DateTime finishedAt;
  final int pollCount;
  final int? finalStatus;
  final String? error;

  Duration get elapsed => finishedAt.difference(startedAt);
  bool get completed => error == null;
}
