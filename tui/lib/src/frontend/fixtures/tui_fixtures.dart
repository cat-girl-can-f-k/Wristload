import 'dart:io';

import '../port/tui_snapshot.dart';

/// Reusable UI snapshot fixtures for tests and the fake preview. Fixtures are
/// pure data: they do not depend on Bluetooth, files, or real time.
class TuiFixtures {
  const TuiFixtures._();

  static TuiSnapshot base({int revision = 1}) => TuiSnapshot(
        revision: revision,
        platform: const TuiPlatformInfo(
          macosOnly: true,
          currentSupported: true,
          systemName: 'macOS',
        ),
        helper: const TuiHelperInfo(
          state: TuiHelperState.ready,
          protocolVersion: 1,
          executablePresent: true,
          executableExecutable: true,
        ),
        scan: const TuiScanInfo(state: TuiScanState.idle),
        supportedModels: _supportedModels,
        devices: const [],
        connection: const TuiConnectionInfo(
          state: TuiConnectionState.disconnected,
        ),
        authKeyLoaded: false,
        pendingDecisions: const [],
        queue: const [],
        activeTask: null,
        recovery: const TuiRecoveryInfo(state: TuiRecoveryState.none),
        transferSettings: _defaultSettings,
        logs: const [],
        notice: null,
        allowedActions: const {
          'initialize',
          'refreshPairedDevices',
          'startScan',
          'addManualDevice',
          'importFiles',
          'inspectRecovery',
          'updateTransferSettings',
          'exportSafeLogs',
        },
        blockedReasons: const {},
        busyOperations: const {},
      );

  static TuiSnapshot helperStarting({int revision = 2}) =>
      base(revision: revision).copyWith(
        helper: const TuiHelperInfo(
          state: TuiHelperState.starting,
          message: '正在启动 macOS 蓝牙 helper…',
        ),
        allowedActions: const {},
        busyOperations: const {TuiBusyOperation.initialize},
      );

  static TuiSnapshot helperMissing({int revision = 2}) =>
      base(revision: revision).copyWith(
        helper: const TuiHelperInfo(
          state: TuiHelperState.failed,
          code: 'helper_missing',
          message: '未找到 wearable_macos_bridge，请先编译 macos_bridge。',
          executablePresent: false,
        ),
        allowedActions: const {'initialize'},
        blockedReasons: const {
          'startScan': 'helper 未就绪',
          'connectDevice': 'helper 未就绪',
        },
      );

  static TuiSnapshot helperProtocolMismatch({int revision = 2}) =>
      base(revision: revision).copyWith(
        helper: const TuiHelperInfo(
          state: TuiHelperState.failed,
          code: 'helper_protocol_mismatch',
          message: 'helper 协议版本不匹配，请重新编译。',
          protocolVersion: 99,
          executablePresent: true,
          executableExecutable: true,
        ),
        allowedActions: const {'initialize'},
      );

  static TuiSnapshot scanRunning({int revision = 3}) =>
      base(revision: revision).copyWith(
        scan: TuiScanInfo(
          state: TuiScanState.running,
          startedAt: DateTime.now().subtract(const Duration(seconds: 3)),
          endsAt: DateTime.now().add(const Duration(seconds: 7)),
          remaining: const Duration(seconds: 7),
        ),
        allowedActions: const {
          'stopScan',
          'refreshPairedDevices',
          'addManualDevice',
          'importFiles',
        },
        blockedReasons: const {'startScan': '扫描已在运行'},
        busyOperations: const {TuiBusyOperation.scan},
      );

  static TuiSnapshot scanFinished({int revision = 4}) =>
      base(revision: revision).copyWith(
        devices: [
          _band9Pro('AA-BB-CC-DD-EE-FF',
              sources: {TuiDeviceSource.paired, TuiDeviceSource.inquiry},
              rssi: -52),
          _inquiry('11-22-33-44-55-66', name: 'Smart Band 9', rssi: -68),
        ],
      );

  static TuiSnapshot pairedAndInquiryMerged({int revision = 5}) =>
      base(revision: revision).copyWith(
        devices: [
          _band9Pro('AA-BB-CC-DD-EE-FF',
              sources: {TuiDeviceSource.paired, TuiDeviceSource.inquiry},
              rssi: -52,
              paired: true),
        ],
      );

