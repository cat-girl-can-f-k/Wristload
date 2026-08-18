/// Parsed, non-secret launch configuration for the standalone TUI.
library;

import '../application/tui_application.dart';

final class TuiLaunchOptions {
  const TuiLaunchOptions({
    this.helperPath,
    this.fixtureName,
    this.directedClassicTarget,
    this.probe = false,
    this.showHelp = false,
    this.error,
  });

  factory TuiLaunchOptions.parse(
    List<String> arguments, {
    required Iterable<String> fixtureNames,
  }) {
    String? helperPath;
    String? fixtureName;
    String? directedMac;
    String? directedName;
    String? directedProfile;
    var probe = false;
    var showHelp = false;

    String? readValue(int index) {
      if (index + 1 >= arguments.length ||
          arguments[index + 1].startsWith('-')) {
        return null;
      }
      return arguments[index + 1];
    }

    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--help' || argument == '-h') {
        showHelp = true;
      } else if (argument == '--probe') {
        probe = true;
      } else if (argument == '--helper' ||
          argument == '--fixture' ||
          argument == '--directed-mac' ||
          argument == '--directed-name' ||
          argument == '--directed-profile') {
        final value = readValue(index);
        if (value == null) {
          return TuiLaunchOptions(error: argument + ' requires a value.');
        }
        index++;
        if (argument == '--helper') {
          if (helperPath != null) {
            return const TuiLaunchOptions(
              error: '--helper may only be supplied once.',
            );
          }
          helperPath = value;
        } else if (argument == '--fixture') {
          if (fixtureName != null) {
            return const TuiLaunchOptions(
              error: '--fixture may only be supplied once.',
            );
          }
          fixtureName = value;
        } else if (argument == '--directed-mac') {
          if (directedMac != null) {
            return const TuiLaunchOptions(
              error: '--directed-mac may only be supplied once.',
            );
          }
          directedMac = value;
        } else if (argument == '--directed-name') {
          if (directedName != null) {
            return const TuiLaunchOptions(
              error: '--directed-name may only be supplied once.',
            );
          }
          directedName = value;
        } else {
          if (directedProfile != null) {
            return const TuiLaunchOptions(
              error: '--directed-profile may only be supplied once.',
            );
          }
          directedProfile = value;
        }
      } else {
        return TuiLaunchOptions(error: 'Unknown argument: ' + argument);
      }
    }

    if (probe && fixtureName != null) {
      return const TuiLaunchOptions(
        error: '--probe cannot be combined with --fixture.',
      );
    }
    if (fixtureName != null && !fixtureNames.contains(fixtureName)) {
      return TuiLaunchOptions(error: 'Unknown fixture: ' + fixtureName);
    }

    final directedCount = <String?>[
      directedMac,
      directedName,
      directedProfile,
    ].whereType<String>().length;
    if (directedCount != 0 && directedCount != 3) {
      return const TuiLaunchOptions(
        error:
            '--directed-mac, --directed-name, and --directed-profile must be provided together.',
      );
    }
    if (directedCount != 0 && (probe || fixtureName != null)) {
      return const TuiLaunchOptions(
        error: '--directed-* cannot be combined with --probe or --fixture.',
      );
    }

    TuiDirectedClassicTarget? target;
    if (directedCount == 3) {
      try {
        target = TuiDirectedClassicTarget.fromExplicitProfileId(
          macAddress: directedMac!,
          displayName: directedName!,
          profileId: directedProfile!,
        );
      } on FormatException {
        return const TuiLaunchOptions(
            error: 'Invalid directed Classic target.');
      } on ArgumentError {
        return const TuiLaunchOptions(
            error: 'Invalid directed Classic target.');
      }
    }

    return TuiLaunchOptions(
      helperPath: helperPath,
      fixtureName: fixtureName,
      directedClassicTarget: target,
      probe: probe,
      showHelp: showHelp,
    );
  }

  final String? helperPath;
  final String? fixtureName;
  final TuiDirectedClassicTarget? directedClassicTarget;
  final bool probe;
  final bool showHelp;
  final String? error;
}
