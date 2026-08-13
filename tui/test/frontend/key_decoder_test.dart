import 'dart:convert';

import 'package:test/test.dart';
import 'package:wristload_tui/src/frontend/input/key_decoder.dart';
import 'package:wristload_tui/src/frontend/input/key_event.dart';

void main() {
  group('KeyDecoder', () {
    late KeyDecoder decoder;
    late List<KeyEvent> events;

    setUp(() {
      decoder = KeyDecoder();
      events = [];
      decoder.events.listen(events.add);
    });

    tearDown(() => decoder.close());

    void send(String text) => decoder.addBytes(utf8.encode(text));

    test('decodes arrow keys', () async {
      send('\x1b[A\x1b[B\x1b[C\x1b[D');
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => (e as KeyPress).name),
          ['up', 'down', 'right', 'left']);
    });

    test('decodes printable characters', () async {
      send('abc');
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => (e as KeyPress).name), ['a', 'b', 'c']);
    });

    test('decodes control characters', () async {
      send('\n\t\x1b\x7f');
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => (e as KeyPress).name),
          ['enter', 'tab', 'esc', 'backspace']);
    });

    test('decodes a standalone Escape after the sequence timeout', () async {
      final standalone = KeyDecoder(escapeSequenceTimeout: Duration.zero);
      final standaloneEvents = <KeyEvent>[];
      standalone.events.listen(standaloneEvents.add);

      standalone.addBytes([0x1b]);
      await Future<void>.delayed(Duration.zero);

      expect((standaloneEvents.single as KeyPress).name, 'esc');
      standalone.close();
    });

    test('flushes a standalone Escape when the stream closes', () async {
      final standalone = KeyDecoder();
      final standaloneEvents = <KeyEvent>[];
      standalone.events.listen(standaloneEvents.add);

      standalone.addBytes([0x1b]);
      standalone.close();
      await Future<void>.delayed(Duration.zero);

      expect((standaloneEvents.single as KeyPress).name, 'esc');
    });

    test('waits for fragmented CSI and SS3 sequences', () async {
      decoder.addBytes([0x1b, 0x5b]);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      decoder.addBytes(utf8.encode('A'));

      decoder.addBytes([0x1b, 0x4f]);
      await Future<void>.delayed(Duration.zero);
      expect(events.map((event) => (event as KeyPress).name), ['up']);
      decoder.addBytes(utf8.encode('P'));
      await Future<void>.delayed(Duration.zero);

      expect(events.map((event) => (event as KeyPress).name), ['up', 'f1']);
    });

    test('falls back without swallowing an incomplete CSI suffix', () async {
      final incomplete = KeyDecoder(escapeSequenceTimeout: Duration.zero);
      final incompleteEvents = <KeyEvent>[];
      incomplete.events.listen(incompleteEvents.add);

      incomplete.addBytes([0x1b, 0x5b]);
      await Future<void>.delayed(Duration.zero);

      expect(incompleteEvents.map((event) => (event as KeyPress).name),
          ['esc', '[']);
      incomplete.close();
    });

    test('does not swallow a normal character after Escape', () async {
      send('\x1bx');
      await Future<void>.delayed(Duration.zero);

      expect(events.map((event) => (event as KeyPress).name), ['esc', 'x']);
    });

    test('decodes bracketed paste as single event', () async {
      send('\x1b[200~file1.bin\nfile2.rpk\n\x1b[201~');
      await Future<void>.delayed(Duration.zero);
      final paste = events.whereType<PasteEvent>().single;
      expect(paste.text, 'file1.bin\nfile2.rpk\n');
    });

    test('keeps a bracketed-paste terminator split across input chunks',
        () async {
      send('\x1b[200~file.rpk\x1b[20');
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);

      send('1~');
      await Future<void>.delayed(Duration.zero);

      final paste = events.single as PasteEvent;
      expect(paste.text, 'file.rpk');
    });

    test('decodes CJK characters', () async {
      send('中文');
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => (e as KeyPress).name), ['中', '文']);
    });
  });
}