  static TuiSnapshot manualDeviceAdded({int revision = 6}) =>
      base(revision: revision).copyWith(
        devices: [
          _band9Pro('AA-BB-CC-DD-EE-FF',
              sources: {TuiDeviceSource.manual}, paired: false, name: '手动添加'),
        ],
      );

  static TuiSnapshot unsupportedDevice({int revision = 6}) =>
      base(revision: revision).copyWith(
        devices: [
          TuiDevice(
            deviceId: '112233445566',
            address: '11-22-33-44-55-66',
            addressKey: '112233445566',
            name: 'Band 8 Pro',
            paired: true,
            sources: {TuiDeviceSource.paired},
            matchedModelId: 'lchz.watch.m67',
            matchedModelName: '小米手环 8 Pro（旧 Vela）',
            protocolGeneration: TuiProtocolGeneration.v1Vela,
            supportState: TuiSupportState.unsupported,
            blockedReason: '仅支持已验证的 Vela V2 设备',
            allowedActions: const {},
          ),
        ],
      );

  static TuiSnapshot connecting({int revision = 7}) =>
      base(revision: revision).copyWith(
        connection: const TuiConnectionInfo(
          state: TuiConnectionState.connecting,
          targetDeviceId: 'AABBCCDDEEFF',
          targetDeviceName: '小米手环 9 Pro',
          targetAddress: 'AA-BB-CC-DD-EE-FF',
        ),
        allowedActions: const {'disconnect'},
        busyOperations: const {TuiBusyOperation.connect},
      );

  static TuiSnapshot awaitingAuthKey({int revision = 8}) =>
      base(revision: revision).copyWith(
        connection: const TuiConnectionInfo(
          state: TuiConnectionState.awaitingAuthKey,
          targetDeviceId: 'AABBCCDDEEFF',
          targetDeviceName: '小米手环 9 Pro',
          targetAddress: 'AA-BB-CC-DD-EE-FF',
        ),
        allowedActions: const {'submitAuthKey', 'disconnect'},
      );

  static TuiSnapshot authenticating({int revision = 9}) =>
      base(revision: revision).copyWith(
        connection: const TuiConnectionInfo(
          state: TuiConnectionState.authenticating,
          targetDeviceId: 'AABBCCDDEEFF',
          targetDeviceName: '小米手环 9 Pro',
          targetAddress: 'AA-BB-CC-DD-EE-FF',
        ),
        authKeyLoaded: true,
        allowedActions: const {'disconnect'},
        busyOperations: const {TuiBusyOperation.auth},
      );

  static TuiSnapshot reconnecting({int revision = 10}) =>
      base(revision: revision).copyWith(
        connection: const TuiConnectionInfo(
          state: TuiConnectionState.reconnecting,
          targetDeviceId: 'AABBCCDDEEFF',
          targetDeviceName: '小米手环 9 Pro',
          targetAddress: 'AA-BB-CC-DD-EE-FF',
        ),
        authKeyLoaded: true,
        allowedActions: const {'disconnect'},
        busyOperations: const {TuiBusyOperation.connect},
      );

  static TuiSnapshot rfcommRebuildRequired({int revision = 11}) =>
      base(revision: revision).copyWith(
        connection: const TuiConnectionInfo(
          state: TuiConnectionState.disconnected,
          targetDeviceId: 'AABBCCDDEEFF',
          targetDeviceName: '小米手环 9 Pro',
          targetAddress: 'AA-BB-CC-DD-EE-FF',
          failureMessage: 'SPP 序号空间已耗尽，必须重建 RFCOMM 会话后重试。',
          failureCode: 'rfcomm_rebuild_required',
        ),
        logs: [
          TuiLogEntry(
            timestamp: DateTime(2026, 8, 13, 12),
            level: TuiLogLevel.error,
            category: TuiLogCategory.protocol,
            eventCode: 'protocol.spp_sequence_exhausted',
            message: 'SPP 序号空间已耗尽，必须重建 RFCOMM 会话后重试。',
          ),
        ],
        notice: const TuiNotice(
          id: 'rfcomm_rebuild_required',
          message: 'SPP 序号空间已耗尽，必须重建 RFCOMM 会话后重试。',
          severity: TuiDecisionSeverity.error,
        ),
      );

