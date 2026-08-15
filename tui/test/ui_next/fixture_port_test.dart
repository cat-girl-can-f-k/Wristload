import 'package:test/test.dart';
import 'package:wristload_tui/src/ui_next/fixture_port.dart';
import 'package:wristload_tui/src/ui_next/port.dart';

void main() {
  test('fixture catalog preserves every documented command-line fixture', () {
    expect(
      UiNextFixtures.names,
      containsAll(<String>[
        'base',
        'scanFinished',
        'queueWaiting',
        'awaitingAuthKey',
        'rfcommRebuildRequired',
        'ready',
        'queueRunningTransfer',
        'awaitingDevice100',
        'installSucceeded',
        'installFailed',
        'installStateUnknown',
        'recoveryAvailable',
        'pendingDecisions',
        'logs',
      ]),
    );
    for (final name in UiNextFixtures.names) {
      expect(UiNextFixtures.load(name), isA<UiSnapshot>(), reason: name);
    }
  });

  test('fixture port is in-memory and emits replacement-ui state', () async {
    final port = FakeUiNextPort(initial: UiNextFixtures.load('scanFinished'));
    final values = <UiSnapshot>[];
    final subscription = port.snapshots.listen(values.add);

    final device = port.snapshot.devices.singleWhere(
      (candidate) => candidate.id == 'AA:BB:CC:DD:EE:FF',
    );
    await port.connect(device.id);
    await port.saveDevice(device.id);

    expect(port.recordedActions, <String>['connect', 'saveDevice']);
    expect(port.snapshot.connectionPhase, UiConnectionPhase.connecting);
    expect(
      port.snapshot.devices
          .singleWhere((candidate) => candidate.id == device.id)
          .saved,
      isTrue,
    );
    expect(values, isNotEmpty);

    await subscription.cancel();
    await port.dispose();
  });
}
