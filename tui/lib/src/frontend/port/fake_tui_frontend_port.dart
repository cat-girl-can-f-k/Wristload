import 'dart:async';
import 'dart:io';

import 'tui_action_result.dart';
import 'tui_frontend_port.dart';
import 'tui_snapshot.dart';

/// A fully programmable fake implementation of [TuiFrontendPort] for frontend
/// development and tests. It does not simulate Bluetooth bytes, installation
/// protocol, or real timing; it only produces discrete snapshot fixtures and
/// records every action submitted by the UI.
///
/// Every property is exposed for tests; production code must use the public
/// [TuiFrontendPort] interface only.
class FakeTuiFrontendPort implements TuiFrontendPort {
  FakeTuiFrontendPort({TuiSnapshot? initial}) {
    _snapshot = initial ?? _emptySnapshot();
    _controller = StreamController<TuiSnapshot>.broadcast(sync: true);
  }

  late final StreamController<TuiSnapshot> _controller;
  late TuiSnapshot _snapshot;
  int _revision = 0;
  bool _disposed = false;

  final List<RecordedAction> recordedActions = [];

  /// Programmatic hook called after each action before the action completes.
  /// Tests can inject synchronous or asynchronous state transitions.
  FutureOr<void> Function(FakeTuiFrontendPort port, RecordedAction action)?
      onAction;

  @override
  TuiSnapshot get snapshot => _snapshot;

  @override
  Stream<TuiSnapshot> get snapshots => Stream<TuiSnapshot>.multi((listener) {
        listener.add(_snapshot);
        final subscription = _controller.stream.listen(
          listener.add,
          onError: listener.addError,
          onDone: listener.close,
        );
        listener.onCancel = subscription.cancel;
      });

  void emit(TuiSnapshot snapshot) {
    if (_disposed) return;
    _snapshot = snapshot;
    if (!_controller.isClosed) _controller.add(snapshot);
  }

  void emitNext(TuiSnapshot Function(TuiSnapshot current) builder) {
    emit(builder(_snapshot));
  }

  Future<TuiActionResult> _record(
    String name,
    Map<String, Object?> args,
  ) async {
    final action = RecordedAction(name, args, DateTime.now());
    recordedActions.add(action);
    await onAction?.call(this, action);
    return TuiActionResult.success('已接受：$name');
  }

  @override
  Future<TuiActionResult> initialize() async => _record('initialize', const {});

  @override
  Future<TuiActionResult> refreshPairedDevices() async {
    return _record('refreshPairedDevices', const {});
  }

  @override
  Future<TuiActionResult> startScan({
    Duration duration = const Duration(seconds: 10),
  }) async {
    return _record('startScan', {'duration': duration.inSeconds});
  }

  @override
  Future<TuiActionResult> stopScan() async => _record('stopScan', const {});

  @override
  Future<TuiActionResult> addManualDevice({
    required String address,
    required String modelId,
    String? displayName,
  }) async {
    return _record('addManualDevice', {
      'address': address,
      'modelId': modelId,
      'displayName': displayName,
    });
  }

  @override
  Future<TuiActionResult> connectDevice(String deviceId) async {
    return _record('connectDevice', {'deviceId': deviceId});
  }

  @override
  Future<TuiActionResult> disconnect() async => _record('disconnect', const {});

  @override
  Future<TuiActionResult> submitAuthKey(String value) async {
    return _record('submitAuthKey', {'length': value.length});
  }

  @override
  Future<TuiActionResult> clearAuthKey() async =>
      _record('clearAuthKey', const {});

  @override
  Future<TuiActionResult> importFiles(List<String> literalPaths) async {
    return _record('importFiles', {'count': literalPaths.length});
  }

  @override
  Future<TuiActionResult> resolveDecision(
    String decisionId, {
    required bool accepted,
    Map<String, String> values = const {},
  }) async {
    return _record('resolveDecision', {
      'decisionId': decisionId,
      'accepted': accepted,
      'values': values,
    });
  }

  @override
  Future<TuiActionResult> removeQueueItem(String itemId) async {
    return _record('removeQueueItem', {'itemId': itemId});
  }

