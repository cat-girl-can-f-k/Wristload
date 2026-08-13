import 'package:test/test.dart';
import 'package:wristload_tui/src/frontend/fixtures/tui_fixtures.dart';
import 'package:wristload_tui/src/frontend/port/fake_tui_frontend_port.dart';
import 'package:wristload_tui/src/frontend/port/tui_snapshot.dart';

void main() {
  group('FakeTuiFrontendPort', () {
    late FakeTuiFrontendPort port;

    setUp(() {
      port = FakeTuiFrontendPort(initial: TuiFixtures.base());
    });

    tearDown(() async {
      await port.dispose();
    });

    test('emits initial snapshot to new subscribers', () async {
      final snapshots = <TuiSnapshot>[];
      final sub = port.snapshots.listen(snapshots.add);
      await Future<void>.delayed(Duration.zero);
      expect(snapshots, isNotEmpty);
      expect(snapshots.first.revision, greaterThan(0));
      await sub.cancel();
    });

    test('replays the latest snapshot independently to late subscribers',
        () async {
      final next = TuiFixtures.ready(revision: 42);
      port.emit(next);

      final first = await port.snapshots.first;
      final second = await port.snapshots.first;

      expect(first.revision, 42);
      expect(second.revision, 42);
      expect(identical(first, second), isTrue);
    });

    test('records initialize action', () async {
      await port.initialize();
      expect(port.recordedActions.map((a) => a.name), contains('initialize'));
    });

    test('records submitAuthKey without exposing the secret', () async {
      await port.submitAuthKey('deadbeef' * 4);
      final action = port.recordedActions.single;
      expect(action.name, 'submitAuthKey');
      expect(action.args['length'], 32);
      expect(action.args.toString(), isNot(contains('deadbeef')));
      expect(port.snapshot.authKeyLoaded, isFalse);
    });

    test('never records an authkey inside another action payload', () async {
      const secret = '0123456789abcdef0123456789abcdef';
      await port.submitAuthKey(secret);
      await port.clearAuthKey();
      await port.startScan();

      final transcript = port.recordedActions
          .map((action) => '${action.name} ${action.args}')
          .join('\n');
      expect(transcript, isNot(contains(secret)));
      expect(transcript, contains('length: 32'));
    });

    test('records importFiles with literal paths', () async {
      await port.importFiles(['/a/b.bin', '/c/d.rpk']);
      expect(port.recordedActions.single.args['count'], 2);
    });

    test('fixture logs expose stable structured fields', () {
      final log = TuiFixtures.logs().logs.last;
      expect(log.category, TuiLogCategory.install);
      expect(log.eventCode, 'install.failed');
    });

    test('dispose can be called only once', () async {
      await port.dispose();
      await port.dispose();
      expect(port.recordedActions.where((a) => a.name == 'dispose').length, 1);
    });
  });
}
