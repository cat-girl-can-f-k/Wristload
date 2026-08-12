import 'package:flutter_test/flutter_test.dart';
import 'package:miwearable_install_tool/application/floating_install_snapshot_mapper.dart';
import 'package:miwearable_install_tool/application/device_controller.dart';
import 'package:miwearable_install_tool/domain/floating_install_snapshot.dart';
import 'package:miwearable_install_tool/domain/install_models.dart';
import 'package:miwearable_install_tool/domain/install_task.dart';

void main() {
  test('floating snapshot survives a method-channel map round trip', () {
    const source = FloatingInstallSnapshot(
      phase: FloatingInstallPhase.installing,
      connected: true,
      authenticated: true,
      deviceName: 'REDMI Watch 5',
      kind: InstallKind.watchface,
      fileName: 'dial.face',
      confirmedBytes: 512,
      totalBytes: 2048,
      bytesPerSecond: 1024.5,
      queuePosition: 2,
      queueLength: 3,
      message: 'transferring',
    );

    final decoded = FloatingInstallSnapshot.fromJson(source.toJson());

    expect(decoded.phase, source.phase);
    expect(decoded.connected, isTrue);
    expect(decoded.authenticated, isTrue);
    expect(decoded.kind, InstallKind.watchface);
    expect(decoded.fileName, 'dial.face');
    expect(decoded.progress, 0.25);
    expect(decoded.queuePosition, 2);
    expect(decoded.queueLength, 3);
  });

  test('invalid or missing channel fields fall back safely', () {
    final decoded = FloatingInstallSnapshot.fromJson({
      'phase': 'futurePhase',
      'confirmedBytes': 300,
      'totalBytes': 100,
      'bytesPerSecond': -1,
      'queuePosition': 4,
      'queueLength': 2,
      'kind': 'firmware',
    });

    expect(decoded.phase, FloatingInstallPhase.idle);
    expect(decoded.connected, isFalse);
    expect(decoded.authenticated, isFalse);
    expect(decoded.deviceName, isEmpty);
    expect(decoded.kind, isNull);
    expect(decoded.confirmedBytes, 100);
    expect(decoded.progress, 1);
    expect(decoded.bytesPerSecond, isNull);
    expect(decoded.queuePosition, isNull);
  });

  test('a twice-failed skipped item returns the floating window to idle', () {
    final controller = DeviceController();
    addTearDown(controller.dispose);
    const metadata = InstallMetadata(
      fileName: 'failed.face',
      fileSize: 1024,
      md5Hex: '0123456789abcdef0123456789abcdef',
      sha256Hex:
          '0000000000000000000000000000000000000000000000000000000000000000',
      faceId: '1234',
    );
    controller.enqueue(const InstallRequest(
      kind: InstallKind.watchface,
      path: r'C:\packages\failed.face',
      metadata: metadata,
    ));
    controller.installQueue.single
      ..stage = QueueStage.failed
      ..failureAttempts = QueueEntry.maximumFailureAttempts
      ..skippedAfterRetry = true;
    controller.latestTask = const InstallTask(
      kind: InstallKind.watchface,
      fileName: 'failed.face',
      stage: InstallStage.failed,
      message: '握手超时',
      md5Hex: '0123456789abcdef0123456789abcdef',
    );

    expect(
      controller.floatingInstallSnapshot.phase,
      FloatingInstallPhase.idle,
    );
  });
}
