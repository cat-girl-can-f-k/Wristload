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
  });

  group('UiNextShell', () {
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

    test('authkey prompt cancellation dispatches only the cancellation intent',
        () async {
      final terminal = _FakeTerminal(rows: 24, columns: 80);
      final port = _FakePort(UiSnapshot(
        devices: devices,
        connectionPhase: UiConnectionPhase.awaitingAuthKey,
        connectedDeviceId: devices.first.id,
      ));
      final shell = UiNextShell(terminal: terminal, port: port);
      final running = shell.run();
      await _pump();

      expect(shell.state.modal, UiModal.authKey);
      terminal.key('\x1b');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(shell.state.modal, isNull);
      expect(port.disconnectCount, 0);
      expect(port.connected, isEmpty);
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
    bool synchronousSnapshots = false,
  }) : _controller =
            StreamController<UiSnapshot>.broadcast(sync: synchronousSnapshots);

  final UiSnapshot _snapshot;
  final StreamController<UiSnapshot> _controller;
  final List<String> connected = [];
  final List<String> installs = [];
  final Completer<UiActionResult>? pendingInstall;
  int cancelCount = 0;
  int disconnectCount = 0;

  @override
  UiSnapshot get snapshot => _snapshot;
  @override
  Stream<UiSnapshot> get snapshots => _controller.stream;

  void emitSnapshot(UiSnapshot snapshot) => _controller.add(snapshot);

  Future<UiActionResult> _ok([String? message]) async =>
      UiActionResult.accepted(message);
  @override
  Future<UiActionResult> initialize() => _ok();
  @override
  Future<UiActionResult> scan() => _ok();
  @override
  Future<UiActionResult> connect(String macAddress) async {
    connected.add(macAddress);
    return const UiActionResult.accepted();
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
  Future<void> dispose() async {}
  @override
  Future<UiActionResult> submitAuthKey(String macAddress, String authKey) =>
      _ok();
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
