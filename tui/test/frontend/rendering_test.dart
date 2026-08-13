import 'package:test/test.dart';
import 'package:wristload_tui/src/frontend/app/tui_app.dart';
import 'package:wristload_tui/src/frontend/fixtures/tui_fixtures.dart';
import 'package:wristload_tui/src/frontend/port/fake_tui_frontend_port.dart';
import 'package:wristload_tui/src/frontend/state/app_state.dart';
import 'package:wristload_tui/src/frontend/terminal/cell_width.dart';
import 'package:wristload_tui/src/frontend/views/devices_view.dart';
import 'package:wristload_tui/src/frontend/views/queue_view.dart';
import 'package:wristload_tui/src/frontend/views/settings_view.dart';
import 'package:wristload_tui/src/frontend/views/task_view.dart';
import 'package:wristload_tui/src/frontend/widgets/frame.dart';
import 'package:wristload_tui/src/frontend/widgets/progress.dart';
import 'package:wristload_tui/src/frontend/widgets/status_bar.dart';
import 'package:wristload_tui/src/frontend/terminal/fake_terminal.dart';
import 'package:wristload_tui/src/frontend/theme/ansi_text.dart';
import 'package:wristload_tui/src/frontend/views/diagnostic_log_panel.dart';

void main() {
  group('Rendering', () {
    void assertNoOverflow(Frame frame, int width) {
      for (final row in frame.rows) {
        expect(CellWidth.of(row), lessThanOrEqualTo(width),
            reason: 'Row overflow: $row');
      }
    }

    test('devices view renders within 80x24 without overflow', () {
      const width = 80;
      const height = 24;
      final frame = Frame(width: width, height: height);
      final snapshot = TuiFixtures.scanFinished();
      final state = AppState();
      DevicesView(snapshot: snapshot, state: state, frame: frame).render();
      assertNoOverflow(frame, width);
    });

    test('queue view shows pending decisions', () {
      const width = 100;
      const height = 30;
      final frame = Frame(width: width, height: height);
      final snapshot = TuiFixtures.pendingDecisions();
      final state = AppState();
      QueueView(snapshot: snapshot, state: state, frame: frame).render();
      assertNoOverflow(frame, width);
      final text = frame.rows.join('\n');
      expect(text, contains('表盘分辨率不匹配'));
      expect(text, contains('缺失 faceId'));
    });

    test('task view preserves stateUnknown wording', () {
      const width = 100;
      const height = 30;
      final frame = Frame(width: width, height: height);
      final snapshot = TuiFixtures.installStateUnknown();
      final state = AppState();
      TaskView(snapshot: snapshot, state: state, frame: frame).render();
      assertNoOverflow(frame, width);
      final text = frame.rows.join('\n');
      expect(text, contains('设备状态未知'));
      expect(text, isNot(contains('安装成功')));
      expect(text, isNot(contains('安装失败')));
    });

    test('100% awaitingDevice does not render success', () {
      const width = 100;
      const height = 30;
      final frame = Frame(width: width, height: height);
      final snapshot = TuiFixtures.awaitingDevice100();
      final state = AppState();
      TaskView(snapshot: snapshot, state: state, frame: frame).render();
      assertNoOverflow(frame, width);
      final text = frame.rows.join('\n');
      expect(text, contains('等待设备安装结果'));
      expect(text, isNot(contains('安装成功')));
    });

    test('progress uses confirmedBytes not queuedBytes', () {
      final lines = ProgressWidget(
        width: 60,
        confirmedBytes: 50,
        queuedBytes: 80,
        totalBytes: 100,
        stageLabel: '传输中',
      ).render();
      expect(lines.first, contains('50%'));
      expect(lines.join('\n'), contains('已提交等待确认: 80B'));
    });

    test('long CJK text fits within width', () {
      const width = 80;
      const height = 24;
      final frame = Frame(width: width, height: height);
      final snapshot = TuiFixtures.longText();
      final state = AppState();
      DevicesView(snapshot: snapshot, state: state, frame: frame).render();
      QueueView(snapshot: snapshot, state: state, frame: frame).render();
      assertNoOverflow(frame, width);
    });

    test('MAC address is not truncated in device list', () {
      const width = 100;
      const height = 24;
      final frame = Frame(width: width, height: height);
      final snapshot = TuiFixtures.scanFinished();
      final state = AppState();
      DevicesView(snapshot: snapshot, state: state, frame: frame).render();
      final text = frame.rows.join('\n');
      expect(text, contains('AA-BB-CC-DD-EE-FF'));
      expect(text, contains('11-22-33-44-55-66'));
    });

    test('devices view exposes the RFCOMM rebuild requirement', () {
      const width = 100;
      final frame = Frame(width: width, height: 24);
      DevicesView(
        snapshot: TuiFixtures.rfcommRebuildRequired(),
        state: AppState(),
        frame: frame,
        supportsColor: false,
      ).render();

      assertNoOverflow(frame, width);
      expect(frame.rows.join('\n'), contains('必须重建 RFCOMM'));
    });

    test('status bar exposes the RFCOMM rebuild requirement', () {
      final line = StatusBar(width: 140, supportsColor: false)
          .render(TuiFixtures.rfcommRebuildRequired());

      expect(line, contains('需重建 RFCOMM'));
      expect(CellWidth.of(line), lessThanOrEqualTo(140));
    });

    test('manual device fields render their active focus', () {
      const width = 100;
      final frame = Frame(width: width, height: 30);
      final state = AppState()
        ..showAddDevice = true
        ..manualDeviceField = ManualDeviceField.displayName;

      DevicesView(
        snapshot: TuiFixtures.base(),
        state: state,
        frame: frame,
      ).render();

      final text = frame.rows.join('\n');
      expect(text, contains('显示名称: 可选█'));
      expect(text, isNot(contains('地址: AA-BB-CC-DD-EE-FF█')));
    });

    test('settings view renders the selected field as focused', () {
      const width = 100;
      final frame = Frame(width: width, height: 30);
      final state = AppState()..settingsField = SettingsField.massWindowSize;

      SettingsView(
        snapshot: TuiFixtures.base(),
        state: state,
        frame: frame,
      ).render();

      final text = frame.rows.join('\n');
      expect(text, contains('Mass 窗口大小: 3█'));
      expect(text, isNot(contains('分段间隔 (ms): 5█')));
    });

    test('renders without overflow at 60x20', () {
      const width = 60;
      const height = 20;
      final frame = Frame(width: width, height: height);
      final snapshot = TuiFixtures.scanFinished();
      final state = AppState();
      DevicesView(snapshot: snapshot, state: state, frame: frame).render();
      assertNoOverflow(frame, width);
    });

    test('renders without overflow at 120x40', () {
      const width = 120;
      const height = 40;
      final frame = Frame(width: width, height: height);
      final snapshot = TuiFixtures.queueRunningTransfer();
      final state = AppState();
      TaskView(snapshot: snapshot, state: state, frame: frame).render();
      QueueView(snapshot: snapshot, state: state, frame: frame).render();
      assertNoOverflow(frame, width);
    });

    test('59x19 fits within bounds even with compact fallback', () {
      const width = 59;
      const height = 19;
      final frame = Frame(width: width, height: height);
      final snapshot = TuiFixtures.scanFinished();
      final state = AppState();
      DevicesView(snapshot: snapshot, state: state, frame: frame).render();
      assertNoOverflow(frame, width);
    });

    test('wide layout reserves a persistent diagnostic column at 120 columns', () async {
      final terminal = FakeTerminal(rows: 24, columns: 120);
      final port = FakeTuiFrontendPort(initial: TuiFixtures.logs());
      final app = TuiApp(terminal: terminal, port: port, previewLabel: 'TEST');
      final run = app.run();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(terminal.buffer, contains('LIVE LOG'));
      expect(terminal.buffer, contains('EVENTS'));
      for (final line in terminal.lines) {
        expect(CellWidth.of(line), lessThanOrEqualTo(120), reason: line);
      }

      terminal.key('q');
      await run;
      await port.dispose();
    });

    test('narrow layouts do not render the persistent diagnostic column', () async {
      for (final width in [60, 80]) {
        final terminal = FakeTerminal(rows: 24, columns: width);
        final port = FakeTuiFrontendPort(initial: TuiFixtures.logs());
        final app = TuiApp(terminal: terminal, port: port, previewLabel: 'TEST');
        final run = app.run();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(terminal.buffer, isNot(contains('LIVE LOG')), reason: '$width columns');
        for (final line in terminal.lines) {
          expect(CellWidth.of(line), lessThanOrEqualTo(width), reason: line);
        }

        terminal.key('q');
        await run;
        await port.dispose();
      }
    });

    test('authkey prompt opens automatically and does not reopen for same snapshot after Esc', () async {
      final terminal = FakeTerminal(rows: 24, columns: 80);
      final port = FakeTuiFrontendPort(initial: TuiFixtures.awaitingAuthKey());
      final app = TuiApp(terminal: terminal, port: port, previewLabel: 'TEST');
      final run = app.run();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(terminal.buffer, contains('输入 authkey'));

      terminal.key('\x1b');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      port.emit(TuiFixtures.awaitingAuthKey(revision: 9));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(terminal.buffer, isNot(contains('输入 authkey')));

      terminal.key('q');
      await run;
      await port.dispose();
    });

    test('snapshot notice renders at the bottom and the same id does not extend it',
        () async {
      final terminal = FakeTerminal(rows: 24, columns: 100);
      final port = FakeTuiFrontendPort(
        initial: TuiFixtures.rfcommRebuildRequired(),
      );
      final app = TuiApp(
        terminal: terminal,
        port: port,
        previewLabel: 'TEST',
        noticeDuration: const Duration(milliseconds: 200),
      );
      final run = app.run();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      String noticeLine() {
        final lines = terminal.lines;
        expect(lines.length, greaterThanOrEqualTo(3));
        return lines[lines.length - 3];
      }

      expect(noticeLine(), contains('必须重建 RFCOMM'));

      port.emit(TuiFixtures.rfcommRebuildRequired(revision: 99));
      await Future<void>.delayed(const Duration(milliseconds: 130));

      expect(noticeLine(), isNot(contains('必须重建 RFCOMM')));

      terminal.key('q');
      await run;
      await port.dispose();
    });

    test('ANSI diagnostics remain width-safe and can be disabled', () {
      final entries = TuiFixtures.logs().logs;
      final colored = DiagnosticLogPanel(
        entries: entries,
        width: 44,
        height: 3,
        ansi: true,
      ).render();
      final plain = DiagnosticLogPanel(
        entries: entries,
        width: 44,
        height: 3,
        ansi: false,
      ).render();

      expect(colored.any(AnsiText.containsAnsi), isTrue);
      expect(plain.any(AnsiText.containsAnsi), isFalse);
      expect(colored.every((line) => CellWidth.of(line) == 44), isTrue);
      expect(plain.every((line) => CellWidth.of(line) == 44), isTrue);
    });
  });
}