  @override
  Future<TuiActionResult> moveQueueItem(String itemId, int newIndex) async {
    return _record('moveQueueItem', {'itemId': itemId, 'newIndex': newIndex});
  }

  @override
  Future<TuiActionResult> clearCompletedQueue() async {
    return _record('clearCompletedQueue', const {});
  }

  @override
  Future<TuiActionResult> startQueue() async => _record('startQueue', const {});

  @override
  Future<TuiActionResult> retryQueueItem(String itemId) async {
    return _record('retryQueueItem', {'itemId': itemId});
  }

  @override
  Future<TuiActionResult> cancelActiveInstall() async {
    return _record('cancelActiveInstall', const {});
  }

  @override
  Future<TuiActionResult> inspectRecovery() async =>
      _record('inspectRecovery', const {});

  @override
  Future<TuiActionResult> resumeRecovery() async =>
      _record('resumeRecovery', const {});

  @override
  Future<TuiActionResult> discardRecovery() async =>
      _record('discardRecovery', const {});

  @override
  Future<TuiActionResult> updateTransferSettings({
    required int segmentIntervalMs,
    required int massWindowSize,
  }) async {
    return _record('updateTransferSettings', {
      'segmentIntervalMs': segmentIntervalMs,
      'massWindowSize': massWindowSize,
    });
  }

  @override
  Future<TuiActionResult> exportSafeLogs(
    String literalDestinationPath,
  ) async {
    return _record('exportSafeLogs', {
      'literalDestinationPath': literalDestinationPath,
    });
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    recordedActions.add(RecordedAction('dispose', const {}, DateTime.now()));
    await _controller.close();
  }

  TuiSnapshot _emptySnapshot() {
    _revision++;
    final supported = Platform.isMacOS;
    return TuiSnapshot(
      revision: _revision,
      platform: TuiPlatformInfo(
        macosOnly: true,
        currentSupported: supported,
        systemName: supported ? 'macOS' : Platform.operatingSystem,
      ),
      helper: const TuiHelperInfo(state: TuiHelperState.stopped),
      scan: const TuiScanInfo(state: TuiScanState.idle),
      supportedModels: _defaultSupportedModels,
      devices: const [],
      connection:
          const TuiConnectionInfo(state: TuiConnectionState.disconnected),
      authKeyLoaded: false,
      pendingDecisions: const [],
      queue: const [],
      activeTask: null,
      recovery: const TuiRecoveryInfo(state: TuiRecoveryState.unchecked),
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
  }

  static const _defaultSupportedModels = <TuiSupportedModel>[
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
      modelId: 'miwear.watch.o66',
      displayName: '小米手环 10',
      generation: 'Vela V2',
      supported: true,
    ),
    TuiSupportedModel(
      modelId: 'miwear.watch.p67cn',
      displayName: '小米手环 10 Pro',
      generation: 'Vela V2',
      supported: true,
    ),
    TuiSupportedModel(
      modelId: 'miwear.watch.o63',
      displayName: '小米 Watch S4 系列',
      generation: 'Vela V2',
      supported: true,
    ),
    TuiSupportedModel(
      modelId: 'miwear.watch.s5',
      displayName: '小米 Watch S5 系列',
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
      modelId: 'miwear.watch.p65',
      displayName: 'REDMI Watch 6',
      generation: 'Vela V2',
      supported: true,
    ),
    TuiSupportedModel(
      modelId: 'lchz.watch.m67',
      displayName: '小米手环 8 Pro（旧 Vela）',
      generation: 'Vela V1',
      supported: false,
    ),
    TuiSupportedModel(
      modelId: 'hqbd3.watch.l67',
      displayName: '小米手环 7 Pro（Huami/Zepp）',
      generation: 'Huami/Zepp',
      supported: false,
    ),
  ];
}

class RecordedAction {
  RecordedAction(this.name, this.args, this.at);

  final String name;
  final Map<String, Object?> args;
  final DateTime at;

  @override
  String toString() => 'RecordedAction($name, $args)';
}
