import 'dart:async';
import 'dart:convert';

import 'key_event.dart';

/// Decodes a raw byte stream into logical [KeyEvent]s.
///
/// Handles:
/// - ASCII control characters (Enter, Tab, Backspace, Escape)
/// - ANSI escape sequences (arrows, Home, End, F1-F12, etc.)
/// - Bracketed paste events (ESC [ 200 ~ ... ESC [ 201 ~)
class KeyDecoder {
  KeyDecoder({
    this.escapeSequenceTimeout = const Duration(milliseconds: 35),
  });

  /// How long to wait for bytes that might complete an ANSI escape sequence.
  ///
  /// A terminal sends both a standalone Escape and the prefix of CSI/SS3
  /// sequences as `0x1b`. A short idle timeout lets the former remain usable
  /// without treating a sequence split across input chunks as Escape.
  final Duration escapeSequenceTimeout;

  final _controller = StreamController<KeyEvent>.broadcast();
  final _buffer = <int>[];
  bool _inPaste = false;
  final _pasteBuffer = StringBuffer();
  Timer? _escapeTimer;
  bool _closed = false;

  Stream<KeyEvent> get events => _controller.stream;

  void addBytes(List<int> bytes) {
    _cancelEscapeTimer();
    _buffer.addAll(bytes);
    _drain();
  }

  void close() {
    if (_closed) return;
    _cancelEscapeTimer();
    _flushIncompleteEscapeSequence();
    _closed = true;
    _controller.close();
  }

  void _drain() {
    while (_buffer.isNotEmpty) {
      final event = _decodeNext();
      if (event == null) break;
      _controller.add(event);
    }
  }

  KeyEvent? _decodeNext() {
    if (_buffer.isEmpty) return null;

    // Bracketed paste start: ESC [ 200 ~
    if (_startsWith([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])) {
      _inPaste = true;
      _pasteBuffer.clear();
      _buffer.removeRange(0, 6);
      return _decodeNext(); // continue parsing inside paste
    }

    // Bracketed paste end: ESC [ 201 ~
    if (_inPaste && _startsWith([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])) {
      _inPaste = false;
      _buffer.removeRange(0, 6);
      final text = _pasteBuffer.toString();
      _pasteBuffer.clear();
      return PasteEvent(text);
    }

    if (_inPaste) {
      // Keep a possible, but incomplete, paste terminator in the byte buffer
      // until the next chunk arrives. If it diverges from the terminator, the
      // bytes are ordinary pasted text and are consumed below.
      if (_isPrefixOf([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])) {
        return null;
      }
      final byte = _buffer.removeAt(0);
      if (byte < 0x80) {
        _pasteBuffer.writeCharCode(byte);
      } else {
        // Multi-byte UTF-8: collect full rune.
        _buffer.insert(0, byte);
        final rune = _takeRune();
        if (rune == null) return null;
        _pasteBuffer.writeCharCode(rune);
      }
      return _decodeNext();
    }

    final first = _buffer.first;

    // ESC sequence
    if (first == 0x1b) {
      if (_buffer.length == 1) {
        _scheduleEscapeFallback();
        return null;
      }
      if (_buffer[1] == 0x5b) {
        final event = _decodeCsi();
        if (event == null) _scheduleEscapeFallback();
        return event;
      }
      if (_buffer[1] == 0x4f) {
        final event = _decodeSs3();
        if (event == null) _scheduleEscapeFallback();
        return event;
      }
      // ESC not followed by '[' is treated as a standalone Esc; the following
      // byte (if any) remains in the buffer for the next decode iteration.
      _buffer.removeAt(0);
      return const KeyPress('esc', raw: '\x1b');
    }

    // Single-byte control characters
    if (first < 0x20 || first == 0x7f) {
      _buffer.removeAt(0);
      return _controlKey(first);
    }

    // Multi-byte UTF-8 character or printable ASCII
    final rune = _takeRune();
    if (rune == null) return null;
    final char = String.fromCharCode(rune);
    return KeyPress(char, raw: char);
  }

  KeyEvent? _decodeCsi() {
    // Find the end of the CSI sequence (0x40-0x7e final byte).
    var end = 2;
    while (end < _buffer.length) {
      final b = _buffer[end];
      if (b >= 0x40 && b <= 0x7e) break;
      end++;
    }
    if (end >= _buffer.length) return null; // incomplete

    final params = utf8.decode(_buffer.sublist(2, end));
    final finalByte = _buffer[end];
    _buffer.removeRange(0, end + 1);

    final name = _csiName(params, finalByte);
    return KeyPress(name,
        raw: '\x1b[${params}${String.fromCharCode(finalByte)}');
  }

