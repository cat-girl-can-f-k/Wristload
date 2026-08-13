library;

import '../domain/device_profile.dart';
import '../domain/install_models.dart';
import '../domain/install_task.dart';
import '../transport/mac_bluetooth_transport.dart';

enum BackendConnectionState {
  disconnected,
  connecting,
  awaitingAuthKey,
  authenticating,
  ready,
}

class BackendSnapshot {
  const BackendSnapshot({
    required this.connection,
    required this.queue,
    this.device,
    this.profile,
    this.latestTask,
    this.message,
    this.failureCode,
    this.logs = const [],
    this.authKeyLoaded = false,
    this.queueRunning = false,
    this.installRunning = false,
    this.segmentIntervalMs = 5,
    this.massWindowSize = 3,
  });

  final BackendConnectionState connection;
  final MacBluetoothDevice? device;
  final DeviceProfile? profile;
  final List<QueueEntry> queue;
  final InstallTask? latestTask;
  final String? message;
  /// Stable machine-readable failure classification for the current session.
  final String? failureCode;
  final List<String> logs;
  final bool authKeyLoaded;
  final bool queueRunning;
  final bool installRunning;
  final int segmentIntervalMs;
  final int massWindowSize;

  bool get sessionReady => connection == BackendConnectionState.ready;
  bool get installInProgress =>
      installRunning ||
      latestTask?.stage == InstallStage.transferring ||
      latestTask?.stage == InstallStage.awaitingDevice ||
      latestTask?.stage == InstallStage.validating;
}
