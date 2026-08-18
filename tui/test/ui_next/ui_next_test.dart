import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:wristload_tui/src/ui_next/cell_width.dart';
import 'package:wristload_tui/src/ui_next/layout.dart';
import 'package:wristload_tui/src/ui_next/port.dart';
import 'package:wristload_tui/src/ui_next/shell.dart';
import 'package:wristload_tui/src/ui_next/state.dart';
import 'package:wristload_tui/src/ui_next/terminal.dart';
import 'package:wristload_tui/src/ui_next/theme.dart';

void main() {
  final devices = <UiDevice>[
    UiDevice(
      name: 'Xiaomi Smart Band 10 超长完整设备名称 ⌚️ 测试版',
      macAddress: 'AA-BB-CC-DD-EE-01',
      support: UiDeviceSupport.supported,
      saved: true,
      savedAuthKey: '00112233445566778899AABBCCDDEEFF',
    ),
    UiDevice(
      name: '小米手环 9 Pro 国际版',
      macAddress: 'AA:BB:CC:DD:EE:02',
      support: UiDeviceSupport.unknown,
    ),
    UiDevice(
      name: '\x1b[31mANSI 名称\x1b[0m 与 emoji 🧪',
      macAddress: 'AA:BB:CC:DD:EE:03',
      support: UiDeviceSupport.unsupported,
    ),
  ];

  group('UiNextRenderer', () {
    for (final width in [60, 80, 120]) {
      test('responsive width ' + width.toString(), () {
        final state = UiNextState()..select(devices.first.id);
        final result = const UiNextRenderer().render(
          snapshot: UiSnapshot(devices: devices),
          state: state,
          width: width,
          height: 28,
          color: false,
        );
        for (final line in const LineSplitter().convert(result.text)) {
          expect(UiCellWidth.of(line), lessThanOrEqualTo(width), reason: line);
        }
        final plain = UiCellWidth.stripAnsi(result.text);
        expect(plain, contains('DEVICES'));
        expect(plain, contains('DEVICE / CONNECTION'));
        expect(plain, contains('ACTIVITY'));
        expect(plain, contains('AA:BB:CC:DD:EE:01'));
        expect(plain, contains('00112233445566778899AABBCCDDEEFF'));
        expect(plain, contains('Xiaomi Smart Band 10'));
        final expected = width == 60
            ? UiLayoutMode.compact
            : width == 80
                ? UiLayoutMode.wrapped
                : UiLayoutMode.wide;
        expect(result.mode, expected);
      });
    }

    test('detail exposes complete CJK and emoji device name', () {
      final state = UiNextState()
        ..select(devices.first.id)
        ..detailOpen = true;
      final result = const UiNextRenderer().render(
        snapshot: UiSnapshot(devices: devices),
        state: state,
        width: 60,
        height: 24,
        color: false,
      );
      final text = UiCellWidth.stripAnsi(result.text).replaceAll('\n', '');
      expect(text, contains('Xiaomi Smart Band 10 超长完整设备名称 ⌚️ 测试版'));
      expect(text, contains('[L]日志'));
      expect(
        result.hitRegions.any((hit) => hit.action == UiHitAction.openLogs),
        isTrue,
      );
    });

    test('detail keeps saved device information but omits runtime status', () {
      final connected = UiDevice(
        name: '已连接设备',
        macAddress: 'AA:BB:CC:DD:EE:09',
        support: UiDeviceSupport.supported,
        saved: true,
        savedAuthKey: '00112233445566778899AABBCCDDEEFF',
        connected: true,
      );
      final state = UiNextState()
        ..select(connected.id)
        ..detailOpen = true;
      final result = const UiNextRenderer().render(
        snapshot: UiSnapshot(
          devices: [connected],
          scanning: true,
          notice: '连接中',
        ),
        state: state,
        width: 80,
        height: 24,
        color: false,
      );

      final text = UiCellWidth.stripAnsi(result.text);
      expect(text, contains('名称: 已连接设备'));
      expect(text, contains('MAC: AA:BB:CC:DD:EE:09'));
      expect(text, contains('支持: 支持'));
      expect(text, contains('authkey: 00112233445566778899AABBCCDDEEFF'));
      expect(text, contains('保存: 是'));
      expect(text, isNot(contains('连接: 已连接')));
      expect(text, isNot(contains('状态: 连接中')));
    });

    test('sanitizes external controls and retains graphemes when wrapped', () {
      final device = UiDevice(
        name: '\x1b[31m中⌚️文\x1b[0m\n名称',
        macAddress: 'AA:BB:CC:DD:EE:04',
        support: UiDeviceSupport.supported,
      );
      final state = UiNextState();
      final result = const UiNextRenderer().render(
        snapshot: UiSnapshot(
          devices: [device],
          notice: '\x1b]8;;https://invalid.example\x07不安全\x1b]8;;\x07',
        ),
        state: state,
        width: 2,
        height: 40,
        color: false,
      );

      final text = result.text;
      final plain = UiCellWidth.stripAnsi(text);
      expect(text, isNot(contains('\x1b')));
      expect(plain, contains('中'));
      expect(plain, contains('⌚️'));
      expect(plain, contains('文'));
      expect(plain, contains('名'));
      expect(plain, contains('称'));
      for (final line in const LineSplitter().convert(text)) {
        expect(UiCellWidth.of(line), lessThanOrEqualTo(2), reason: line);
      }
    });

    test('detail name stays reachable by scrolling on a small terminal', () {
      final device = UiDevice(
        name: '第一段 第二段 第三段 第四段 😀 最后一段',
        macAddress: 'AA:BB:CC:DD:EE:05',
        support: UiDeviceSupport.supported,
      );
      final state = UiNextState()
        ..select(device.id)
        ..detailOpen = true;
      final first = const UiNextRenderer().render(
        snapshot: UiSnapshot(devices: [device]),
        state: state,
        width: 12,
        height: 7,
        color: false,
      );
      expect(first.maxScrollOffset, greaterThan(0));

      var seen = false;
      for (var offset = 0; offset <= first.maxScrollOffset; offset++) {
        state.scrollOffset = offset;
        final page = const UiNextRenderer().render(
          snapshot: UiSnapshot(devices: [device]),
          state: state,
          width: 12,
          height: 7,
          color: false,
        );
        if (UiCellWidth.stripAnsi(page.text).contains('最后一段')) {
          seen = true;
          break;
        }
      }
      expect(seen, isTrue);
    });

    test('uses resolved black theme colors without color injection', () {
      final result = const UiNextRenderer().render(
        snapshot: UiSnapshot(
          devices: devices,
          themeId: 'black-cyan',
          notice: '状态正常',
        ),
        state: UiNextState()..select(devices.first.id),
        width: 80,
        height: 24,
        color: true,
      );
      expect(result.text, startsWith(UiTheme.blackCyan.background));
      expect(result.text, contains(UiTheme.blackCyan.primary));
      expect(UiCellWidth.stripAnsi(result.text), contains('状态正常'));
    });

    test('footer exposes the separate diagnostic log viewer action', () {
      final result = const UiNextRenderer().render(
        snapshot: UiSnapshot(devices: devices),
        state: UiNextState()..select(devices.first.id),
        width: 80,
        height: 24,
        color: false,
      );

      expect(UiCellWidth.stripAnsi(result.text), contains('[L]日志'));
      expect(
        result.hitRegions.any((hit) => hit.action == UiHitAction.openLogs),
        isTrue,
      );
    });

    test('installation panel distinguishes verified and pending success', () {
      final verified = const UiNextRenderer().render(
        snapshot: UiSnapshot(
          devices: devices,
          install: const UiInstallStatus(
            phase: UiInstallPhase.succeeded,
            fileName: 'Weather.rpk',
            confirmedBytes: 100,
            totalBytes: 100,
            successVerifiedByDeviceBusinessEvent: true,
          ),
        ),
        state: UiNextState()..select(devices.first.id),
        width: 120,
        height: 32,
        color: false,
      );
      final pending = const UiNextRenderer().render(
        snapshot: UiSnapshot(
          devices: devices,
          install: const UiInstallStatus(
            phase: UiInstallPhase.succeeded,
            fileName: 'Weather.rpk',
            confirmedBytes: 100,
            totalBytes: 100,
          ),
        ),
        state: UiNextState()..select(devices.first.id),
        width: 120,
        height: 32,
        color: false,
      );

      final verifiedText = UiCellWidth.stripAnsi(verified.text);
      final pendingText = UiCellWidth.stripAnsi(pending.text);
      expect(verifiedText, contains('INSTALL'));
      expect(verifiedText, contains('设备确认安装成功'));
      expect(pendingText, contains('INSTALL'));
      expect(pendingText, contains('等待设备安装结果'));
      expect(pendingText, isNot(contains('设备确认安装成功')));
    });

    test('connection inspector uses only the reported high-level phase', () {
      UiLayoutResult render(UiConnectionPhase phase) =>
          const UiNextRenderer().render(
            snapshot: UiSnapshot(
              devices: devices,
              connectionPhase: phase,
            ),
            state: UiNextState()..select(devices.first.id),
            width: 120,
            height: 28,
            color: false,
          );

      final connecting = UiCellWidth.stripAnsi(
        render(UiConnectionPhase.connecting).text,
      );
      final ready = UiCellWidth.stripAnsi(render(UiConnectionPhase.ready).text);
      final failed =
          UiCellWidth.stripAnsi(render(UiConnectionPhase.failed).text);

      expect(connecting, contains('连接中'));
      expect(connecting, isNot(contains('Session READY')));
      expect(ready, contains('Session READY'));
      expect(failed, contains('连接失败'));
      // The application snapshot has no per-stage transport contract. The
      // inspector may name the pipeline, but it must mark every unavailable
      // stage as unreported rather than infer progress from a broad phase.
      expect(failed, contains('RFCOMM  - 未报告'));
      expect(failed, contains('f=26  - 未报告'));
      expect(failed, contains('f=27  - 未报告'));
    });

    test('command bar exposes only the phase-appropriate connection action',
        () {
      List<String> actionsFor(UiConnectionPhase phase) => const UiNextRenderer()
          .render(
            snapshot: UiSnapshot(
              devices: devices,
              connectionPhase: phase,
            ),
            state: UiNextState()..select(devices.first.id),
            width: 160,
            height: 28,
            color: false,
          )
          .visibleCommandActionNames;

      for (final phase in <UiConnectionPhase>[
        UiConnectionPhase.disconnected,
        UiConnectionPhase.failed,
      ]) {
        expect(actionsFor(phase), contains(UiHitAction.connect.name));
        expect(actionsFor(phase), isNot(contains(UiHitAction.disconnect.name)));
      }
      for (final phase in <UiConnectionPhase>[
        UiConnectionPhase.connecting,
        UiConnectionPhase.awaitingAuthKey,
        UiConnectionPhase.authenticating,
        UiConnectionPhase.ready,
      ]) {
        expect(actionsFor(phase), contains(UiHitAction.disconnect.name));
        expect(actionsFor(phase), isNot(contains(UiHitAction.connect.name)));
      }
      expect(
        actionsFor(UiConnectionPhase.disconnecting),
        isNot(anyOf(
          contains(UiHitAction.connect.name),
          contains(UiHitAction.disconnect.name),
        )),
      );
    });
  });

  group('UiNextShell', () {
    test('starts scanning after successful startup initialization', () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(devices: devices));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      expect(port.actions, ['initialize', 'scan']);

      terminal.key('q');
      await running;
    });

    test('does not scan when startup initialization is rejected', () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(
        UiSnapshot(devices: devices),
        initializeResult: const UiActionResult.rejected('初始化失败'),
      );
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      expect(port.actions, ['initialize']);

      terminal.key('q');
      await running;
    });

    test('does not scan over an auto-connect startup state', () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(
        UiSnapshot(
          devices: devices,
          connectionPhase: UiConnectionPhase.connecting,
        ),
      );
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      expect(port.actions, ['initialize']);

      terminal.key('q');
      await running;
    });

    test('keyboard and mouse share normalized MAC selection', () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(devices: devices));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      terminal.key('\x1b[B');
      await _pump();
      expect(shell.state.selectedDeviceId, devices[1].id);

      final firstHit = shell.latestLayout!.hitRegions.firstWhere(
        (hit) => hit.deviceId == devices.first.id,
      );
      terminal.click(firstHit.rect.left, firstHit.rect.top);
      await _pump();
      expect(shell.state.selectedDeviceId, devices.first.id);

      terminal.key('q');
      await running;
      expect(terminal.mouseCapture, isFalse);
      expect(terminal.rawMode, isFalse);
      expect(terminal.altBuffer, isFalse);
      expect(terminal.cursorVisible, isTrue);
    });

    test('wheel and resize preserve selected MAC and rebuild hit regions',
        () async {
      final many = List.generate(
        12,
        (index) => UiDevice(
          name: '设备 ' + index.toString() + ' 的完整中文名称',
          macAddress:
              'AA:BB:CC:DD:EE:' + index.toRadixString(16).padLeft(2, '0'),
          support: UiDeviceSupport.supported,
        ),
      );
      final terminal = _FakeTerminal(rows: 20, columns: 60);
      final shell = UiNextShell(
        terminal: terminal,
        port: _FakePort(UiSnapshot(devices: many)),
      );
      final running = shell.run();
      await _pump();
      final selected = shell.state.selectedDeviceId;

      terminal.scroll(2, 6, down: true);
      await _pump();
      expect(shell.state.scrollOffset, greaterThan(0));
      expect(shell.state.selectedDeviceId, selected);

      terminal.resize(32, 120);
      await _pump();
      expect(shell.latestLayout!.mode, UiLayoutMode.wide);
      expect(shell.state.selectedDeviceId, selected);
      expect(
        shell.latestLayout!.hitRegions.where((hit) => hit.deviceId != null),
        isNotEmpty,
      );

      terminal.key('q');
      await running;
    });

    test('connect intent routes the stable MAC through the port', () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(devices: devices));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();
      terminal.key('c');
      await _pump();
      expect(port.connected, [devices.first.id]);
      terminal.key('q');
      await running;
    });

    test('arrow enters the command bar and Enter dispatches focus', () async {
      final terminal = _FakeTerminal(rows: 28, columns: 120);
      final port = _FakePort(UiSnapshot(devices: devices));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      terminal.key('\x1b[B');
      await _pump();
      terminal.key('\x1b[B');
      await _pump();
      final selected = devices.last.id;
      expect(shell.state.selectedDeviceId, selected);

      terminal.key('\x1b[B');
      await _pump();
      expect(shell.state.focus, UiFocusTarget.commandBar);
      expect(shell.state.focusedActionName, UiHitAction.connect.name);

      terminal.key('\x1b[D');
      await _pump();
      expect(shell.state.focusedActionName, UiHitAction.connect.name);
      terminal.key('\x1b[C');
      await _pump();
      expect(shell.state.focusedActionName, UiHitAction.scan.name);

      terminal.key('\x1b[A');
      await _pump();
      expect(shell.state.focus, UiFocusTarget.deviceBrowser);
      expect(shell.state.selectedDeviceId, selected);

      terminal.key('\x1b[B');
      await _pump();
      terminal.key('\r');
      await _pump();
      expect(port.connected, [selected]);

      terminal.key('q');
      await running;
    });

    test('empty browser can reach and leave the command bar with arrows',
        () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final shell = UiNextShell(
        terminal: terminal,
        port: _FakePort(UiSnapshot(devices: const [])),
      );
      final running = shell.run();
      await _pump();

      terminal.key('\x1b[B');
      await _pump();
      expect(shell.state.focus, UiFocusTarget.commandBar);
      expect(shell.state.focusedActionName, isNotNull);
      terminal.key('\x1b[A');
      await _pump();
      expect(shell.state.focus, UiFocusTarget.deviceBrowser);
      expect(shell.state.selectedDeviceId, isNull);

      terminal.key('q');
      await running;
    });

    test('mouse command activation immediately paints the shared focus',
        () async {
      final terminal = _FakeTerminal(rows: 28, columns: 120);
      final pendingConnect = Completer<UiActionResult>();
      final port = _FakePort(
        UiSnapshot(devices: devices),
        pendingConnect: pendingConnect,
      );
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();
      final hit = shell.latestLayout!.hitRegions.firstWhere(
        (candidate) =>
            candidate.action == UiHitAction.connect &&
            candidate.isCommandAction,
      );
      final writesBeforeClick = terminal.writes.length;

      terminal.click(hit.rect.left, hit.rect.top);
      await _pump();

      expect(shell.state.focus, UiFocusTarget.commandBar);
      expect(shell.state.focusedActionName, UiHitAction.connect.name);
      expect(terminal.writes.length, greaterThan(writesBeforeClick));
      expect(
        UiCellWidth.stripAnsi(shell.latestLayout!.text),
        contains('> [Enter/c]连接 <'),
      );
      expect(port.connected, [devices.first.id]);

      pendingConnect.complete(const UiActionResult.accepted());
      await _pump();
      terminal.key('q');
      await running;
    });

    test(
        'command focus normalizes after conditional actions disappear or resize',
        () async {
      final directed = UiDevice(
        name: '定向测试设备',
        macAddress: 'AA:BB:CC:DD:EE:10',
        support: UiDeviceSupport.supported,
        isDirectedSessionTarget: true,
      );
      final terminal = _FakeTerminal(rows: 28, columns: 120);
      final port = _FakePort(UiSnapshot(devices: [directed]));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      terminal.key('\x1b[B');
      await _pump();
      final directedIndex = shell.latestLayout!.visibleCommandActionNames
          .indexOf(UiHitAction.directedConnect.name);
      expect(directedIndex, greaterThanOrEqualTo(0));
      for (var index = 0; index < directedIndex; index++) {
        terminal.key('\x1b[C');
        await _pump();
      }
      expect(shell.state.focusedActionName, UiHitAction.directedConnect.name);

      port.emitSnapshot(UiSnapshot(devices: [devices[1]]));
      await _pump();
      expect(shell.state.focus, UiFocusTarget.commandBar);
      expect(
        shell.state.focusedActionName,
        shell.latestLayout!.visibleCommandActionNames.first,
      );

      shell.state.focusCommandBar(UiHitAction.theme.name);
      terminal.resize(10, 40);
      await _pump();
      expect(
        shell.latestLayout!.visibleCommandActionNames,
        contains(shell.state.focusedActionName),
      );

      terminal.key('q');
      await running;
    });

    test('short command bar pages keep actions reachable by arrows and mouse',
        () async {
      final terminal = _FakeTerminal(rows: 10, columns: 40);
      final port = _FakePort(UiSnapshot(devices: [devices.first]));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      expect(shell.latestLayout!.commandPageCount, greaterThan(1));
      expect(
        shell.latestLayout!.hitRegions
            .any((hit) => hit.action == UiHitAction.nextCommandPage),
        isTrue,
      );

      // One selected device means Down enters the command bar. Moving right
      // past a page edge must reveal later context actions.
      terminal.key('\x1b[B');
      await _pump();
      expect(shell.state.focus, UiFocusTarget.commandBar);
      for (var step = 0;
          shell.state.focusedActionName != UiHitAction.install.name &&
              step < 24;
          step++) {
        terminal.key('\x1b[C');
        await _pump();
      }
      expect(shell.state.focusedActionName, UiHitAction.install.name);
      expect(shell.latestLayout!.commandPage, greaterThan(0));

      terminal.key('\r');
      await _pump();
      expect(shell.state.modal, UiModal.installPath);
      expect(shell.state.modalTargetDeviceId, devices.first.id);
      terminal.key('\x1b');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // The visible pager has the same effect for mouse users and rebuilds
      // the action hit regions for the new page.
      final next = shell.latestLayout!.hitRegions.firstWhere(
        (hit) => hit.action == UiHitAction.nextCommandPage,
      );
      terminal.click(next.rect.left, next.rect.top);
      await _pump();
      expect(shell.latestLayout!.commandPage, 1);
      expect(shell.state.focus, UiFocusTarget.commandBar);
      expect(shell.state.focusedActionName, isNotNull);

      final previous = shell.latestLayout!.hitRegions.firstWhere(
        (hit) => hit.action == UiHitAction.previousCommandPage,
      );
      terminal.click(previous.rect.left, previous.rect.top);
      await _pump();
      expect(shell.latestLayout!.commandPage, 0);

      terminal.key('q');
      await running;
    });

    test('extremely narrow command pages keep mouse hitboxes after resize',
        () async {
      final terminal = _FakeTerminal(rows: 10, columns: 8);
      final port = _FakePort(UiSnapshot(devices: [devices.first]));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      void expectCommandHitsInBounds(int width) {
        final commandHits = shell.latestLayout!.hitRegions.where(
          (hit) =>
              hit.isCommandAction ||
              hit.action == UiHitAction.previousCommandPage ||
              hit.action == UiHitAction.nextCommandPage,
        );
        expect(commandHits, isNotEmpty);
        for (final hit in commandHits) {
          expect(hit.rect.left, inInclusiveRange(1, width));
          expect(hit.rect.right, inInclusiveRange(hit.rect.left, width));
          expect(hit.rect.top, greaterThanOrEqualTo(1));
        }
      }

      expect(shell.latestLayout!.commandPageCount, greaterThan(1));
      expectCommandHitsInBounds(8);
      final next = shell.latestLayout!.hitRegions.firstWhere(
        (hit) => hit.action == UiHitAction.nextCommandPage,
      );
      terminal.click(next.rect.left, next.rect.top);
      await _pump();
      expect(shell.latestLayout!.commandPage, 1);
      expectCommandHitsInBounds(8);
      final previous = shell.latestLayout!.hitRegions.firstWhere(
        (hit) => hit.action == UiHitAction.previousCommandPage,
      );
      terminal.click(previous.rect.left, previous.rect.top);
      await _pump();
      expect(shell.latestLayout!.commandPage, 0);

      terminal.resize(8, 6);
      await _pump();
      expectCommandHitsInBounds(6);
      final resizedNext = shell.latestLayout!.hitRegions.firstWhere(
        (hit) => hit.action == UiHitAction.nextCommandPage,
      );
      terminal.click(resizedNext.rect.left, resizedNext.rect.top);
      await _pump();
      expect(shell.latestLayout!.commandPage, 1);

      // One action fits on a page at this width, so Left/Right cross the
      // boundary and Enter executes the same focused action that mouse
      // navigation made visible.
      terminal.key('\x1b[D');
      await _pump();
      expect(shell.latestLayout!.commandPage, 0);
      terminal.key('\x1b[C');
      await _pump();
      expect(shell.latestLayout!.commandPage, 1);
      terminal.key('\r');
      await _pump();
      expect(port.actions, contains('scan'));

      terminal.key('q');
      await running;
    });

    test('sub-ten command pagination stays within terminal bounds', () {
      for (final width in Iterable<int>.generate(9, (index) => index + 1)) {
        final state = UiNextState()..select(devices.first.id);
        final result = const UiNextRenderer().render(
          snapshot: UiSnapshot(devices: [devices.first]),
          state: state,
          width: width,
          height: 10,
          color: false,
        );

        expect(result.commandPageCount, greaterThan(1), reason: 'width=$width');
        for (final line in const LineSplitter().convert(result.text)) {
          expect(
            UiCellWidth.of(line),
            lessThanOrEqualTo(width),
            reason: 'width=$width line=$line',
          );
        }
        final pagerHits = result.hitRegions.where(
          (hit) =>
              hit.action == UiHitAction.previousCommandPage ||
              hit.action == UiHitAction.nextCommandPage,
        );
        expect(pagerHits, isNotEmpty, reason: 'width=$width');
        for (final hit in pagerHits) {
          expect(hit.rect.left, inInclusiveRange(1, width));
          expect(hit.rect.right, inInclusiveRange(hit.rect.left, width));
        }
      }
    });

    test('directed keyboard and hit action use only the dedicated port call',
        () async {
      final directed = UiDevice(
        name: '本次定向连接设备',
        macAddress: 'AA:BB:CC:DD:EE:10',
        support: UiDeviceSupport.supported,
        isDirectedSessionTarget: true,
      );
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(devices: [directed, devices[1]]));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      terminal.key('g');
      await _pump();
      expect(port.directedConnectCount, 1);
      expect(port.connected, isEmpty);

      final directedHit = shell.latestLayout!.hitRegions.firstWhere(
        (hit) => hit.action == UiHitAction.directedConnect,
      );
      terminal.click(directedHit.rect.left, directedHit.rect.top);
      await _pump();
      expect(port.directedConnectCount, 2);
      expect(port.connected, isEmpty);

      terminal.key('q');
      await running;
    });

    test('Enter, c, and ordinary connect keep strict connection behavior',
        () async {
      final directed = UiDevice(
        name: '本次定向连接设备',
        macAddress: 'AA:BB:CC:DD:EE:10',
        support: UiDeviceSupport.supported,
        isDirectedSessionTarget: true,
      );
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(devices: [directed]));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      terminal.key('\r');
      await _pump();
      terminal.key('c');
      await _pump();
      final strictHit = shell.latestLayout!.hitRegions.firstWhere(
        (hit) => hit.action == UiHitAction.connect,
      );
      terminal.click(strictHit.rect.left, strictHit.rect.top);
      await _pump();

      expect(port.connected, [directed.id, directed.id, directed.id]);
      expect(port.directedConnectCount, 0);
      terminal.key('q');
      await running;
    });

    test('g does nothing after selecting a non-directed device', () async {
      final directed = UiDevice(
        name: '本次定向连接设备',
        macAddress: 'AA:BB:CC:DD:EE:10',
        support: UiDeviceSupport.supported,
        isDirectedSessionTarget: true,
      );
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(devices: [directed, devices[1]]));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      terminal.key('\x1b[B');
      await _pump();
      expect(shell.state.selectedDeviceId, devices[1].id);
      expect(
        shell.latestLayout!.hitRegions
            .where((hit) => hit.action == UiHitAction.directedConnect),
        isEmpty,
      );
      terminal.key('g');
      await _pump();
      expect(port.directedConnectCount, 0);
      expect(port.connected, isEmpty);

      terminal.key('q');
      await running;
    });

    test('reserves the action gate before keyboard and mouse connect actions',
        () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final connect = Completer<UiActionResult>();
      final port = _FakePort(
        UiSnapshot(devices: devices),
        pendingConnect: connect,
      );
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();
      final connectHit = shell.latestLayout!.hitRegions.firstWhere(
        (hit) => hit.action == UiHitAction.connect,
      );

      terminal.key('\r');
      terminal.key('c');
      terminal.click(connectHit.rect.left, connectHit.rect.top);
      await _pump();

      expect(port.connected, [devices.first.id]);
      expect(connect.isCompleted, isFalse);
      connect.complete(const UiActionResult.accepted());
      await _pump();
      terminal.key('q');
      await running;
    });

    test('active connection context cannot enqueue a second connect request',
        () async {
      final directed = UiDevice(
        name: '本次定向连接设备',
        macAddress: 'AA:BB:CC:DD:EE:10',
        support: UiDeviceSupport.supported,
        connected: true,
        isDirectedSessionTarget: true,
      );
      final terminal = _FakeTerminal(rows: 24, columns: 100);
      final port = _FakePort(UiSnapshot(
        devices: [directed],
        connectionPhase: UiConnectionPhase.ready,
        connectedDeviceId: directed.id,
      ));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      expect(
        shell.latestLayout!.visibleCommandActionNames,
        contains(UiHitAction.disconnect.name),
      );
      expect(
        shell.latestLayout!.visibleCommandActionNames,
        isNot(contains(UiHitAction.connect.name)),
      );
      expect(
        shell.latestLayout!.visibleCommandActionNames,
        isNot(contains(UiHitAction.directedConnect.name)),
      );
      expect(
        shell.latestLayout!.hitRegions.where(
          (hit) =>
              hit.isCommandAction &&
              (hit.action == UiHitAction.connect ||
                  hit.action == UiHitAction.directedConnect),
        ),
        isEmpty,
      );

      terminal.key('c');
      terminal.key('g');
      await _pump();
      expect(port.connected, isEmpty);
      expect(port.directedConnectCount, 0);

      terminal.key(String.fromCharCode(13));
      await _pump();
      expect(port.disconnectCount, 0);

      terminal.key('\x1b[B');
      await _pump();
      expect(shell.state.focus, UiFocusTarget.commandBar);
      expect(shell.state.focusedActionName, UiHitAction.disconnect.name);
      terminal.key(String.fromCharCode(13));
      await _pump();
      expect(port.disconnectCount, 1);

      terminal.key('q');
      await running;
    });

    test('uppercase L launches logs without touching the port lifecycle',
        () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(devices: devices));
      var launches = 0;
      final shell = UiNextShell(
        terminal: terminal,
        port: port,
        logViewerLauncher: () async => launches++,
      );
      final running = shell.run();
      await _pump();

      terminal.key('L');
      await _pump();
      expect(launches, 1);
      expect(port.disconnectCount, 0);
      expect(port.disposeCount, 0);
      expect(
        UiCellWidth.stripAnsi(shell.latestLayout!.text),
        contains('已在 macOS Terminal 打开诊断日志'),
      );

      terminal.key('q');
      await running;
      expect(port.disposeCount, 1);
    });

    test('Enter connects and d/Tab toggle details', () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(devices: devices));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      terminal.key('d');
      await _pump();
      expect(shell.state.detailOpen, isTrue);
      expect(UiCellWidth.stripAnsi(shell.latestLayout!.text),
          contains('[d/Tab/Esc] 返回设备列表'));

      terminal.key('\t');
      await _pump();
      expect(shell.state.detailOpen, isFalse);
      expect(UiCellWidth.stripAnsi(shell.latestLayout!.text),
          contains('[Enter/c]连接'));

      terminal.key('\r');
      await _pump();
      expect(port.connected, [devices.first.id]);
      terminal.key('q');
      await running;
    });

    test('authkey prompt locks target identity while selection input is open',
        () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(
        devices: devices,
        connectionPhase: UiConnectionPhase.awaitingAuthKey,
        pendingAuthDeviceId: devices.first.id,
        connectionGeneration: 1,
      ));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      expect(shell.state.modal, UiModal.authKey);
      expect(shell.state.modalTargetDeviceId, devices.first.id);
      terminal.key('\x1b[B');
      final firstHit = shell.latestLayout!.hitRegions.firstWhere(
        (hit) => hit.deviceId == devices[1].id,
      );
      terminal.click(firstHit.rect.left, firstHit.rect.top);
      await _pump();
      expect(shell.state.selectedDeviceId, devices.first.id);

      expect(
        shell.latestLayout!.hitRegions
            .where((hit) => hit.action == UiHitAction.connect),
        isEmpty,
      );
      expect(port.connected, isEmpty);

      terminal.key(List<String>.filled(6, 'x').join());
      terminal.key('\r');
      await _pump();
      expect(port.authKeySubmissions, [(devices.first.id, 6)]);
      expect(shell.state.modalTargetDeviceId, isNull);
      terminal.key('q');
      await running;
    });

    test('install modal keeps the opening device when snapshots replace it',
        () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(devices: devices));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      terminal.key('i');
      await _pump();
      expect(shell.state.modalTargetDeviceId, devices.first.id);
      terminal.key('/tmp/theme.rpk');
      port.emitSnapshot(UiSnapshot(devices: [devices[1]]));
      await _pump();
      expect(shell.state.selectedDeviceId, devices[1].id);
      expect(shell.state.modalTargetDeviceId, devices.first.id);

      terminal.key('\r');
      await _pump();
      expect(port.installs, [devices.first.id]);

      terminal.key('q');
      await running;
    });

    test(
        'activity records safe state summaries instead of snapshot diagnostics',
        () async {
      final terminal = _FakeTerminal(rows: 28, columns: 120);
      final port = _FakePort(UiSnapshot(devices: devices));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      port.emitSnapshot(UiSnapshot(
        devices: devices,
        scanning: true,
        connectionPhase: UiConnectionPhase.connecting,
        notice: 'secret-diagnostic-payload',
      ));
      await _pump();
      port.emitSnapshot(UiSnapshot(
        devices: devices,
        scanning: true,
        connectionPhase: UiConnectionPhase.ready,
        install: const UiInstallStatus(
          phase: UiInstallPhase.succeeded,
          message: 'secret-install-detail',
        ),
      ));
      await _pump();
      port.emitSnapshot(UiSnapshot(
        devices: devices,
        scanning: true,
        connectionPhase: UiConnectionPhase.ready,
        install: const UiInstallStatus(
          phase: UiInstallPhase.succeeded,
          successVerifiedByDeviceBusinessEvent: true,
          message: 'secret-install-detail',
        ),
      ));
      await _pump();

      final activity = shell.state.recentActivity
          .map((entry) => entry.category + ' ' + entry.message)
          .join('\n');
      expect(activity, contains('扫描 已开始'));
      expect(activity, contains('中'));
      expect(activity, contains('连接 Session READY'));
      expect(activity, contains('安装 等待设备安装结果'));
      expect(activity, contains('安装 设备确认安装成功'));
      expect(activity, isNot(contains('secret-diagnostic-payload')));
      expect(activity, isNot(contains('secret-install-detail')));
      expect(activity, isNot(contains('RFCOMM')));
      expect(activity, isNot(contains('f=26')));

      terminal.key('q');
      await running;
    });

    test('authkey submission immediately redraws without its modal', () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final pendingSubmission = Completer<UiActionResult>();
      final port = _FakePort(
        UiSnapshot(
          devices: devices,
          connectionPhase: UiConnectionPhase.awaitingAuthKey,
          pendingAuthDeviceId: devices.first.id,
          connectionGeneration: 1,
        ),
        pendingAuthKeySubmission: pendingSubmission,
      );
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      terminal.key('abc123');
      await _pump();
      final writesBeforeSubmit = terminal.writes.length;
      terminal.key('\r');
      await _pump();

      expect(shell.state.modal, isNull);
      expect(terminal.writes.length, greaterThan(writesBeforeSubmit));
      expect(port.authKeySubmissions, [(devices.first.id, 6)]);

      pendingSubmission.complete(const UiActionResult.accepted());
      await _pump();
      terminal.key('q');
      await running;
    });

    test('connection snapshots close only a generation-bound authkey modal',
        () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(
        devices: devices,
        connectionPhase: UiConnectionPhase.awaitingAuthKey,
        pendingAuthDeviceId: devices.first.id,
        connectionGeneration: 1,
      ));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      expect(shell.state.modal, UiModal.authKey);
      port.emitSnapshot(UiSnapshot(
        devices: devices,
        connectionPhase: UiConnectionPhase.connecting,
        connectionGeneration: 1,
      ));
      await _pump();
      expect(shell.state.modal, isNull);

      terminal.key('a');
      await _pump();
      expect(shell.state.modal, UiModal.authKey);
      expect(shell.state.modalTargetConnectionGeneration, isNull);
      port.emitSnapshot(UiSnapshot(
        devices: devices,
        connectionPhase: UiConnectionPhase.failed,
        connectionGeneration: 1,
      ));
      await _pump();
      expect(shell.state.modal, UiModal.authKey);

      // This is a manually opened prompt, so it intentionally remains open
      // after a connection snapshot. Close it before issuing the shell exit
      // key; otherwise `q` is valid authkey input and the test never exits.
      terminal.key('\x1b');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      terminal.key('q');
      await running;
    });

    test('authkey prompt cancellation dispatches only the cancellation intent',
        () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(
        devices: devices,
        connectionPhase: UiConnectionPhase.awaitingAuthKey,
        pendingAuthDeviceId: devices.first.id,
        connectionGeneration: 1,
      ));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      expect(shell.state.modal, UiModal.authKey);
      terminal.key('\x1b');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(shell.state.modal, isNull);
      expect(shell.state.modalTargetDeviceId, isNull);
      expect(port.disconnectCount, 0);
      expect(port.connected, isEmpty);
      terminal.key('q');
      await running;
    });

    test('authkey cancellation is scoped to the pending target and generation',
        () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(
        devices: devices,
        connectionPhase: UiConnectionPhase.awaitingAuthKey,
        pendingAuthDeviceId: devices.first.id,
        connectionGeneration: 1,
      ));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      expect(shell.state.modalTargetDeviceId, devices.first.id);
      terminal.key('\x1b');
      // A lone Escape is intentionally decoded after the terminal escape
      // sequence grace period.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(shell.state.modal, isNull);

      // The old active identity is deliberately retained: only the explicit
      // pending target may decide which device receives the authkey prompt.
      port.emitSnapshot(UiSnapshot(
        devices: devices,
        connectionPhase: UiConnectionPhase.awaitingAuthKey,
        connectedDeviceId: devices.first.id,
        pendingAuthDeviceId: devices[1].id,
        connectionGeneration: 2,
      ));
      await _pump();

      expect(shell.state.modal, UiModal.authKey);
      expect(shell.state.modalTargetDeviceId, devices[1].id);
      expect(shell.state.modalTargetConnectionGeneration, 2);
      terminal.key('\x1b');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      terminal.key('q');
      await running;
    });

    test('late snapshot cannot render after exit is requested', () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(
        UiSnapshot(devices: devices),
        synchronousSnapshots: true,
      );
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();
      final writesBeforeExit = terminal.writes.length;

      shell.requestExit();
      port.emitSnapshot(UiSnapshot(
        devices: devices,
        notice: 'this snapshot arrived after q',
      ));
      await running;

      expect(terminal.writes, hasLength(writesBeforeExit));
      expect(terminal.buffer.toString(), isNot(contains('after q')));
    });

    test('cancel runs while the install action remains pending', () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final install = Completer<UiActionResult>();
      final port = _FakePort(
        UiSnapshot(
          devices: devices,
          install: const UiInstallStatus(phase: UiInstallPhase.transferring),
        ),
        pendingInstall: install,
      );
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      terminal.key('i');
      terminal.key('/tmp/theme.bin');
      terminal.key('\r');
      await _pump();
      expect(port.installs, [devices.first.id]);
      expect(install.isCompleted, isFalse);

      terminal.key('z');
      await _pump();
      expect(port.cancelCount, 1);
      expect(install.isCompleted, isFalse);
      expect(shell.state.selectedDeviceId, devices.first.id);

      install.complete(const UiActionResult.accepted('安装完成'));
      await _pump();
      terminal.key('q');
      await running;
    });
  });
}

