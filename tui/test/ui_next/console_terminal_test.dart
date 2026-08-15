import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wristload_tui/src/ui_next/console_terminal.dart';

void main() {
  group('UiConsoleTerminal', () {
    test('uses TTY capabilities and sensible non-terminal dimensions', () {
      final bindings = _FakeBindings(rows: 0, columns: -1);
      final terminal = UiConsoleTerminal(bindings: bindings);

      expect(terminal.rows, 24);
      expect(terminal.columns, 80);
      expect(terminal.isInteractive, isTrue);
      expect(
        terminal.supportsColor,
        bindings.supportsAnsiEscapes &&
            Platform.environment['NO_COLOR'] == null,
      );
      terminal.reset();
    });

    test('emits alternate buffer, cursor, raw input, and SGR mouse controls',
        () {
      final bindings = _FakeBindings();
      final terminal = UiConsoleTerminal(bindings: bindings);

      terminal.setAltBuffer(true);
      terminal.setCursorVisible(false);
      terminal.setRawMode(true);
      terminal.setMouseCapture(true);
      terminal.clearScreen();
      terminal.moveHome();
      terminal.flush();

      expect(
        bindings.writes.join(),
        '\x1b[?1049h'
        '\x1b[?25l'
        '\x1b[?1002h\x1b[?1006h\x1b[?2004h'
        '\x1b[2J\x1b[H'
        '\x1b[H',
      );
      expect(bindings.rawModeChanges, [true]);
      expect(bindings.flushCalls, 1);
      terminal.reset();
    });

    test(
        'forwards resize notifications until reset and restores terminal modes',
        () async {
      final bindings = _FakeBindings();
      final terminal = UiConsoleTerminal(bindings: bindings);
      final resized = <void>[];
      final subscription = terminal.onResize.listen(resized.add);

      bindings.emitResize();
      await _pump();
      expect(resized, hasLength(1));

      terminal.setRawMode(true);
      terminal.setMouseCapture(true);
      terminal.setAltBuffer(true);
      terminal.setCursorVisible(false);
      terminal.reset();
      bindings.emitResize();
      await _pump();

      expect(resized, hasLength(1));
      expect(bindings.rawModeChanges, [true, false]);
      expect(
        bindings.writes.last,
        '\x1b[?1002l\x1b[?1006l\x1b[?2004l\x1b[0m\x1b[?25h\x1b[?1049l',
      );
      await subscription.cancel();
    });

    test('mode requests are idempotent and reset is safe to repeat', () {
      final bindings = _FakeBindings();
      final terminal = UiConsoleTerminal(bindings: bindings);

      terminal.setMouseCapture(true);
      terminal.setMouseCapture(true);
      terminal.setRawMode(true);
      terminal.setRawMode(true);
      terminal.reset();
      terminal.reset();

      expect(bindings.rawModeChanges, [true, false]);
      expect(
        bindings.writes.where((text) => text.contains('\x1b[?1002h')).length,
        1,
      );
      expect(
        bindings.writes.where((text) => text.contains('\x1b[?1002l')).length,
        1,
      );
    });

    test('queues writes until an in-flight flush releases stdout', () async {
      final bindings = _FakeBindings(
        blockFlush: true,
        rejectWritesWhileFlushing: true,
      );
      final terminal = UiConsoleTerminal(bindings: bindings);

      terminal.write('first');
      terminal.flush();
      terminal.moveHome();
      terminal.write('second');
      terminal.flush();

      expect(bindings.writes, ['first']);
      expect(bindings.flushCalls, 1);
      expect(bindings.writeAttemptsWhileFlushActive, 0);

      bindings.completeFlush();
      await _pump();
      await _pump();

      expect(bindings.writes, ['first', '\x1b[Hsecond']);
      expect(bindings.flushCalls, 2);
      expect(bindings.writeAttemptsWhileFlushActive, 0);
      terminal.reset();
    });
  });
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

class _FakeBindings implements UiConsoleBindings {
  _FakeBindings({
    this.rows = 24,
    this.columns = 80,
    this.blockFlush = false,
    this.rejectWritesWhileFlushing = false,
  });

  @override
  int rows;
  @override
  int columns;
  @override
  bool hasTerminal = true;
  @override
  bool supportsAnsiEscapes = true;
  final bool blockFlush;
  final bool rejectWritesWhileFlushing;
  final Completer<void> _flushGate = Completer<void>();
  bool _flushActive = false;
  final StreamController<List<int>> _input =
      StreamController<List<int>>.broadcast();
  final StreamController<void> _resize = StreamController<void>.broadcast();
  final List<String> writes = [];
  final List<bool> rawModeChanges = [];
  int flushCalls = 0;
  int writeAttemptsWhileFlushActive = 0;

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  Stream<void> get resize => _resize.stream;

  @override
  Future<void> flush() {
    flushCalls++;
    if (!blockFlush) return Future<void>.value();
    _flushActive = true;
    return _flushGate.future.whenComplete(() => _flushActive = false);
  }

  @override
  void setRawMode(bool enabled) {
    rawModeChanges.add(enabled);
  }

  @override
  void write(String text) {
    if (rejectWritesWhileFlushing && _flushActive) {
      writeAttemptsWhileFlushActive++;
      throw StateError('StreamSink is bound to a stream');
    }
    writes.add(text);
  }

  void emitResize() => _resize.add(null);

  void completeFlush() {
    if (!_flushGate.isCompleted) _flushGate.complete();
  }
}
