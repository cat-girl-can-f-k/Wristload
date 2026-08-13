/// 安装任务的纯数据模型。
///
/// 模型不包含 authkey、会话密钥或文件副本，因此可安全用于可恢复检查点。
library;

import 'install_task.dart';
import 'device_profile.dart';

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
    this.unsupportedLuaConfirmed = false,
    this.watchfaceResolutionConfirmed = false,
  });

  final InstallKind kind;
  final String path;
  final InstallMetadata metadata;
  final bool unsupportedLuaConfirmed;
  final bool watchfaceResolutionConfirmed;
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
      };

  /// 解析检查点 JSON；字段缺失或越界时返回 null（不可恢复）。
  static InstallCheckpoint? fromJson(Map<String, Object?> value) {
    final kindValue = value['kind'] as String? ?? 'watchface';
    final md5Value = value['md5Hex'] as String?;
    final sha256Value = value['sha256Hex'] as String?;
    final pathValue =
        (value['path'] as String?) ?? (value['fileName'] as String?);
    final fileSizeValue = (value['fileSize'] as num?)?.toInt();
    final dataTypeValue = (value['dataType'] as num?)?.toInt();
    final segmentValue = (value['lastAcknowledgedSegment'] as num?)?.toInt();
    final phaseValue = value['phase'] as String?;
    if (md5Value == null ||
        sha256Value == null ||
        pathValue == null ||
        fileSizeValue == null ||
        fileSizeValue < 0 ||
        dataTypeValue == null ||
        dataTypeValue < 0 ||
        dataTypeValue > 0x40 ||
        segmentValue == null ||
        segmentValue < 0 ||
        phaseValue == null) {
      return null;
    }
    return InstallCheckpoint(
      kind: kindValue == 'quickapp'
          ? InstallKind.quickApp
          : InstallKind.watchface,
      path: pathValue,
      fileSize: fileSizeValue,
      md5Hex: md5Value,
      sha256Hex: sha256Value,
      dataType: dataTypeValue,
      lastAcknowledgedSegment: segmentValue,
      phase: phaseValue,
      faceId: value['faceId'] as String?,
      packageName: value['packageName'] as String?,
      versionCode: (value['versionCode'] as num?)?.toInt(),
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
