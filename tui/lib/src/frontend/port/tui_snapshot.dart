/// Immutable UI-facing snapshot types. The frontend treats every object here
/// as read-only truth; it never mutates or caches fields beyond the current
/// frame.
library;

/// Platform support statement for the current process.
enum TuiPlatformSupport { supported, unsupported }

class TuiPlatformInfo {
  const TuiPlatformInfo({
    required this.macosOnly,
    required this.currentSupported,
    required this.systemName,
  });

  final bool macosOnly;
  final bool currentSupported;
  final String systemName;

  TuiPlatformSupport get supportState => currentSupported
      ? TuiPlatformSupport.supported
      : TuiPlatformSupport.unsupported;
}

/// Lifecycle of the macOS Bluetooth helper. The UI never sees Process or
/// JSONL details.
enum TuiHelperState { stopped, starting, ready, failed, disposed }

class TuiHelperInfo {
  const TuiHelperInfo({
    required this.state,
    this.code,
    this.message,
    this.protocolVersion,
    this.executablePresent,
    this.executableExecutable,
  });

  final TuiHelperState state;
  final String? code;
  final String? message;
  final int? protocolVersion;
  final bool? executablePresent;
  final bool? executableExecutable;
}

/// Scan state with optional timing display data.
enum TuiScanState { idle, starting, running, stopping, failed }

class TuiScanInfo {
  const TuiScanInfo({
    required this.state,
    this.startedAt,
    this.endsAt,
    this.remaining,
    this.failureMessage,
  });

  final TuiScanState state;
  final DateTime? startedAt;
  final DateTime? endsAt;
  final Duration? remaining;
  final String? failureMessage;
}

/// A V2 model that the backend explicitly allows for installation.
class TuiSupportedModel {
  const TuiSupportedModel({
    required this.modelId,
    required this.displayName,
    required this.generation,
    required this.supported,
  });

  final String modelId;
  final String displayName;
  final String generation;
  final bool supported;
}

enum TuiDeviceSource { paired, inquiry, manual }

enum TuiProtocolGeneration { v1Vela, v2Vela, huamiZepp, unknown }

enum TuiSupportState { supported, unsupported, unknown }

class TuiDevice {
  const TuiDevice({
    required this.deviceId,
    required this.address,
    required this.addressKey,
    required this.name,
    required this.paired,
    required this.sources,
    this.rssi,
    this.matchedModelId,
    this.matchedModelName,
    this.protocolGeneration = TuiProtocolGeneration.unknown,
    this.supportState = TuiSupportState.unknown,
    this.blockedReason,
    this.allowedActions = const {},
  });

  final String deviceId;
  final String address;
  final String addressKey;
  final String? name;
  final int? rssi;
  final bool paired;
  final Set<TuiDeviceSource> sources;
  final String? matchedModelId;
  final String? matchedModelName;
  final TuiProtocolGeneration protocolGeneration;
  final TuiSupportState supportState;
  final String? blockedReason;
  final Set<String> allowedActions;

  bool get supportsInstall => supportState == TuiSupportState.supported;
}

enum TuiConnectionState {
  disconnected,
  connecting,
  awaitingAuthKey,
  authenticating,
  reconnecting,
  ready,
  disconnecting,
  failed,
}

class TuiConnectionInfo {
  const TuiConnectionInfo({
    required this.state,
    this.targetDeviceId,
    this.targetDeviceName,
    this.targetAddress,
    this.failureMessage,
    this.failureCode,
  });

  final TuiConnectionState state;
  final String? targetDeviceId;
  final String? targetDeviceName;
  final String? targetAddress;
  final String? failureMessage;
  /// Stable machine-readable failure classification for the current connection.
  final String? failureCode;
}

enum TuiDecisionSeverity { info, warning, error }

enum TuiDecisionKind {
  watchfaceResolutionMismatch,
  redmiWatch5LuaUnsupported,
  missingFaceId,
  invalidRpkVersionCode,
  recoveryFileChanged,
  generic,
}

