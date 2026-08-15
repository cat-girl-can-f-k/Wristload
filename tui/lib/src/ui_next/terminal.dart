import 'dart:async';

/// Terminal boundary owned by the replacement UI.
abstract interface class UiTerminal {
  int get rows;
  int get columns;
  bool get supportsColor;
  bool get isInteractive;
  Stream<void> get onResize;
  Stream<List<int>> get byteStream;

  void write(String text);
  void clearScreen();
  void moveHome();
  void setCursorVisible(bool visible);
  void setAltBuffer(bool enabled);
  void setRawMode(bool enabled);
  void setMouseCapture(bool enabled);
  void flush();
  void reset();
}
