import 'package:test/test.dart';
import 'package:wristload_tui/src/entrypoint/tui_launch_options.dart';

void main() {
  const fixtures = <String>['base', 'ready'];

  TuiLaunchOptions parse(List<String> arguments) =>
      TuiLaunchOptions.parse(arguments, fixtureNames: fixtures);

  const directedArguments = <String>[
    '--directed-mac',
    '12-34-56-78-9a-bc',
    '--directed-name',
    'Example Classic Device',
    '--directed-profile',
    'band10Pro',
  ];

  group('TuiLaunchOptions directed Classic target', () {
    test('accepts a complete process-local target and canonicalizes its MAC',
        () {
      final options = parse(directedArguments);

      expect(options.error, isNull);
      expect(options.directedClassicTarget, isNotNull);
      expect(options.directedClassicTarget!.macAddress, '12:34:56:78:9A:BC');
      expect(
          options.directedClassicTarget!.displayName, 'Example Classic Device');
      expect(options.directedClassicTarget!.profile.family.name, 'band10Pro');
    });

    test('allows an explicit helper with a complete directed target', () {
      final options = parse(<String>[
        '--helper',
        '/tmp/bridge',
        ...directedArguments,
      ]);

      expect(options.error, isNull);
      expect(options.helperPath, '/tmp/bridge');
      expect(options.directedClassicTarget, isNotNull);
    });

    for (final omittedOption in <String>[
      '--directed-mac',
      '--directed-name',
      '--directed-profile',
    ]) {
      test('rejects a directed target missing $omittedOption', () {
        final incomplete = <String>[];
        for (var index = 0; index < directedArguments.length; index += 2) {
          if (directedArguments[index] == omittedOption) continue;
          incomplete
            ..add(directedArguments[index])
            ..add(directedArguments[index + 1]);
        }

        final options = parse(incomplete);

        expect(options.directedClassicTarget, isNull);
        expect(options.error, contains('must be provided together'));
      });
    }

    test('rejects an invalid Classic MAC', () {
      final options = parse(<String>[
        '--directed-mac',
        'not-a-classic-mac',
        '--directed-name',
        'Example Classic Device',
        '--directed-profile',
        'band10Pro',
      ]);

      expect(options.directedClassicTarget, isNull);
      expect(options.error, 'Invalid directed Classic target.');
    });

    test('rejects an empty or control-character device name', () {
      final empty = parse(<String>[
        '--directed-mac',
        '12:34:56:78:9A:BC',
        '--directed-name',
        '',
        '--directed-profile',
        'band10Pro',
      ]);
      final control = parse(<String>[
        '--directed-mac',
        '12:34:56:78:9A:BC',
        '--directed-name',
        'Example\nDevice',
        '--directed-profile',
        'band10Pro',
      ]);

      expect(empty.error, 'Invalid directed Classic target.');
      expect(control.error, 'Invalid directed Classic target.');
    });

    test('requires an explicit recognized profile identifier', () {
      final options = parse(<String>[
        '--directed-mac',
        '12:34:56:78:9A:BC',
        '--directed-name',
        'Example Classic Device',
        '--directed-profile',
        'unrecognized-profile',
      ]);

      expect(options.directedClassicTarget, isNull);
      expect(options.error, 'Invalid directed Classic target.');
    });

    test('keeps directed target mutually exclusive with probe and fixtures',
        () {
      final probe = parse(<String>['--probe', ...directedArguments]);
      final fixture = parse(<String>[
        '--fixture',
        'base',
        ...directedArguments,
      ]);

      expect(
        probe.error,
        '--directed-* cannot be combined with --probe or --fixture.',
      );
      expect(
        fixture.error,
        '--directed-* cannot be combined with --probe or --fixture.',
      );
    });

    test('does not create a directed target for ordinary launch modes', () {
      expect(parse(const <String>[]).directedClassicTarget, isNull);
      expect(
        parse(const <String>['--fixture', 'base']).directedClassicTarget,
        isNull,
      );
      expect(parse(const <String>['--probe']).directedClassicTarget, isNull);
    });
  });
}