class TuiDecisionInputField {
  const TuiDecisionInputField({
    required this.fieldId,
    required this.label,
    required this.format,
    required this.required,
    this.min,
    this.max,
  });

  final String fieldId;
  final String label;
  final String format;
  final bool required;
  final int? min;
  final int? max;
}

class TuiPendingDecision {
  const TuiPendingDecision({
    required this.decisionId,
    required this.kind,
    required this.severity,
    required this.title,
    required this.message,
    this.facts = const [],
    this.confirmLabel = '确认',
    this.cancelLabel = '取消',
    this.inputFields = const [],
    this.token,
    this.revision,
  });

  final String decisionId;
  final TuiDecisionKind kind;
  final TuiDecisionSeverity severity;
  final String title;
  final String message;
  final List<String> facts;
  final String confirmLabel;
  final String cancelLabel;
  final List<TuiDecisionInputField> inputFields;
  final String? token;
  final int? revision;
}

enum TuiQueueItemKind { watchface, quickApp }

enum TuiQueueItemStage {
  waiting,
  installing,
  done,
  failed,
  cancelled,
  stateUnknown
}

class TuiQueueItem {
  const TuiQueueItem({
    required this.itemId,
    required this.kind,
    required this.fileName,
    required this.literalPath,
    required this.fileSize,
    required this.md5Hex,
    required this.sha256Hex,
    required this.stage,
    this.faceId,
    this.watchfaceResolution,
    this.containsLua = false,
    this.packageName,
    this.versionCode,
    this.message,
    this.failureAttempts = 0,
    this.canRetry = false,
    this.allowedActions = const {},
    this.blockedReason,
  });

  final String itemId;
  final TuiQueueItemKind kind;
  final String fileName;
  final String literalPath;
  final int fileSize;
  final String md5Hex;
  final String sha256Hex;
  final TuiQueueItemStage stage;
  final String? faceId;
  final String? watchfaceResolution;
  final bool containsLua;
  final String? packageName;
  final int? versionCode;
  final String? message;
  final int failureAttempts;
  final bool canRetry;
  final Set<String> allowedActions;
  final String? blockedReason;

  bool get isFailure =>
      stage == TuiQueueItemStage.failed ||
      stage == TuiQueueItemStage.cancelled ||
      stage == TuiQueueItemStage.stateUnknown;
}

enum TuiTaskStage {
  validating,
  waitingForProtocol,
  transferring,
  awaitingDevice,
  succeeded,
  failed,
  cancelled,
  stateUnknown,
}

class TuiActiveTask {
  const TuiActiveTask({
    required this.kind,
    required this.fileName,
    required this.stage,
    required this.message,
    this.targetDeviceName,
    this.currentSegment,
    this.totalSegments,
    this.confirmedBytes,
    this.queuedBytes,
    this.totalBytes,
    this.queuedSegment,
    this.bytesPerSecond,
    this.elapsed,
    this.transferElapsed,
    this.averageBytesPerSecond,
    this.successVerifiedByDeviceBusinessEvent = false,
  });

  final TuiQueueItemKind kind;
  final String fileName;
  final TuiTaskStage stage;
  final String message;
  final String? targetDeviceName;
  final int? currentSegment;
  final int? totalSegments;
  final int? confirmedBytes;
  final int? queuedBytes;
  final int? totalBytes;
  final int? queuedSegment;
  final double? bytesPerSecond;
  final Duration? elapsed;
  final Duration? transferElapsed;
  final double? averageBytesPerSecond;
  final bool successVerifiedByDeviceBusinessEvent;
}

enum TuiRecoveryState { unchecked, checking, none, available, invalid, failed }

class TuiRecoveryInfo {
  const TuiRecoveryInfo({
    required this.state,
    this.fileName,
    this.literalPath,
    this.fileSize,
    this.md5Hex,
    this.sha256Hex,
    this.lastAcknowledgedSegment,
    this.phase,
    this.message,
    this.allowedActions = const {},
  });

