import 'dart:async';
import 'dart:io';

import 'terminal.dart';

/// Operating-system boundary used by [UiConsoleTerminal].
///
/// Keeping this small makes the production terminal usable from macOS while
/// allowing lifecycle and escape-sequence behavior to be tested without a real
/// TTY. It deliberately belongs to `ui_next` and has no dependency on the
/// replaceable legacy terminal implementation.
abstract interface class UiConsoleBindings {
  int get rows;
  int get columns;
  bool get supportsAnsiEscapes;
  bool get hasTerminal;
  Stream<List<int>> get input;
  Stream<void> get resize;

  void write(String text);
  Future<void> flush();
  void setRawMode(bool enabled);
}

/// Production [UiConsoleBindings] backed directly by Dart's terminal APIs.
class DartUiConsoleBindings implements UiConsoleBindings {
  DartUiConsoleBindings() : _resize = _watchResize();

  final Stream<void> _resize;

  @override
  int get rows {
    try {
      return stdout.terminalLines;
    } on StdoutException {
      return 0;
    }
  }

  @override
  int get columns {
    try {
      return stdout.terminalColumns;
    } on StdoutException {
      return 0;
    }
  }

  @override
  bool get supportsAnsiEscapes => stdout.supportsAnsiEscapes;

  @override
  bool get hasTerminal => stdin.hasTerminal && stdout.hasTerminal;

  @override
  Stream<List<int>> get input => stdin;

  @override
  Stream<void> get resize => _resize;

  @override
  Future<void> flush() => stdout.flush();

  @override
  void setRawMode(bool enabled) {
    stdin.echoMode = !enabled;
    stdin.lineMode = !enabled;
  }

  @override
  void write(String text) => stdout.write(text);

  static Stream<void> _watchResize() {
    if (!(Platform.isMacOS || Platform.isLinux)) return const Stream.empty();
    try {
      return ProcessSignal.sigwinch.watch().map<void>((_) {});
    } on UnsupportedError {
      return const Stream.empty();
    }
  }
}

/// Standalone production terminal for the replacement TUI.
///
/// The instance owns only its resize subscription. [reset] restores the
/// terminal modes it changed but intentionally never closes process stdin or
/// stdout, because those streams are owned by the host process.
class UiConsoleTerminal implements UiTerminal {
  UiConsoleTerminal({UiConsoleBindings? bindings})
      : _bindings = bindings ?? DartUiConsoleBindings() {
    _resizeSubscription = _bindings.resize.listen(
      (_) {
        if (!_reset) _resizeController.add(null);
      },
      onError: (_, __) {
        // A resize notification is an optional terminal enhancement.
      },
    );
  }

  final UiConsoleBindings _bindings;
  final StreamController<void> _resizeController =
      StreamController<void>.broadcast();
  late final StreamSubscription<void> _resizeSubscription;

  bool _rawMode = false;
  bool _altBuffer = false;
  bool _cursorVisible = true;
  bool _mouseCapture = false;
  bool _reset = false;

  // stdout.flush() temporarily binds the underlying sink. A later synchronous
  // write during that window throws `Bad state: StreamSink is bound to a
  // stream`, so output written after a flush is held until it completes.
  Future<void>? _flushInFlight;
  final StringBuffer _deferredOutput = StringBuffer();
  bool _flushRequested = false;

  @override
  int get rows => _positiveOr(_bindings.rows, 24);

  @override
  int get columns => _positiveOr(_bindings.columns, 80);

  @override
  bool get supportsColor =>
      _bindings.supportsAnsiEscapes && Platform.environment['NO_COLOR'] == null;

  @override
  bool get isInteractive => _bindings.hasTerminal;

  @override
  Stream<List<int>> get byteStream => _bindings.input;

  @override
  Stream<void> get onResize => _resizeController.stream;

  @override
  void clearScreen() {
    _write('\x1b[2J\x1b[H');
  }

