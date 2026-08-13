import 'package:test/test.dart';
import 'package:wristload_tui/src/frontend/fixtures/tui_fixtures.dart';
import 'package:wristload_tui/src/frontend/input/command.dart';
import 'package:wristload_tui/src/frontend/input/dispatcher.dart';
import 'package:wristload_tui/src/frontend/port/fake_tui_frontend_port.dart';
import 'package:wristload_tui/src/frontend/state/app_state.dart';
import 'package:wristload_tui/src/frontend/terminal/fake_terminal.dart';

void main() {
  group('ActionDispatcher', () {
    late FakeTuiFrontendPort port;
    late AppState state;
    late FakeTerminal terminal;
    late ActionDispatcher dispatcher;
    String? lastNotice;

    setUp(() {
      port = FakeTuiFrontendPort(initial: TuiFixtures.base());
      state = AppState();
      terminal = FakeTerminal();
      dispatcher = ActionDispatcher(
        port: port,
        state: state,
        terminal: terminal,
        onNotice: (message, {isError = false}) => lastNotice = message,
      );
    });

    tearDown(() async {
      dispatcher.dispose();
      await port.dispose();
    });

    test('navigates between views', () async {
      await dispatcher.dispatch(const NavigateCommand(1));
      expect(state.currentView, View.queue);
      await dispatcher.dispatch(const NavigateCommand(0));
      expect(state.currentView, View.devices);
    });

    test('selects next/previous device by id', () async {
      port.emit(TuiFixtures.scanFinished());
      await dispatcher.dispatch(const SelectFirstCommand());
      expect(state.selectedDeviceId, 'AABBCCDDEEFF');
      await dispatcher.dispatch(const SelectNextCommand());
      expect(state.selectedDeviceId, '112233445566');
      await dispatcher.dispatch(const SelectPreviousCommand());
      expect(state.selectedDeviceId, 'AABBCCDDEEFF');
    });

    test('rejects invalid authkey length without calling facade', () async {
      state.showAuthKey = true;
      state.authKeyInput = 'short';
      await dispatcher.dispatch(const SubmitAuthKeyCommand());
      expect(port.recordedActions, isEmpty);
      expect(lastNotice, contains('32'));
      expect(state.authKeyInput, isEmpty);
    });

    test('submits 32-hex authkey and clears input', () async {
      port.emit(TuiFixtures.awaitingAuthKey());
      state.showAuthKey = true;
      state.authKeyInput = 'deadbeef' * 4;
      await dispatcher.dispatch(const SubmitAuthKeyCommand());
      expect(port.recordedActions.single.name, 'submitAuthKey');
      expect(state.authKeyInput, isEmpty);
    });

    test('import splits pasted multiline paths', () async {
      state.showImport = true;
      state.importInput = '  /a/b.bin  \n\n/c/d.rpk\n';
      await dispatcher.dispatch(const SubmitImportCommand());
      expect(port.recordedActions.single.args['count'], 2);
      expect(state.importInput, isEmpty);
    });

    test('prevents concurrent identical actions', () async {
      port.onAction = (p, action) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      };
      final f1 = dispatcher.dispatch(const RefreshPairedCommand());
      final f2 = dispatcher.dispatch(const RefreshPairedCommand());
      await Future.wait([f1, f2]);
      expect(
          port.recordedActions
              .where((a) => a.name == 'refreshPairedDevices')
              .length,
          1);
    });

    test('clears pending after a synchronous facade failure', () async {
      port.onAction = (p, a) => throw StateError('fixture failure');

      await dispatcher.dispatch(const RefreshPairedCommand());
      await dispatcher.dispatch(const RefreshPairedCommand());

      expect(
        port.recordedActions
            .where((action) => action.name == 'refreshPairedDevices')
            .length,
        2,
      );
      expect(lastNotice, '操作失败，请检查日志或重试。');
    });

    test('routes manual fields by the active focus', () async {
      state.showAddDevice = true;
      state.manualDeviceField = ManualDeviceField.address;
      await dispatcher.dispatch(const TypeTextCommand('AA-BB'));
      state.manualDeviceField = ManualDeviceField.displayName;
      await dispatcher.dispatch(const TypeTextCommand('办公室手环'));
      await dispatcher.dispatch(const BackspaceCommand());

      expect(state.manualAddress, 'AA-BB');
      expect(state.manualDisplayName, '办公室手');
    });

    test('submits manual device fields to the facade', () async {
      state.showAddDevice = true;
      state.manualAddress = 'AA-BB-CC-DD-EE-FF';
      state.selectedModelId = 'miwear.watch.n67';
      state.manualDisplayName = 'Office';

      await dispatcher.dispatch(const AddManualDeviceCommand());

      final args = port.recordedActions.single.args;
      expect(args['address'], 'AA-BB-CC-DD-EE-FF');
      expect(args['modelId'], 'miwear.watch.n67');
      expect(args['displayName'], 'Office');
    });

    test('routes settings text and rejects values outside frontend ranges',
        () async {
      state.currentView = View.settings;
      await dispatcher.dispatch(const TypeTextCommand('21'));
      await dispatcher.dispatch(const CycleSettingsFieldCommand());
      await dispatcher.dispatch(const TypeTextCommand('51'));
      await dispatcher.dispatch(const UpdateSettingsCommand());

      expect(state.segmentIntervalInput, '21');
      expect(state.massWindowSizeInput, '51');
      expect(port.recordedActions, isEmpty);
      expect(lastNotice, contains('1 到 20'));
    });

    test('submits values for the active decision without retaining old values',
        () async {
      port.emit(TuiFixtures.pendingDecisions());
      await dispatcher.dispatch(const OpenPendingDecisionCommand());
      await dispatcher.dispatch(const SelectNextCommand());
      await dispatcher.dispatch(const OpenPendingDecisionCommand());
      await dispatcher.dispatch(const CycleDecisionFieldCommand());

      // Open the second decision explicitly after the first has initialized
      // its independent fields.
      state.activeDecisionId = 'd-2';
      state.decisionFieldIndex = 0;
      state.decisionValues
        ..clear()
        ..['faceId'] = '';
      await dispatcher.dispatch(const TypeTextCommand('42'));
      await dispatcher.dispatch(
        DecisionCommand(
            'd-2', true, Map<String, String>.from(state.decisionValues)),
      );

      final args = port.recordedActions.last.args;
      expect(args['decisionId'], 'd-2');
      expect(args['values'], {'faceId': '42'});
    });

    test('does not connect an id that disappeared from the current snapshot',
        () async {
      port.emit(TuiFixtures.scanFinished());
      state.selectedDeviceId = 'AABBCCDDEEFF';
      port.emit(TuiFixtures.base());

      await dispatcher.dispatch(const ConnectCommand());

      expect(port.recordedActions, isEmpty);
      expect(state.selectedDeviceId, isNull);
    });

    test('selects adjacent item when current id disappears', () async {
      port.emit(TuiFixtures.scanFinished());
      state.selectedDeviceId = 'AABBCCDDEEFF';
      port.emit(TuiFixtures.base());
      dispatcher.reconcileSelection();
      expect(state.selectedDeviceId, isNull);
    });
  });
}
