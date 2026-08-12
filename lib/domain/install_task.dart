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
    this.elapsed,
    this.transferElapsed,
    this.averageBytesPerSecond,
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

  /// 从安装流程开始到当前状态（或结束状态）的总耗时。
  final Duration? elapsed;

  /// 文件传输耗时，不包含设备侧安装等待时间。
  final Duration? transferElapsed;

  /// 基于本次实际传输字节与传输耗时计算的平均速度。
  final double? averageBytesPerSecond;
}