Future<void> _pump() => Future<void>.delayed(const Duration(milliseconds: 20));

class _FakePort implements UiNextPort {
  _FakePort(
    this._snapshot, {
    this.pendingInstall,
    this.pendingConnect,
    this.pendingAuthKeySubmission,
    this.initializeResult = const UiActionResult.accepted(),
    bool synchronousSnapshots = false,
  }) : _controller =
            StreamController<UiSnapshot>.broadcast(sync: synchronousSnapshots);

  UiSnapshot _snapshot;
  final StreamController<UiSnapshot> _controller;
  final List<String> connected = [];
  int directedConnectCount = 0;
  final List<String> installs = [];
  final List<(String, int)> authKeySubmissions = [];
  final Completer<UiActionResult>? pendingInstall;
  final Completer<UiActionResult>? pendingConnect;
  final Completer<UiActionResult>? pendingAuthKeySubmission;
  final UiActionResult initializeResult;
  final List<String> actions = [];
  int cancelCount = 0;
  int disconnectCount = 0;
  int disposeCount = 0;

  @override
  UiSnapshot get snapshot => _snapshot;
  @override
  Stream<UiSnapshot> get snapshots => _controller.stream;

  void emitSnapshot(UiSnapshot snapshot) {
    _snapshot = snapshot;
    _controller.add(snapshot);
  }

