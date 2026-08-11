enum InstallKind { watchface, quickApp }

enum InstallStage {
  idle,
  validating,
  waitingForProtocol,
  transferring,
  awaitingDevice,
  succeeded,
  cancelled,
  stateUnknown,
  failed,
}

class InstallTask {
  const InstallTask({
    required this.kind,
    required this.fileName,
    required this.stage,
    required this.message,
    this.targetDeviceName,
    this.md5Hex,
    this.faceId,
    this.packageName,
    this.versionCode,
    this.currentSegment,
    this.totalSegments,
    this.confirmedBytes,
    this.queuedSegment,
    this.queuedBytes,
    this.totalBytes,
    this.bytesPerSecond,
  });

  final InstallKind kind;
  final String fileName;
  final InstallStage stage;
  final String message;
  final String? targetDeviceName;
  final String? md5Hex;
  final String? faceId;
  final String? packageName;
  final int? versionCode;
  final int? currentSegment;
  final int? totalSegments;
  final int? confirmedBytes;
  final int? queuedSegment;
  final int? queuedBytes;
  final int? totalBytes;

  /// 基于设备累计 ACK 的实际确认速度；排队但尚未确认的字节不计入速度。
  final double? bytesPerSecond;
}
