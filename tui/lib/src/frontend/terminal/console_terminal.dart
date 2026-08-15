import 'dart:async';
import 'dart:io';

import 'package:console/console.dart';

import 'terminal.dart';

/// [Terminal] implementation backed by the `console` package and stdin/stdout.
class ConsoleTerminal implements Terminal {
  ConsoleTerminal() {
    _resizeSub = Console.onResize.listen((_) => _resizeController.add(null));
  }

  late final StreamSubscription<void> _resizeSub;
  final _resizeController = StreamController<void>.broadcast();
  bool _mouseCaptureEnabled = false;

  @override
  int get rows {
    try {
      return Console.rows;
    } on StdoutException {
      return 24;
    }
  }

  @override
  int get columns {
    try {
      return Console.columns;
    } on StdoutException {
      return 80;
    }
  }

  @override
  Stream<void> get onResize => _resizeController.stream;

  @override
  void write(String text) => Console.write(text);

  @override
  void writeLine(String text) => Console.adapter.writeln(text);

  @override
  void clearScreen() {
    Console.eraseDisplay(2);
    moveHome();
  }

  @override
  void moveHome() => Console.moveCursor(row: 1, column: 1);

  @override
  void setCursorVisible(bool visible) {
    try {
      if (visible) {
        Console.showCursor();
      } else {
        Console.hideCursor();
      }
    } on StdoutException {
      // stdout may already be closed during shutdown.
    }
  }

  @override
  void setAltBuffer(bool enabled) {
    try {
      if (enabled) {
        Console.altBuffer();
      } else {
        Console.normBuffer();
      }
    } on StdoutException {
      // stdout may already be closed during shutdown.
    }
  }

  @override
  void setRawMode(bool enabled) {
    try {
      stdin.echoMode = !enabled;
      stdin.lineMode = !enabled;
    } on StdinException {
      // stdin may already be closed (e.g. pipe EOF). Nothing to restore.
    }
  }

  @override
  void setMouseCapture(bool enabled) {
    if (_mouseCaptureEnabled == enabled) return;
    _mouseCaptureEnabled = enabled;
    try {
      // 1002 reports button motion, while 1006 makes coordinates unambiguous
      // decimal values (SGR: ESC [ < b ; x ; y M/m).
      Console.write(
          enabled ? '\x1b[?1002h\x1b[?1006h' : '\x1b[?1002l\x1b[?1006l');
    } on StdoutException {
      // stdout may already be closed during shutdown.
    }
  }

  @override
  Stream<List<int>> get byteStream => stdin;

  @override
  bool get supportsColor =>
      stdout.supportsAnsiEscapes && Platform.environment['NO_COLOR'] == null;

  @override
  bool get isInteractive => stdin.hasTerminal;

  @override
  void flush() {}

  @override
  void reset() {
    _resizeSub.cancel();
    _resizeController.close();
    try {
      setMouseCapture(false);
      Console.resetAll();
      setCursorVisible(true);
      setRawMode(false);
      setAltBuffer(false);
    } on StdinException {
      // stdin/stdout already closed; terminal state is irrelevant.
    }
  }
}
