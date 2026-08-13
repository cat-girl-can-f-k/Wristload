import 'package:test/test.dart';
import 'package:wristload_tui/wristload_tui.dart';

void main() {
  test('public API exposes facade and frontend port contract', () async {
    final TuiFrontendPort port = TuiFacade.macos(
      helperPath: '/definitely/not/a/bridge',
    );

    expect(port, isA<TuiFacade>());
    expect(port.snapshot.platform.macosOnly, isTrue);
    await port.dispose();
  });

  test('public snapshot data remains immutable to consumers', () {
    final snapshot = TuiSnapshot(
      revision: 1,
      platform: const TuiPlatformInfo(
        macosOnly: true,
        currentSupported: true,
        systemName: 'macOS',
      ),
      helper: const TuiHelperInfo(state: TuiHelperState.stopped),
      scan: const TuiScanInfo(state: TuiScanState.idle),
      supportedModels: const [],
      devices: const [],
      connection: const TuiConnectionInfo(
        state: TuiConnectionState.disconnected,
      ),
      authKeyLoaded: false,
      pendingDecisions: const [],
      queue: const [],
      activeTask: null,
      recovery: const TuiRecoveryInfo(state: TuiRecoveryState.none),
      transferSettings: const TuiTransferSettings(
        segmentIntervalMs: 5,
        massWindowSize: 3,
        segmentIntervalMsRange: (1, 20),
        massWindowSizeRange: (1, 50),
      ),
      logs: const [],
      notice: null,
      allowedActions: const {},
      blockedReasons: const {},
      busyOperations: const {},
    );

    expect(snapshot.isBusy, isFalse);
    expect(snapshot.devices, isEmpty);
  });

  test('structured log entries expose stable category and event code', () {
    final entry = TuiLogEntry(
      timestamp: DateTime(2026, 8, 13),
      level: TuiLogLevel.warning,
      category: TuiLogCategory.security,
      eventCode: 'security.gate.blocked',
      message: '操作被验证门禁阻止。',
    );

    expect(entry.category, TuiLogCategory.security);
    expect(entry.eventCode, 'security.gate.blocked');
  });

  test('public action results keep stable safe fields', () {
    final result = TuiActionResult.success('已接受', operationId: 'op-1');
    expect(result.accepted, isTrue);
    expect(result.code, 'ok');
    expect(result.operationId, 'op-1');
  });

  test('success is an explicit device-business terminal state', () {
    const sentButUnconfirmed = TuiActiveTask(
      kind: TuiQueueItemKind.watchface,
      fileName: 'face.bin',
      stage: TuiTaskStage.awaitingDevice,
      message: '文件已确认发送，等待设备安装结果。',
      confirmedBytes: 100,
      queuedBytes: 100,
      totalBytes: 100,
      successVerifiedByDeviceBusinessEvent: false,
    );
    const completed = TuiActiveTask(
      kind: TuiQueueItemKind.watchface,
      fileName: 'face.bin',
      stage: TuiTaskStage.succeeded,
      message: '设备已确认安装。',
      successVerifiedByDeviceBusinessEvent: true,
    );

    expect(sentButUnconfirmed.confirmedBytes, sentButUnconfirmed.totalBytes);
    expect(sentButUnconfirmed.stage, isNot(TuiTaskStage.succeeded));
    expect(sentButUnconfirmed.successVerifiedByDeviceBusinessEvent, isFalse);
    expect(completed.stage, TuiTaskStage.succeeded);
    expect(completed.successVerifiedByDeviceBusinessEvent, isTrue);
  });
}
