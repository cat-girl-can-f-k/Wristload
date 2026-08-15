library;

import '../domain/device_profile.dart';
import '../domain/install_models.dart';
import '../domain/install_task.dart';
import 'tui_mac_bluetooth_transport.dart';

enum TuiProtocolConnectionState {
  disconnected,
  connecting,
  awaitingAuthKey,
  authenticating,
  ready,
}

final class TuiProtocolSnapshot {
  const TuiProtocolSnapshot({
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

  final TuiProtocolConnectionState connection;
  final TuiTransportDevice? device;
  final DeviceProfile? profile;
  final List<QueueEntry> queue;
  final InstallTask? latestTask;
  final String? message;
  final String? failureCode;
  final List<String> logs;
  final bool authKeyLoaded;
  final bool queueRunning;
  final bool installRunning;
  final int segmentIntervalMs;
  final int massWindowSize;

  bool get sessionReady => connection == TuiProtocolConnectionState.ready;
}