  KeyEvent? _decodeSs3() {
    if (_buffer.length < 3) return null;

    final finalByte = _buffer[2];
    _buffer.removeRange(0, 3);
    final name = switch (finalByte) {
      0x41 => 'up',
      0x42 => 'down',
      0x43 => 'right',
      0x44 => 'left',
      0x48 => 'home',
      0x46 => 'end',
      0x50 => 'f1',
      0x51 => 'f2',
      0x52 => 'f3',
      0x53 => 'f4',
      _ => 'ss3-${String.fromCharCode(finalByte)}',
    };
    return KeyPress(name, raw: '\x1bO${String.fromCharCode(finalByte)}');
  }

  void _scheduleEscapeFallback() {
    if (_escapeTimer != null || _closed) return;
    _escapeTimer = Timer(escapeSequenceTimeout, () {
      _escapeTimer = null;
      if (_closed || _buffer.isEmpty || _buffer.first != 0x1b) return;

      // The sequence stayed incomplete. Preserve every following byte so it
      // can be decoded normally instead of being lost with the Escape prefix.
      _buffer.removeAt(0);
      _controller.add(const KeyPress('esc', raw: '\x1b'));
      _drain();
    });
  }

  void _cancelEscapeTimer() {
    _escapeTimer?.cancel();
    _escapeTimer = null;
  }

  void _flushIncompleteEscapeSequence() {
    if (_buffer.isEmpty || _buffer.first != 0x1b || _inPaste) return;

    _buffer.removeAt(0);
    _controller.add(const KeyPress('esc', raw: '\x1b'));
    _drain();
  }

  String _csiName(String params, int finalByte) {
    final fb = String.fromCharCode(finalByte);
    if (fb == 'A') return 'up';
    if (fb == 'B') return 'down';
    if (fb == 'C') return 'right';
    if (fb == 'D') return 'left';
    if (fb == 'H') return 'home';
    if (fb == 'F') return 'end';
    if (fb == 'Z') return 'shift-tab';
    if (fb == '~') {
      switch (params) {
        case '2':
          return 'insert';
        case '3':
          return 'delete';
        case '5':
          return 'page-up';
        case '6':
          return 'page-down';
        case '11':
        case '1;1':
          return 'f1';
        case '12':
        case '1;2':
          return 'f2';
        case '13':
        case '1;3':
          return 'f3';
        case '14':
        case '1;4':
          return 'f4';
        case '15':
        case '1;5':
          return 'f5';
        case '17':
        case '1;6':
          return 'f6';
        case '18':
        case '1;7':
          return 'f7';
        case '19':
        case '1;8':
          return 'f8';
        case '20':
        case '1;9':
          return 'f9';
        case '21':
        case '1;10':
          return 'f10';
        case '23':
        case '1;11':
          return 'f11';
        case '24':
        case '1;12':
          return 'f12';
      }
    }
    return 'csi-${params}${fb}';
  }

  KeyPress _controlKey(int byte) {
    switch (byte) {
      case 0x00:
        return const KeyPress('ctrl-space', raw: '\x00');
      case 0x01:
        return const KeyPress('ctrl-a', raw: '\x01');
      case 0x03:
        return const KeyPress('ctrl-c', raw: '\x03');
      case 0x04:
        return const KeyPress('ctrl-d', raw: '\x04');
      case 0x05:
        return const KeyPress('ctrl-e', raw: '\x05');
      case 0x09:
        return const KeyPress('tab', raw: '\t');
      case 0x0a:
      case 0x0d:
        return const KeyPress('enter', raw: '\n');
      case 0x1b:
        return const KeyPress('esc', raw: '\x1b');
      case 0x7f:
        return const KeyPress('backspace', raw: '\x7f');
      default:
        return KeyPress('ctrl-${String.fromCharCode(byte + 0x60)}',
            raw: String.fromCharCode(byte));
    }
  }

  int? _takeRune() {
    if (_buffer.isEmpty) return null;
    final first = _buffer.first;
    int length;
    if (first < 0x80) {
      length = 1;
    } else if ((first & 0xe0) == 0xc0) {
      length = 2;
    } else if ((first & 0xf0) == 0xe0) {
      length = 3;
    } else if ((first & 0xf8) == 0xf0) {
      length = 4;
    } else {
      _buffer.removeAt(0); // invalid leading byte
      return 0xfffd;
    }
    if (_buffer.length < length) return null;
    final bytes = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    return utf8.decode(bytes).runes.first;
  }

  bool _startsWith(List<int> prefix) {
    if (_buffer.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (_buffer[i] != prefix[i]) return false;
    }
    return true;
  }

  bool _isPrefixOf(List<int> sequence) {
    if (_buffer.isEmpty || _buffer.length >= sequence.length) return false;
    for (var i = 0; i < _buffer.length; i++) {
      if (_buffer[i] != sequence[i]) return false;
    }
    return true;
  }
}
