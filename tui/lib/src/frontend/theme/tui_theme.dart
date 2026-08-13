import 'dart:io';

/// Semantic color roles used by the terminal UI. Every role also has a text
/// label or glyph, so disabling color never removes information.
enum TuiTone { neutral, accent, info, success, warning, error, muted }

/// Small ANSI theme tuned for dark terminals.
///
/// Color is enabled automatically only for an ANSI-capable stdout. It can be
/// disabled with `NO_COLOR`, `TERM=dumb`, or
/// `WRISTLOAD_TUI_COLOR=never`. `WRISTLOAD_TUI_COLOR=always` is useful for
/// snapshots written to an ANSI-aware file.
abstract final class TuiTheme {
  static const reset = '\x1b[0m';
  static const _bold = '\x1b[1m';
  static const _dim = '\x1b[2m';
  static const _cyan = '\x1b[96m';
  static const _teal = '\x1b[36m';
  static const _blue = '\x1b[94m';
  static const _green = '\x1b[92m';
  static const _yellow = '\x1b[93m';
  static const _red = '\x1b[91m';
  static const _white = '\x1b[97m';
  static const _gray = '\x1b[90m';
  static const _selection = '\x1b[48;5;236m';

  static bool? _colorOverride;

  /// Overrides automatic color detection. Pass null to restore auto mode.
  static void setColorEnabled(bool? enabled) => _colorOverride = enabled;

  static bool get colorEnabled {
    final override = _colorOverride;
    if (override != null) return override;

    final requested =
        Platform.environment['WRISTLOAD_TUI_COLOR']?.trim().toLowerCase();
    if (const {'never', '0', 'false', 'off'}.contains(requested)) return false;
    if (const {'always', '1', 'true', 'on'}.contains(requested)) return true;
    if (Platform.environment.containsKey('NO_COLOR')) return false;
    if (Platform.environment['TERM']?.toLowerCase() == 'dumb') return false;
    return stdout.supportsAnsiEscapes;
  }

  /// Resolves an optional terminal capability override against auto-detection.
  /// Widgets expose this value so embedders and snapshot tests can force a
  /// deterministic color mode without changing process-wide environment.
  static bool useColor(bool? supportsColor) => supportsColor ?? colorEnabled;

  static String paint(
    String text,
    TuiTone tone, {
    bool bold = false,
    bool dim = false,
    bool selected = false,
    bool? supportsColor,
  }) {
    if (!useColor(supportsColor) || text.isEmpty) return text;
    final codes = StringBuffer();
    if (selected) codes.write(_selection);
    if (bold) codes.write(_bold);
    if (dim) codes.write(_dim);
    codes.write(switch (tone) {
      TuiTone.neutral => _white,
      TuiTone.accent => _cyan,
      TuiTone.info => _blue,
      TuiTone.success => _green,
      TuiTone.warning => _yellow,
      TuiTone.error => _red,
      TuiTone.muted => _gray,
    });
    return '$codes$text$reset';
  }

  static String primary(
    String text, {
    bool bold = false,
    bool? supportsColor,
  }) =>
      paint(
        text,
        TuiTone.accent,
        bold: bold,
        supportsColor: supportsColor,
      );

  static String secondary(
    String text, {
    bool bold = false,
    bool? supportsColor,
  }) =>
      useColor(supportsColor)
          ? '${bold ? _bold : ''}$_teal$text$reset'
          : text;

  static String muted(String text, {bool? supportsColor}) => paint(
        text,
        TuiTone.muted,
        dim: true,
        supportsColor: supportsColor,
      );

  static String key(String text, {bool? supportsColor}) => paint(
        text,
        TuiTone.accent,
        bold: true,
        supportsColor: supportsColor,
      );

  static String selected(String text, {bool? supportsColor}) => paint(
        text,
        TuiTone.accent,
        bold: true,
        selected: true,
        supportsColor: supportsColor,
      );

  static String badge(
    String text,
    TuiTone tone, {
    bool? supportsColor,
  }) =>
      paint(
        '[$text]',
        tone,
        bold: tone != TuiTone.muted,
        supportsColor: supportsColor,
      );
}
