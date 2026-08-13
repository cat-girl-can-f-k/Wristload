import 'dart:async';

import 'package:test/test.dart';
import 'package:wristload_tui/src/frontend/app/tui_app.dart';
import 'package:wristload_tui/src/frontend/fixtures/tui_fixtures.dart';
import 'package:wristload_tui/src/frontend/port/fake_tui_frontend_port.dart';
import 'package:wristload_tui/src/frontend/terminal/fake_terminal.dart';

void main() {
  group('Terminal recovery', () {
    test('restores terminal after normal run', () async {
      final terminal = FakeTerminal();
      final port = FakeTuiFrontendPort(initial: TuiFixtures.base());
      final appFuture = TuiApp(
        terminal: terminal,
        port: port,
        previewLabel: 'TEST',
      ).run();
      // Wait for the app to start listening before sending quit.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      terminal.key('q');
      await appFuture;
      expect(terminal.rawMode, isFalse);
      expect(terminal.altBuffer, isFalse);
      expect(terminal.cursorVisible, isTrue);
      expect(terminal.disposed, isTrue);
      expect(port.recordedActions.where((a) => a.name == 'dispose').length, 1);
    });

    test('refuses to run on non-interactive terminal', () async {
      final terminal = FakeTerminal(interactive: false);
      final port = FakeTuiFrontendPort(initial: TuiFixtures.base());
      await expectLater(
        TuiApp(terminal: terminal, port: port, previewLabel: 'TEST').run(),
        throwsA(isA<StateError>()),
      );
      expect(terminal.rawMode, isFalse);
      expect(terminal.altBuffer, isFalse);
      expect(port.recordedActions.where((a) => a.name == 'dispose').length, 0);
    });

    test('restores terminal after exception in input stream', () async {
      final terminal = FakeTerminal();
      final port = FakeTuiFrontendPort(initial: TuiFixtures.base());
      final app = TuiApp(
        terminal: terminal,
        port: port,
        previewLabel: 'TEST',
      );
      final runFuture = app.run();
      // Give the app a moment to start listening.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Simulate a late exception by adding invalid bytes.
      terminal.type('\x80\x80\x80');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      terminal.key('q');
      await runFuture;
      expect(terminal.rawMode, isFalse);
      expect(terminal.disposed, isTrue);
    });
  });
}