  static TuiSnapshot ready({int revision = 11}) =>
      base(revision: revision).copyWith(
        connection: const TuiConnectionInfo(
          state: TuiConnectionState.ready,
          targetDeviceId: 'AABBCCDDEEFF',
          targetDeviceName: '小米手环 9 Pro',
          targetAddress: 'AA-BB-CC-DD-EE-FF',
        ),
        authKeyLoaded: true,
        allowedActions: const {
          'disconnect',
          'importFiles',
          'startQueue',
          'clearAuthKey',
          'updateTransferSettings',
        },
      );

  static TuiSnapshot queueEmpty({int revision = 12}) =>
      base(revision: revision).copyWith(
        connection: const TuiConnectionInfo(
          state: TuiConnectionState.ready,
          targetDeviceId: 'AABBCCDDEEFF',
          targetDeviceName: '小米手环 9 Pro',
          targetAddress: 'AA-BB-CC-DD-EE-FF',
        ),
        authKeyLoaded: true,
      );

  static TuiSnapshot queueWaiting({int revision = 13}) =>
      base(revision: revision).copyWith(
        connection: const TuiConnectionInfo(
          state: TuiConnectionState.ready,
          targetDeviceId: 'AABBCCDDEEFF',
          targetDeviceName: '小米手环 9 Pro',
          targetAddress: 'AA-BB-CC-DD-EE-FF',
        ),
        authKeyLoaded: true,
        queue: [
          _watchfaceQueue('wf-1', 'cat_face.bin'),
          _rpkQueue('rpk-1', 'weather.rpk'),
        ],
        allowedActions: const {
          'disconnect',
          'startQueue',
          'removeQueueItem',
          'moveQueueItem',
          'importFiles',
        },
      );

  static TuiSnapshot queueRunningTransfer({int revision = 14}) =>
      base(revision: revision).copyWith(
        connection: const TuiConnectionInfo(
          state: TuiConnectionState.ready,
          targetDeviceId: 'AABBCCDDEEFF',
          targetDeviceName: '小米手环 9 Pro',
        ),
        authKeyLoaded: true,
        queue: [
          _watchfaceQueue('wf-1', 'cat_face.bin',
              stage: TuiQueueItemStage.installing),
          _rpkQueue('rpk-1', 'weather.rpk'),
        ],
        activeTask: TuiActiveTask(
          kind: TuiQueueItemKind.watchface,
          fileName: 'cat_face.bin',
          stage: TuiTaskStage.transferring,
          message: '正在发送第 12-15/80 片',
          targetDeviceName: '小米手环 9 Pro',
          currentSegment: 15,
          totalSegments: 80,
          confirmedBytes: 14850,
          queuedBytes: 19800,
          totalBytes: 158400,
          bytesPerSecond: 4200,
          elapsed: const Duration(seconds: 12),
          transferElapsed: const Duration(seconds: 8),
          averageBytesPerSecond: 1856,
        ),
        allowedActions: const {'cancelActiveInstall', 'disconnect'},
        busyOperations: const {TuiBusyOperation.connect},
      );

  static TuiSnapshot awaitingDevice100({int revision = 15}) =>
      base(revision: revision).copyWith(
        connection: const TuiConnectionInfo(
          state: TuiConnectionState.ready,
          targetDeviceId: 'AABBCCDDEEFF',
          targetDeviceName: '小米手环 9 Pro',
        ),
        authKeyLoaded: true,
        queue: [
          _watchfaceQueue('wf-1', 'cat_face.bin',
              stage: TuiQueueItemStage.installing),
        ],
        activeTask: TuiActiveTask(
          kind: TuiQueueItemKind.watchface,
          fileName: 'cat_face.bin',
          stage: TuiTaskStage.awaitingDevice,
          message: '文件已确认发送，等待设备安装结果',
          targetDeviceName: '小米手环 9 Pro',
          currentSegment: 80,
          totalSegments: 80,
          confirmedBytes: 158400,
          queuedBytes: 158400,
          totalBytes: 158400,
          bytesPerSecond: 0,
          elapsed: const Duration(minutes: 1),
          transferElapsed: const Duration(seconds: 45),
          averageBytesPerSecond: 3516,
          successVerifiedByDeviceBusinessEvent: false,
        ),
        allowedActions: const {'cancelActiveInstall'},
      );

