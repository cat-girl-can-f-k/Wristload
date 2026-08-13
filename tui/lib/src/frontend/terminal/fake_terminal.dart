import 'dart:async';
import 'dart:convert';

import 'terminal.dart';

/// A fake [Terminal] that records all output and is driven by a controller for
/// input and resize events. Useful for rendering and keyboard tests.
class FakeTerminal implements Terminal {
  FakeTerminal({
    this.rows = 24,
    this.columns = 80,
    this.supportsColor = false,
    this.interactive = true,
  });

  @override
  int rows;
  @override
  int columns;
  @override
  final bool supportsColor;

  /// Whether the fake terminal pretends to be interactive.
  final bool interactive;

  final StringBuffer _buffer = StringBuffer();
  final StreamController<List<int>> _inputController =
      StreamController<List<int>>.broadcast();
  final StreamController<void> _resizeController =
      StreamController<void>.broadcast();

  bool _rawMode = false;
  bool _altBuffer = false;
  bool _cursorVisible = true;
  bool _disposed = false;

  @override
  Stream<void> get onResize => _resizeController.stream;

  @override
  bool get isInteractive => interactive;

  @override
  void write(String text) {
    if (_disposed) return;
    _buffer.write(text);
  }

  @override
  void writeLine(String text) {
    if (_disposed) return;
    _buffer.writeln(text);
  }

  @override
  void clearScreen() {
    _buffer.clear();
  }

  @override
  void moveHome() {}

  @override
  void setCursorVisible(bool visible) => _cursorVisible = visible;

  @override
  void setAltBuffer(bool enabled) => _altBuffer = enabled;

  @override
  void setRawMode(bool enabled) => _rawMode = enabled;

  @override
  Stream<List<int>> get byteStream => _inputController.stream;

  @override
  void flush() {}

  @override
  void reset() {
    if (_disposed) return;
    _disposed = true;
    _rawMode = false;
    _altBuffer = false;
    _cursorVisible = true;
    _inputController.close();
    _resizeController.close();
  }

  /// Simulate a user typing literal text. Bracketed paste is emulated by
  /// wrapping the text so the key decoder treats it as a single paste event.
  void type(String text) {
    _inputController.add(utf8.encode(text));
  }

  /// Simulate a single key by its escape sequence or character.
  void key(String sequence) {
    _inputController.add(utf8.encode(sequence));
  }

  /// Simulate a terminal resize.
  void resize(int newRows, int newColumns) {
    rows = newRows;
    columns = newColumns;
    _resizeController.add(null);
  }

  /// The full rendered output so far.
  String get buffer => _buffer.toString();

  /// Lines of rendered output (split on newlines).
  List<String> get lines => LineSplitter.split(buffer).toList();

  bool get rawMode => _rawMode;
  bool get altBuffer => _altBuffer;
  bool get cursorVisible => _cursorVisible;

  /// Whether [dispose]/[reset] has been called.
  bool get disposed => _disposed;
}
