enum UiTone { normal, primary, muted, success, warning, error, selection }

class UiTheme {
  const UiTheme({
    required this.name,
    required this.background,
    required this.primary,
    required this.muted,
    required this.success,
    required this.warning,
    required this.error,
    required this.selection,
  });

  final String name;
  final String background;
  final String primary;
  final String muted;
  final String success;
  final String warning;
  final String error;
  final String selection;

  static const blackBlue = UiTheme(
    name: 'black-blue',
    background: '\x1b[48;5;16m',
    primary: '\x1b[38;5;75m',
    muted: '\x1b[38;5;244m',
    success: '\x1b[38;5;78m',
    warning: '\x1b[38;5;221m',
    error: '\x1b[38;5;203m',
    selection: '\x1b[48;5;17m\x1b[38;5;117m',
  );

  static const blackCyan = UiTheme(
    name: 'black-cyan',
    background: '\x1b[48;5;16m',
    primary: '\x1b[38;5;80m',
    muted: '\x1b[38;5;246m',
    success: '\x1b[38;5;85m',
    warning: '\x1b[38;5;221m',
    error: '\x1b[38;5;210m',
    selection: '\x1b[48;5;23m\x1b[38;5;159m',
  );

  static const blackGreen = UiTheme(
    name: 'black-green',
    background: '\x1b[48;5;16m',
    primary: '\x1b[38;5;78m',
    muted: '\x1b[38;5;246m',
    success: '\x1b[38;5;85m',
    warning: '\x1b[38;5;221m',
    error: '\x1b[38;5;210m',
    selection: '\x1b[48;5;22m\x1b[38;5;120m',
  );

  static const available = <UiTheme>[blackBlue, blackCyan, blackGreen];

  static UiTheme resolve(String? id) {
    for (final theme in available) {
      if (theme.name == id) return theme;
    }
    return blackBlue;
  }

  static const reset = '\x1b[0m';

  String paint(String text, UiTone tone, {required bool enabled}) {
    if (!enabled || text.isEmpty) return text;
    final code = switch (tone) {
      UiTone.normal => '',
      UiTone.primary => primary,
      UiTone.muted => muted,
      UiTone.success => success,
      UiTone.warning => warning,
      UiTone.error => error,
      UiTone.selection => selection,
    };
    return '$background$code$text$reset';
  }
}