  static TuiSnapshot installSucceeded({int revision = 16}) =>
      base(revision: revision).copyWith(
        connection: const TuiConnectionInfo(
          state: TuiConnectionState.ready,
          targetDeviceId: 'AABBCCDDEEFF',
          targetDeviceName: '小米手环 9 Pro',
        ),
        authKeyLoaded: true,
        queue: [
          _watchfaceQueue('wf-1', 'cat_face.bin',
              stage: TuiQueueItemStage.done, message: '表盘已安装并已请求切换'),
        ],
        activeTask: TuiActiveTask(
          kind: TuiQueueItemKind.watchface,
          fileName: 'cat_face.bin',
          stage: TuiTaskStage.succeeded,
          message: '表盘已安装并已请求切换',
          targetDeviceName: '小米手环 9 Pro',
          currentSegment: 80,
          totalSegments: 80,
          confirmedBytes: 158400,
          queuedBytes: 158400,
          totalBytes: 158400,
          elapsed: const Duration(minutes: 1, seconds: 5),
          transferElapsed: const Duration(seconds: 45),
          averageBytesPerSecond: 3516,
          successVerifiedByDeviceBusinessEvent: true,
        ),
        allowedActions: const {'disconnect', 'importFiles', 'startQueue'},
      );

  static TuiSnapshot installFailed({int revision = 16}) =>
      base(revision: revision).copyWith(
        queue: [
          _watchfaceQueue('wf-1', 'cat_face.bin',
              stage: TuiQueueItemStage.failed,
              message: '设备拒绝表盘安装，状态=3',
              canRetry: true,
              failureAttempts: 1),
        ],
        activeTask: TuiActiveTask(
          kind: TuiQueueItemKind.watchface,
          fileName: 'cat_face.bin',
          stage: TuiTaskStage.failed,
          message: '设备拒绝表盘安装，状态=3',
          targetDeviceName: '小米手环 9 Pro',
          confirmedBytes: 158400,
          queuedBytes: 158400,
          totalBytes: 158400,
          elapsed: const Duration(minutes: 1, seconds: 5),
          successVerifiedByDeviceBusinessEvent: false,
        ),
        allowedActions: const {
          'retryQueueItem',
          'removeQueueItem',
          'disconnect'
        },
      );

  static TuiSnapshot installStateUnknown({int revision = 16}) =>
      base(revision: revision).copyWith(
        queue: [
          _watchfaceQueue('wf-1', 'cat_face.bin',
              stage: TuiQueueItemStage.stateUnknown,
              message: '设备加密响应无法验证，状态未知',
              canRetry: true,
              failureAttempts: 1),
        ],
        activeTask: TuiActiveTask(
          kind: TuiQueueItemKind.watchface,
          fileName: 'cat_face.bin',
          stage: TuiTaskStage.stateUnknown,
          message: '设备加密响应无法验证，状态未知',
          targetDeviceName: '小米手环 9 Pro',
          confirmedBytes: 79200,
          queuedBytes: 99000,
          totalBytes: 158400,
          elapsed: const Duration(seconds: 30),
          successVerifiedByDeviceBusinessEvent: false,
        ),
        allowedActions: const {
          'retryQueueItem',
          'removeQueueItem',
          'inspectRecovery'
        },
      );

  static TuiSnapshot installCancelled({int revision = 16}) =>
      base(revision: revision).copyWith(
        queue: [
          _watchfaceQueue('wf-1', 'cat_face.bin',
              stage: TuiQueueItemStage.cancelled,
              message: '已取消；设备可能保留部分数据',
              canRetry: true),
        ],
        activeTask: TuiActiveTask(
          kind: TuiQueueItemKind.watchface,
          fileName: 'cat_face.bin',
          stage: TuiTaskStage.cancelled,
          message: '已取消；设备可能保留部分数据',
          targetDeviceName: '小米手环 9 Pro',
          confirmedBytes: 39600,
          queuedBytes: 52800,
          totalBytes: 158400,
          elapsed: const Duration(seconds: 15),
          successVerifiedByDeviceBusinessEvent: false,
        ),
        allowedActions: const {
          'retryQueueItem',
          'removeQueueItem',
          'disconnect'
        },
      );