  @override
  void flush() {
    _flushRequested = true;
    if (_flushInFlight == null) _startFlush();
  }

  @override
  void moveHome() {
    _write('\x1b[H');
  }

  @override
  void reset() {
    if (_reset) return;
    _reset = true;
    _ignore(_resizeSubscription.cancel());
    _ignore(_resizeController.close());

    // Queue cleanup controls through the same serialized output path so a
    // prior flush cannot leave the host terminal in raw mode, alternate-buffer
    // mode, or mouse capture.
    _write('\x1b[?1002l\x1b[?1006l\x1b[?2004l\x1b[0m\x1b[?25h\x1b[?1049l');
    _mouseCapture = false;
    _cursorVisible = true;
    _altBuffer = false;
    if (_rawMode) {
      _setRawMode(false);
      _rawMode = false;
    }
    flush();
  }

  @override
  void setAltBuffer(bool enabled) {
    if (_reset || _altBuffer == enabled) return;
    _write(enabled ? '\x1b[?1049h' : '\x1b[?1049l');
    _altBuffer = enabled;
  }

  @override
  void setCursorVisible(bool visible) {
    if (_reset || _cursorVisible == visible) return;
    _write(visible ? '\x1b[?25h' : '\x1b[?25l');
    _cursorVisible = visible;
  }

  @override
  void setMouseCapture(bool enabled) {
    if (_reset || _mouseCapture == enabled) return;
    // 1002 enables button motion; 1006 selects unambiguous SGR coordinates.
    // Bracketed paste is enabled alongside it for UiInputDecoder.
    _write(enabled
        ? '\x1b[?1002h\x1b[?1006h\x1b[?2004h'
        : '\x1b[?1002l\x1b[?1006l\x1b[?2004l');
    _mouseCapture = enabled;
  }

  @override
  void setRawMode(bool enabled) {
    if (_reset || _rawMode == enabled) return;
    _setRawMode(enabled);
    _rawMode = enabled;
  }

  @override
  void write(String text) {
    _write(text);
  }

  int _positiveOr(int value, int fallback) => value > 0 ? value : fallback;

  void _setRawMode(bool enabled) {
    try {
      _bindings.setRawMode(enabled);
    } on StdinException {
      // Piped/closed stdin is not recoverable and must not break shutdown.
    } on FileSystemException {
      // The terminal can disappear while an application is shutting down.
    }
  }

  void _write(String text) {
    if (text.isEmpty) return;
    if (_flushInFlight != null) {
      _deferredOutput.write(text);
      return;
    }
    _writeImmediately(text);
  }

  void _writeImmediately(String text) {
    try {
      _bindings.write(text);
    } on StdoutException {
      // stdout can be closed during process teardown.
    } on FileSystemException {
      // stdout can be detached from a GUI-launched process.
    } on StateError {
      // Dart's IOSink can reject writes while host process teardown owns it.
      // This is best-effort terminal cleanup, never an application failure.
    }
  }

  void _startFlush() {
    if (_flushInFlight != null) return;
    _flushRequested = false;
    late final Future<void> tracked;
    tracked = _flushBindings().whenComplete(() {
      if (!identical(_flushInFlight, tracked)) return;
      _flushInFlight = null;

      final deferred = _deferredOutput.toString();
      _deferredOutput.clear();
      final needsAnotherFlush = _flushRequested || deferred.isNotEmpty;
      _flushRequested = false;
      if (deferred.isNotEmpty) _writeImmediately(deferred);
      if (needsAnotherFlush) _startFlush();
    });
    _flushInFlight = tracked;
  }

  Future<void> _flushBindings() async {
    try {
      await _bindings.flush();
    } on StdoutException {
      // stdout can be closed during process teardown.
    } on FileSystemException {
      // stdout can be detached from a GUI-launched process.
    } on StateError {
      // IOSink may reject a flush while the host is closing stdout.
    }
  }

  void _ignore(Future<void> operation) {
    unawaited(operation.catchError((_) {}));
  }
}
