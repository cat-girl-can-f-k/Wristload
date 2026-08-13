import 'tui_action_result.dart';
import 'tui_snapshot.dart';

/// The only boundary between the terminal frontend and the installation
/// backend. Implementations must provide an atomic, immutable snapshot and a
/// stream that replays the current value to every new subscriber.
abstract interface class TuiFrontendPort {
  TuiSnapshot get snapshot;
  Stream<TuiSnapshot> get snapshots;

  Future<TuiActionResult> initialize();
  Future<TuiActionResult> refreshPairedDevices();
  Future<TuiActionResult> startScan({
    Duration duration = const Duration(seconds: 10),
  });
  Future<TuiActionResult> stopScan();
  Future<TuiActionResult> addManualDevice({
    required String address,
    required String modelId,
    String? displayName,
  });
  Future<TuiActionResult> connectDevice(String deviceId);
  Future<TuiActionResult> disconnect();
  Future<TuiActionResult> submitAuthKey(String value);
  Future<TuiActionResult> clearAuthKey();

  Future<TuiActionResult> importFiles(List<String> literalPaths);
  Future<TuiActionResult> resolveDecision(
    String decisionId, {
    required bool accepted,
    Map<String, String> values,
  });
  Future<TuiActionResult> removeQueueItem(String itemId);
  Future<TuiActionResult> moveQueueItem(String itemId, int newIndex);
  Future<TuiActionResult> clearCompletedQueue();
  Future<TuiActionResult> startQueue();
  Future<TuiActionResult> retryQueueItem(String itemId);
  Future<TuiActionResult> cancelActiveInstall();

  Future<TuiActionResult> inspectRecovery();
  Future<TuiActionResult> resumeRecovery();
  Future<TuiActionResult> discardRecovery();
  Future<TuiActionResult> updateTransferSettings({
    required int segmentIntervalMs,
    required int massWindowSize,
  });
  Future<TuiActionResult> exportSafeLogs(String literalDestinationPath);
  Future<void> dispose();
}