  static TuiSnapshot recoveryAvailable({int revision = 17}) =>
      base(revision: revision).copyWith(
        recovery: TuiRecoveryInfo(
          state: TuiRecoveryState.available,
          fileName: 'cat_face.bin',
          literalPath: '/Users/demo/Downloads/cat_face.bin',
          fileSize: 158400,
          md5Hex: 'c7b25c08b5a58b0f38f7a49a1e4f1e2a',
          sha256Hex: _fakeSha256,
          lastAcknowledgedSegment: 40,
          phase: 'transferring',
          message: '检查点文件校验通过',
          allowedActions: {
            'inspectRecovery',
            'resumeRecovery',
            'discardRecovery'
          },
        ),
        allowedActions: const {
          'inspectRecovery',
          'resumeRecovery',
          'discardRecovery'
        },
      );

  static TuiSnapshot recoveryInvalid({int revision = 17}) =>
      base(revision: revision).copyWith(
        recovery: TuiRecoveryInfo(
          state: TuiRecoveryState.invalid,
          fileName: 'cat_face.bin',
          literalPath: '/Users/demo/Downloads/cat_face.bin',
          md5Hex: 'c7b25c08b5a58b0f38f7a49a1e4f1e2a',
          sha256Hex: _fakeSha256b,
          lastAcknowledgedSegment: 40,
          phase: 'transferring',
          message: '源文件 MD5 与检查点不符，无法恢复',
          allowedActions: {'inspectRecovery', 'discardRecovery'},
        ),
        allowedActions: const {'inspectRecovery', 'discardRecovery'},
      );

  static TuiSnapshot pendingDecisions({int revision = 18}) =>
      base(revision: revision).copyWith(
        queue: [
          _watchfaceQueue('wf-1', 'mismatched.bin',
              stage: TuiQueueItemStage.waiting),
          _rpkQueue('rpk-1', 'missing_version.rpk',
              stage: TuiQueueItemStage.waiting, versionCode: null),
        ],
        pendingDecisions: [
          const TuiPendingDecision(
            decisionId: 'd-1',
            kind: TuiDecisionKind.watchfaceResolutionMismatch,
            severity: TuiDecisionSeverity.warning,
            title: '表盘分辨率不匹配',
            message: '表盘分辨率与目标设备不匹配，继续安装可能显示异常。',
            facts: ['设备: 小米手环 9 Pro', '表盘分辨率: 480×320', '设备期望: 336×480'],
            confirmLabel: '仍要安装',
            cancelLabel: '取消',
            token: 'token-wf-1',
          ),
          const TuiPendingDecision(
            decisionId: 'd-2',
            kind: TuiDecisionKind.missingFaceId,
            severity: TuiDecisionSeverity.error,
            title: '缺失 faceId',
            message: '表盘元数据缺少数值 faceId，请补全。',
            inputFields: [
              TuiDecisionInputField(
                fieldId: 'faceId',
                label: 'faceId',
                format: r'^\d+$',
                required: true,
              ),
            ],
          ),
          const TuiPendingDecision(
            decisionId: 'd-3',
            kind: TuiDecisionKind.redmiWatch5LuaUnsupported,
            severity: TuiDecisionSeverity.error,
            title: 'Lua 表盘不受支持',
            message: 'REDMI Watch 5 不支持 Lua 表盘。',
            facts: ['设备: REDMI Watch 5'],
            confirmLabel: '了解',
            cancelLabel: '返回',
          ),
          const TuiPendingDecision(
            decisionId: 'd-4',
            kind: TuiDecisionKind.invalidRpkVersionCode,
            severity: TuiDecisionSeverity.error,
            title: 'RPK versionCode 无效',
            message: 'RPK versionCode 缺失或超出合法范围。',
            inputFields: [
              TuiDecisionInputField(
                fieldId: 'versionCode',
                label: 'versionCode',
                format: r'^\d+$',
                required: true,
                min: 1,
                max: 2147483647,
              ),
            ],
          ),
          const TuiPendingDecision(
            decisionId: 'd-5',
            kind: TuiDecisionKind.recoveryFileChanged,
            severity: TuiDecisionSeverity.error,
            title: '恢复文件已变化',
            message: '检查点对应的源文件已变化或不可访问，无法继续恢复。',
            confirmLabel: '放弃恢复',
            cancelLabel: '返回',
            token: 'token-recovery',
          ),
        ],
      );