  Future<UiActionResult> _ok([String? message]) async =>
      UiActionResult.accepted(message);
  @override
  Future<UiActionResult> initialize() async {
    actions.add('initialize');
    return initializeResult;
  }

  @override
  Future<UiActionResult> scan() async {
    actions.add('scan');
    return _ok();
  }

  @override
  Future<UiActionResult> connect(String macAddress) async {
    connected.add(macAddress);
    final pending = pendingConnect;
    if (pending != null) return pending.future;
    return const UiActionResult.accepted();
  }

  @override
  Future<UiActionResult> connectDirectedExactAddress() {
    directedConnectCount++;
    return _ok();
  }

  @override
  Future<UiActionResult> disconnect() {
    disconnectCount++;
    return _ok();
  }

  @override
  Future<UiActionResult> installResource(String macAddress, String path) {
    installs.add(macAddress);
    return pendingInstall?.future ?? _ok();
  }

  @override
  Future<UiActionResult> cancelInstall() {
    cancelCount++;
    return _ok('已请求取消安装');
  }

  @override
  Future<UiActionResult> removeSavedDevice(String macAddress) => _ok();
  @override
  Future<UiActionResult> saveDevice(String macAddress) => _ok();
  @override
  Future<UiActionResult> setAutoConnect(bool enabled) => _ok();
  @override
  Future<UiActionResult> setThemeId(String themeId) => _ok();
  @override
  Future<void> dispose() async {
    disposeCount++;
  }