  final TuiRecoveryState state;
  final String? fileName;
  final String? literalPath;
  final int? fileSize;
  final String? md5Hex;
  final String? sha256Hex;
  final int? lastAcknowledgedSegment;
  final String? phase;
  final String? message;
  final Set<String> allowedActions;
}

class TuiTransferSettings {
  const TuiTransferSettings({
    required this.segmentIntervalMs,
    required this.massWindowSize,
    required this.segmentIntervalMsRange,
    required this.massWindowSizeRange,
    this.saving = false,
    this.lastError,
  });

  final int segmentIntervalMs;
  final int massWindowSize;
  final (int, int) segmentIntervalMsRange;
  final (int, int) massWindowSizeRange;
  final bool saving;
  final String? lastError;
}

enum TuiLogLevel { debug, info, warning, error }

/// Stable diagnostic domains. These are intentionally independent from the
/// backend's free-form messages so callers can filter logs safely.
enum TuiLogCategory {
  system,
  permission,
  helper,
  discovery,
  connection,
  authentication,
  protocol,
  transfer,
  install,
  recovery,
  filesystem,
  security,
  application,
}

class TuiLogEntry {
  const TuiLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.category = TuiLogCategory.application,
    this.eventCode,
  });

  final DateTime timestamp;
  final TuiLogLevel level;
  final String message;
  final TuiLogCategory category;
  final String? eventCode;
}

class TuiNotice {
  const TuiNotice({
    required this.id,
    required this.message,
    this.severity = TuiDecisionSeverity.info,
    this.createdAt,
  });

  final String id;
  final String message;
  final TuiDecisionSeverity severity;
  final DateTime? createdAt;
}

enum TuiBusyOperation {
  initialize,
  refreshPaired,
  scan,
  connect,
  auth,
  import,
  settings,
  export,
  cleanup,
}

/// Atomic immutable snapshot consumed by the frontend. Every field is either
/// a value type, an immutable collection, or another immutable snapshot node.
class TuiSnapshot {
  TuiSnapshot({
    required this.revision,
    required this.platform,
    required this.helper,
    required this.scan,
    required List<TuiSupportedModel> supportedModels,
    required List<TuiDevice> devices,
    required this.connection,
    required this.authKeyLoaded,
    required List<TuiPendingDecision> pendingDecisions,
    required List<TuiQueueItem> queue,
    required this.activeTask,
    required this.recovery,
    required this.transferSettings,
    required List<TuiLogEntry> logs,
    required this.notice,
    required Set<String> allowedActions,
    required Map<String, String> blockedReasons,
    required Set<TuiBusyOperation> busyOperations,
  })  : supportedModels = List.unmodifiable(supportedModels),
        devices = List.unmodifiable(devices),
        pendingDecisions = List.unmodifiable(pendingDecisions),
        queue = List.unmodifiable(queue),
        logs = List.unmodifiable(logs),
        allowedActions = Set.unmodifiable(allowedActions),
        blockedReasons = Map.unmodifiable(blockedReasons),
        busyOperations = Set.unmodifiable(busyOperations);

  final int revision;
  final TuiPlatformInfo platform;
  final TuiHelperInfo helper;
  final TuiScanInfo scan;
  final List<TuiSupportedModel> supportedModels;
  final List<TuiDevice> devices;
  final TuiConnectionInfo connection;
  final bool authKeyLoaded;
  final List<TuiPendingDecision> pendingDecisions;
  final List<TuiQueueItem> queue;
  final TuiActiveTask? activeTask;
  final TuiRecoveryInfo recovery;
  final TuiTransferSettings transferSettings;
  final List<TuiLogEntry> logs;
  final TuiNotice? notice;
  final Set<String> allowedActions;
  final Map<String, String> blockedReasons;
  final Set<TuiBusyOperation> busyOperations;

  bool get isBusy => busyOperations.isNotEmpty;
}