  static TuiSnapshot logs({int revision = 19}) {
    final logs = <TuiLogEntry>[];
    for (var i = 0; i < 20; i++) {
      logs.add(TuiLogEntry(
        timestamp: DateTime.now().subtract(Duration(minutes: 20 - i)),
        level: i == 19 ? TuiLogLevel.error : TuiLogLevel.info,
        category: i == 19 ? TuiLogCategory.install : TuiLogCategory.transfer,
        eventCode: i == 19 ? 'install.failed' : 'transfer.progress',
        message: '日志条目 $i：这是脱敏后的安全日志示例。',
      ));
    }
    return base(revision: revision).copyWith(logs: logs);
  }

  static TuiSnapshot longText({int revision = 20}) =>
      base(revision: revision).copyWith(
        devices: [
          _band9Pro('AA-BB-CC-DD-EE-FF',
              name: '超长中文设备名测试一二三四五六七八九十', sources: {TuiDeviceSource.paired}),
        ],
        queue: [
          _watchfaceQueue('wf-long', '超长中文文件名测试_一二三四五六七八九十.bin',
              literalPath: '/Users/用户/下载/超长中文路径/一二三四五六七八九十.bin'),
        ],
      );

  static TuiSnapshot unsupportedPlatform({int revision = 1}) => TuiSnapshot(
        revision: revision,
        platform: TuiPlatformInfo(
          macosOnly: true,
          currentSupported: false,
          systemName: Platform.operatingSystem,
        ),
        helper: const TuiHelperInfo(state: TuiHelperState.stopped),
        scan: const TuiScanInfo(state: TuiScanState.idle),
        supportedModels: const [],
        devices: const [],
        connection:
            const TuiConnectionInfo(state: TuiConnectionState.disconnected),
        authKeyLoaded: false,
        pendingDecisions: const [],
        queue: const [],
        activeTask: null,
        recovery: const TuiRecoveryInfo(state: TuiRecoveryState.unchecked),
        transferSettings: _defaultSettings,
        logs: const [],
        notice: const TuiNotice(
          id: 'unsupported-platform',
          message: '此 TUI 仅支持 macOS。',
          severity: TuiDecisionSeverity.error,
        ),
        allowedActions: const {},
        blockedReasons: const {},
        busyOperations: const {},
      );

  static TuiDevice _band9Pro(
    String address, {
    String? name,
    Set<TuiDeviceSource> sources = const {TuiDeviceSource.inquiry},
    int? rssi,
    bool paired = false,
  }) =>
      TuiDevice(
        deviceId: address.replaceAll('-', '').toUpperCase(),
        address: address,
        addressKey: address.replaceAll('-', '').toUpperCase(),
        name: name ?? '小米手环 9 Pro',
        paired: paired,
        sources: sources,
        rssi: rssi,
        matchedModelId: 'miwear.watch.n67',
        matchedModelName: '小米手环 9 Pro',
        protocolGeneration: TuiProtocolGeneration.v2Vela,
        supportState: TuiSupportState.supported,
        allowedActions: const {'connectDevice'},
      );

  static TuiDevice _inquiry(
    String address, {
    required String name,
    int? rssi,
  }) =>
      TuiDevice(
        deviceId: address.replaceAll('-', '').toUpperCase(),
        address: address,
        addressKey: address.replaceAll('-', '').toUpperCase(),
        name: name,
        paired: false,
        sources: {TuiDeviceSource.inquiry},
        rssi: rssi,
        protocolGeneration: TuiProtocolGeneration.unknown,
        supportState: TuiSupportState.unknown,
        allowedActions: const {'connectDevice'},
      );

  static String get _fakeSha256 => 'a' * 64;
  static String get _fakeSha256b => 'b' * 64;

  static TuiQueueItem _watchfaceQueue(
    String itemId,
    String fileName, {
    String? literalPath,
    TuiQueueItemStage stage = TuiQueueItemStage.waiting,
    String? message,
    bool canRetry = false,
    int failureAttempts = 0,
  }) =>
      TuiQueueItem(
        itemId: itemId,
        kind: TuiQueueItemKind.watchface,
        fileName: fileName,
        literalPath: literalPath ?? '/Users/demo/Downloads/$fileName',
        fileSize: 158400,
        md5Hex: 'c7b25c08b5a58b0f38f7a49a1e4f1e2a',
        sha256Hex: _fakeSha256,
        stage: stage,
        faceId: '123456',
        watchfaceResolution: '336×480',
        containsLua: false,
        message: message,
        canRetry: canRetry,
        failureAttempts: failureAttempts,
        allowedActions: stage == TuiQueueItemStage.waiting
            ? const {'removeQueueItem', 'moveQueueItem'}
            : const {},
      );

