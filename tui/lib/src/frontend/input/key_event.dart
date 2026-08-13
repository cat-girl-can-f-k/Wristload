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

/// Terminal resize event.
class ResizeEvent extends KeyEvent {
  const ResizeEvent(this.rows, this.columns);

  final int rows;
  final int columns;
}
