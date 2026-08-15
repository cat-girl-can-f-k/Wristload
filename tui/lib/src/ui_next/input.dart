import 'dart:async';
import 'dart:convert';

sealed class UiInputEvent {
  const UiInputEvent();
}

class UiKeyPress extends UiInputEvent {
  const UiKeyPress(this.name, {this.raw = ''});

  final String name;
  final String raw;

  bool get isPrintable =>
      raw.isNotEmpty && raw.runes.every((rune) => rune >= 0x20 && rune != 0x7f);
}

class UiPasteEvent extends UiInputEvent {
  const UiPasteEvent(this.text);
  final String text;
}

enum UiMouseAction { press, release, move, scroll }

enum UiMouseButton { left, middle, right }

enum UiScrollDirection { up, down, left, right }

class UiMouseEvent extends UiInputEvent {
  const UiMouseEvent({
    required this.action,
    required this.column,
    required this.row,
    this.button,
    this.scrollDirection,
  });

  final UiMouseAction action;
  final int column;
  final int row;
  final UiMouseButton? button;
  final UiScrollDirection? scrollDirection;

  bool get isPress => action == UiMouseAction.press;
  bool get isScroll => action == UiMouseAction.scroll;
}

/// Incremental decoder for keyboard, UTF-8, bracketed paste and SGR mouse.
class UiInputDecoder {
  final StreamController<UiInputEvent> _events =
      StreamController<UiInputEvent>.broadcast();
  final List<int> _buffer = [];
  Timer? _escapeTimer;
  bool _closed = false;

  Stream<UiInputEvent> get events => _events.stream;

  void addBytes(List<int> bytes) {
    if (_closed) return;
    _buffer.addAll(bytes);
    if (_buffer.length > 1) _escapeTimer?.cancel();
    _drain();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _escapeTimer?.cancel();
    _events.close();
  }

  void _drain() {
    while (_buffer.isNotEmpty) {
      final consumed = _decodeOne();
      if (!consumed) return;
    }
  }

  bool _decodeOne() {
    if (_startsWith(_pasteStart)) {
      final end = _indexOf(_pasteEnd, _pasteStart.length);
      if (end < 0) return false;
      final bytes = _buffer.sublist(_pasteStart.length, end);
      _buffer.removeRange(0, end + _pasteEnd.length);
      _events.add(UiPasteEvent(utf8.decode(bytes, allowMalformed: true)));
      return true;
    }

    final first = _buffer.first;
    if (first == 0x1b) return _decodeEscape();
    if (first < 0x20 || first == 0x7f) {
      _buffer.removeAt(0);
      _events.add(
          UiKeyPress(_controlName(first), raw: String.fromCharCode(first)));
      return true;
    }

    final length = _utf8Length(first);
    if (_buffer.length < length) return false;
    final bytes = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    final value = utf8.decode(bytes, allowMalformed: true);
    _events.add(UiKeyPress(value, raw: value));
    return true;
  }

  bool _decodeEscape() {
    if (_buffer.length == 1) {
      _scheduleBareEscape();
      return false;
    }
    if (_buffer[1] != 0x5b) {
      _buffer.removeAt(0);
      _events.add(const UiKeyPress('esc', raw: '\x1b'));
      return true;
    }
    var end = 2;
    while (end < _buffer.length &&
        !(_buffer[end] >= 0x40 && _buffer[end] <= 0x7e)) {
      end++;
    }
    if (end >= _buffer.length) return false;
    final params = ascii.decode(_buffer.sublist(2, end), allowInvalid: true);
    final finalByte = _buffer[end];
    _buffer.removeRange(0, end + 1);
    final mouse = _decodeMouse(params, finalByte);
    if (mouse != null) {
      _events.add(mouse);
      return true;
    }
    final finalChar = String.fromCharCode(finalByte);
    final name = switch (finalChar) {
      'A' => 'up',
      'B' => 'down',
      'C' => 'right',
      'D' => 'left',
      'H' => 'home',
      'F' => 'end',
      '~' when params == '3' => 'delete',
      '~' when params == '5' => 'page-up',
      '~' when params == '6' => 'page-down',
      _ => 'csi-$params$finalChar',
    };
    _events.add(UiKeyPress(name, raw: '\x1b[$params$finalChar'));
    return true;
  }

  void _scheduleBareEscape() {
    if (_escapeTimer != null || _closed) return;
    _escapeTimer = Timer(const Duration(milliseconds: 35), () {
      _escapeTimer = null;
      if (_closed || _buffer.isEmpty || _buffer.first != 0x1b) return;
      _buffer.removeAt(0);
      _events.add(const UiKeyPress('esc', raw: '\x1b'));
      _drain();
    });
  }

  UiMouseEvent? _decodeMouse(String params, int finalByte) {
    if (!params.startsWith('<') || (finalByte != 0x4d && finalByte != 0x6d)) {
      return null;
    }
    final fields = params.substring(1).split(';').map(int.tryParse).toList();
    if (fields.length != 3 || fields.any((value) => value == null)) return null;
    final code = fields[0]!;
    final column = fields[1]!;
    final row = fields[2]!;
    if (column < 1 || row < 1) return null;
    final base = code & 3;
    if ((code & 64) != 0) {
      return UiMouseEvent(
        action: UiMouseAction.scroll,
        column: column,
        row: row,
        scrollDirection: switch (base) {
          0 => UiScrollDirection.up,
          1 => UiScrollDirection.down,
          2 => UiScrollDirection.left,
          _ => UiScrollDirection.right,
        },
      );
    }
    return UiMouseEvent(
      action: finalByte == 0x6d || base == 3
          ? UiMouseAction.release
          : (code & 32) != 0
              ? UiMouseAction.move
              : UiMouseAction.press,
      column: column,
      row: row,
      button: switch (base) {
        0 => UiMouseButton.left,
        1 => UiMouseButton.middle,
        2 => UiMouseButton.right,
        _ => null,
      },
    );
  }

  String _controlName(int byte) => switch (byte) {
        0x03 => 'ctrl-c',
        0x08 || 0x7f => 'backspace',
        0x09 => 'tab',
        0x0a || 0x0d => 'enter',
        _ => 'control-$byte',
      };

  int _utf8Length(int first) {
    if (first < 0x80) return 1;
    if ((first & 0xe0) == 0xc0) return 2;
    if ((first & 0xf0) == 0xe0) return 3;
    if ((first & 0xf8) == 0xf0) return 4;
    return 1;
  }

  bool _startsWith(List<int> value) {
    if (_buffer.length < value.length) return false;
    for (var index = 0; index < value.length; index++) {
      if (_buffer[index] != value[index]) return false;
    }
    return true;
  }

  int _indexOf(List<int> needle, int start) {
    for (var offset = start;
        offset <= _buffer.length - needle.length;
        offset++) {
      var matches = true;
      for (var index = 0; index < needle.length; index++) {
        if (_buffer[offset + index] != needle[index]) {
          matches = false;
          break;
        }
      }
      if (matches) return offset;
    }
    return -1;
  }

  static const _pasteStart = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e];
  static const _pasteEnd = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e];
}