  @override
  Future<UiActionResult> submitAuthKey(
      String macAddress, String authKey) async {
    authKeySubmissions.add((macAddress, authKey.length));
    return pendingAuthKeySubmission?.future ?? _ok();
  }
}

class _FakeTerminal implements UiTerminal {
  _FakeTerminal({required this.rows, required this.columns});

  @override
  int rows;
  @override
  int columns;
  final StreamController<List<int>> _input =
      StreamController<List<int>>.broadcast();
  final StreamController<void> _resize = StreamController<void>.broadcast();
  final StringBuffer buffer = StringBuffer();
  final List<String> writes = [];
  bool mouseCapture = false;
  bool rawMode = false;
  bool altBuffer = false;
  bool cursorVisible = true;

  @override
  Stream<List<int>> get byteStream => _input.stream;
  @override
  Stream<void> get onResize => _resize.stream;
  @override
  bool get isInteractive => true;
  @override
  bool get supportsColor => false;
  @override
  void clearScreen() => buffer.clear();
  @override
  void flush() {}
  @override
  void moveHome() {}
  @override
  void reset() {}
  @override
  void setAltBuffer(bool enabled) => altBuffer = enabled;
  @override
  void setCursorVisible(bool visible) => cursorVisible = visible;
  @override
  void setMouseCapture(bool enabled) => mouseCapture = enabled;
  @override
  void setRawMode(bool enabled) => rawMode = enabled;
  @override
  void write(String text) {
    writes.add(text);
    buffer.write(text);
  }

  void key(String value) => _input.add(utf8.encode(value));
  void click(int column, int row) =>
      key('\x1b[<0;' + column.toString() + ';' + row.toString() + 'M');
  void scroll(int column, int row, {required bool down}) => key(
        '\x1b[<' +
            (down ? '65' : '64') +
            ';' +
            column.toString() +
            ';' +
            row.toString() +
            'M',
      );
  void resize(int nextRows, int nextColumns) {
    rows = nextRows;
    columns = nextColumns;
    _resize.add(null);
  }
}
