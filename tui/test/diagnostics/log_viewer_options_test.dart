import 'package:test/test.dart';
import 'package:wristload_tui/src/diagnostics/log_viewer.dart';

void main() {
  test('uses the default live-follow behavior with no options', () {
    final options = DiagnosticLogViewerOptions.parse(const <String>[]);

    expect(options.path, isNull);
    expect(options.follow, isTrue);
    expect(options.help, isFalse);
  });

  test('defers default journal resolution for help and explicit files', () {
    final help = DiagnosticLogViewerOptions.parse(<String>['--help']);
    final explicit = DiagnosticLogViewerOptions.parse(<String>[
      '--file',
      '/tmp/wristload-diagnostics.jsonl',
    ]);

    expect(help.help, isTrue);
    expect(help.path, isNull);
    expect(explicit.help, isFalse);
    expect(explicit.path, '/tmp/wristload-diagnostics.jsonl');
    expect(explicit.follow, isFalse);
  });
}
