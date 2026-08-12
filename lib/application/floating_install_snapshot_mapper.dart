import '../domain/floating_install_snapshot.dart';
import '../domain/install_models.dart';
import '../domain/install_task.dart';
import 'device_controller.dart';

extension FloatingInstallSnapshotMapper on DeviceController {
  FloatingInstallSnapshot get floatingInstallSnapshot {
    final task = latestTask;
    final entry = task == null ? null : _entryForTask(installQueue, task);
    final phase = _phaseFor(task, entry, queueRunning: queueRunning);
    final queueIndex = entry == null ? -1 : installQueue.indexOf(entry);

    return FloatingInstallSnapshot(
      phase: phase,
      connected: isConnected,
      authenticated: sessionReady,
      deviceName: connectedDeviceName ?? connectedProfile?.displayName ?? '',
      kind: task?.kind ?? entry?.request.kind,
      fileName: task?.fileName ?? entry?.request.metadata.fileName,
      confirmedBytes: task?.confirmedBytes ?? 0,
      totalBytes: task?.totalBytes ?? 0,
      bytesPerSecond: task?.bytesPerSecond,
      queuePosition: queueIndex < 0 ? null : queueIndex + 1,
      queueLength: installQueue.length,
      message: task?.message ?? entry?.message,
      canRetry: entry?.canRetry ?? false,
    );
  }
}

QueueEntry? _entryForTask(List<QueueEntry> queue, InstallTask task) {
  for (final entry in queue.reversed) {
    if (entry.request.kind == task.kind &&
        entry.request.metadata.fileName == task.fileName &&
        (task.md5Hex == null || entry.request.metadata.md5Hex == task.md5Hex)) {
      return entry;
    }
  }
  return null;
}

FloatingInstallPhase _phaseFor(
  InstallTask? task,
  QueueEntry? entry, {
  required bool queueRunning,
}) {
  if (task == null) return FloatingInstallPhase.idle;
  return switch (task.stage) {
    InstallStage.succeeded =>
      queueRunning ? FloatingInstallPhase.done : FloatingInstallPhase.idle,
    InstallStage.cancelled ||
    InstallStage.stateUnknown ||
    InstallStage.failed =>
      FloatingInstallPhase.failed,
    InstallStage.validating ||
    InstallStage.waitingForProtocol ||
    InstallStage.transferring ||
    InstallStage.awaitingDevice =>
      FloatingInstallPhase.installing,
    InstallStage.idle => switch (entry?.stage) {
        QueueStage.done => FloatingInstallPhase.done,
        QueueStage.failed ||
        QueueStage.cancelled ||
        QueueStage.stateUnknown =>
          FloatingInstallPhase.failed,
        QueueStage.installing => FloatingInstallPhase.installing,
        _ => FloatingInstallPhase.idle,
      },
  };
}