  static TuiQueueItem _rpkQueue(
    String itemId,
    String fileName, {
    String? literalPath,
    TuiQueueItemStage stage = TuiQueueItemStage.waiting,
    String? message,
    int? versionCode = 100,
    bool canRetry = false,
  }) =>
      TuiQueueItem(
        itemId: itemId,
        kind: TuiQueueItemKind.quickApp,
        fileName: fileName,
        literalPath: literalPath ?? '/Users/demo/Downloads/$fileName',
        fileSize: 65536,
        md5Hex: 'd8e45b19c6a79c1e49f8b59b2e5f2f3b',
        sha256Hex: _fakeSha256b,
        stage: stage,
        packageName: 'com.example.weather',
        versionCode: versionCode,
        message: message,
        canRetry: canRetry,
        allowedActions: stage == TuiQueueItemStage.waiting
            ? const {'removeQueueItem', 'moveQueueItem'}
            : const {},
      );

  static const _defaultSettings = TuiTransferSettings(
    segmentIntervalMs: 5,
    massWindowSize: 3,
    segmentIntervalMsRange: (1, 20),
    massWindowSizeRange: (1, 50),
  );

  static const _supportedModels = <TuiSupportedModel>[
    TuiSupportedModel(
      modelId: 'miwear.watch.n67',
      displayName: '小米手环 9 Pro',
      generation: 'Vela V2',
      supported: true,
    ),
    TuiSupportedModel(
      modelId: 'miwear.watch.n66',
      displayName: '小米手环 9',
      generation: 'Vela V2',
      supported: true,
    ),
    TuiSupportedModel(
      modelId: 'miwear.watch.o65',
      displayName: 'REDMI Watch 5',
      generation: 'Vela V2',
      supported: true,
    ),
    TuiSupportedModel(
      modelId: 'lchz.watch.m67',
      displayName: '小米手环 8 Pro',
      generation: 'Vela V1',
      supported: false,
    ),
    TuiSupportedModel(
      modelId: 'hqbd3.watch.l67',
      displayName: '小米手环 7 Pro',
      generation: 'Huami/Zepp',
      supported: false,
    ),
  ];
}

/// Extension to make fixture construction less verbose.
extension on TuiSnapshot {
  TuiSnapshot copyWith({
    int? revision,
    TuiPlatformInfo? platform,
    TuiHelperInfo? helper,
    TuiScanInfo? scan,
    List<TuiSupportedModel>? supportedModels,
    List<TuiDevice>? devices,
    TuiConnectionInfo? connection,
    bool? authKeyLoaded,
    List<TuiPendingDecision>? pendingDecisions,
    List<TuiQueueItem>? queue,
    TuiActiveTask? activeTask,
    TuiRecoveryInfo? recovery,
    TuiTransferSettings? transferSettings,
    List<TuiLogEntry>? logs,
    TuiNotice? notice,
    Set<String>? allowedActions,
    Map<String, String>? blockedReasons,
    Set<TuiBusyOperation>? busyOperations,
  }) =>
      TuiSnapshot(
        revision: revision ?? this.revision,
        platform: platform ?? this.platform,
        helper: helper ?? this.helper,
        scan: scan ?? this.scan,
        supportedModels: supportedModels ?? this.supportedModels,
        devices: devices ?? this.devices,
        connection: connection ?? this.connection,
        authKeyLoaded: authKeyLoaded ?? this.authKeyLoaded,
        pendingDecisions: pendingDecisions ?? this.pendingDecisions,
        queue: queue ?? this.queue,
        activeTask: activeTask ?? this.activeTask,
        recovery: recovery ?? this.recovery,
        transferSettings: transferSettings ?? this.transferSettings,
        logs: logs ?? this.logs,
        notice: notice ?? this.notice,
        allowedActions: allowedActions ?? this.allowedActions,
        blockedReasons: blockedReasons ?? this.blockedReasons,
        busyOperations: busyOperations ?? this.busyOperations,
      );
}
