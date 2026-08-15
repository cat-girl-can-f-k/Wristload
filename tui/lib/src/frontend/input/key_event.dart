/// A decoded terminal input event.
sealed class KeyEvent {
  const KeyEvent();
}

/// A single logical key press such as an arrow key, letter, or Enter.
class KeyPress extends KeyEvent {
  const KeyPress(this.name, {this.raw = '', this.isPaste = false});

  /// Logical name such as `up`, `down`, `enter`, `esc`, `a`, `?`.
  final String name;

  /// Raw character sequence (may be empty for special keys).
  final String raw;

  /// True if this key came from a bracketed-paste chunk.
  final bool isPaste;

  bool get isPrintable => raw.isNotEmpty && !isControl;

  bool get isControl {
    if (raw.isEmpty) return true;
    final code = raw.codeUnitAt(0);
    return code < 0x20 || code == 0x7f;
  }
}

/// A chunk of pasted text delivered by bracketed paste mode.
class PasteEvent extends KeyEvent {
  const PasteEvent(this.text);

  final String text;
}

/// A decoded SGR mouse event. Coordinates use the terminal's one-based grid.
class MouseEvent extends KeyEvent {
  const MouseEvent({
    required this.action,
    required this.column,
    required this.row,
    required this.rawButtonCode,
    this.button,
    this.scrollDirection,
    this.shift = false,
    this.alt = false,
    this.control = false,
  });

  final MouseAction action;
  final int column;
  final int row;

  /// Original SGR button/modifier field for diagnostics and future mapping.
  final int rawButtonCode;
  final MouseButton? button;
  final MouseScrollDirection? scrollDirection;
  final bool shift;
  final bool alt;
  final bool control;

  bool get isPress => action == MouseAction.press;
  bool get isRelease => action == MouseAction.release;
  bool get isScroll => action == MouseAction.scroll;
}

enum MouseAction { press, release, move, scroll }

enum MouseButton { left, middle, right }

enum MouseScrollDirection { up, down, left, right }

/// Terminal resize event.
class ResizeEvent extends KeyEvent {
  const ResizeEvent(this.rows, this.columns);

  final int rows;
  final int columns;
}
