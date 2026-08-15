import 'dart:async';

/// Abstract terminal used by the TUI. Production implementations drive stdin /
/// stdout; fake implementations capture output for tests.
abstract class Terminal {
  int get rows;
  int get columns;

  /// Emitted whenever the terminal size changes.
  Stream<void> get onResize;

  /// Write raw text to the terminal.
  void write(String text);

  /// Write a line of text and move to the next row.
  void writeLine(String text);

  /// Clear the entire screen.
  void clearScreen();

  /// Move cursor to the top-left corner.
  void moveHome();

  /// Show or hide the cursor.
  void setCursorVisible(bool visible);

  /// Enter or leave the alternate screen buffer.
  void setAltBuffer(bool enabled);

  /// Switch raw / canonical input mode. In raw mode individual key events are
  /// delivered through [keyStream]; in canonical mode lines are delivered.
  void setRawMode(bool enabled);

  /// Enable or disable SGR mouse capture.
  ///
  /// Implementations emit mouse reports through [byteStream] so that the
  /// input decoder can order mouse and keyboard events from one source.
  /// Callers must disable capture before terminal shutdown. [reset] also
  /// restores this mode as a final safety net.
  void setMouseCapture(bool enabled);

  /// Stream of raw byte chunks from stdin.
  Stream<List<int>> get byteStream;

  /// Restore the terminal to a sane state. Called exactly once during shutdown.
  void reset();

  /// True if the terminal claims color support and NO_COLOR is not set.
  bool get supportsColor;

  /// Flush any buffered output.
  void flush();

  /// True if this terminal is connected to an interactive input device.
  /// Non-interactive terminals (pipes, files) cannot run the TUI safely.
  bool get isInteractive;
}
