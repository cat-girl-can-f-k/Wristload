import '../port/tui_snapshot.dart';
import '../state/app_state.dart';
import '../theme/tui_theme.dart';
import '../widgets/frame.dart';
import '../widgets/input.dart';
import '../widgets/panel.dart';

/// Renders the settings view for transfer parameters.
class SettingsView {
  SettingsView({
    required this.snapshot,
    required this.state,
    required this.frame,
    this.supportsColor,
  });

  final TuiSnapshot snapshot;
  final AppState state;
  final Frame frame;
  final bool? supportsColor;

  void render() {
    frame.addRow(SectionHeader(
      width: frame.width,
      eyebrow: 'SETTINGS',
      title: '传输设置',
      meta: '实时生效前需保存',
      supportsColor: supportsColor,
    ).render());
    frame.addBlank();

    final settings = snapshot.transferSettings;
    final intervalInitial = state.segmentIntervalInput.isEmpty
        ? settings.segmentIntervalMs.toString()
        : state.segmentIntervalInput;
    final inputWidth = (frame.width - 4).clamp(0, frame.width).toInt();
    final parameterLines = <String>[
      InputWidget(
        width: inputWidth,
        label: '分段间隔 (ms)',
        value: intervalInitial,
        hint:
            '${settings.segmentIntervalMsRange.$1}-${settings.segmentIntervalMsRange.$2}',
        focused: state.settingsField == SettingsField.segmentInterval,
        supportsColor: supportsColor,
      ).render(),
      TuiTheme.muted(
        '范围: ${settings.segmentIntervalMsRange.$1} ~ '
        '${settings.segmentIntervalMsRange.$2} ms',
        supportsColor: supportsColor,
      ),
    ];
    final windowInitial = state.massWindowSizeInput.isEmpty
        ? settings.massWindowSize.toString()
        : state.massWindowSizeInput;
    parameterLines.add(
      InputWidget(
        width: inputWidth,
        label: 'Mass 窗口大小',
        value: windowInitial,
        hint:
            '${settings.massWindowSizeRange.$1}-${settings.massWindowSizeRange.$2}',
        focused: state.settingsField == SettingsField.massWindowSize,
        supportsColor: supportsColor,
      ).render(),
    );
    parameterLines.add(TuiTheme.muted(
      '范围: ${settings.massWindowSizeRange.$1} ~ '
      '${settings.massWindowSizeRange.$2} 片',
      supportsColor: supportsColor,
    ));
    frame.addRows(PanelWidget(
      width: frame.width,
      title: '传输参数',
      lines: parameterLines,
      tone: TuiTone.accent,
      supportsColor: supportsColor,
    ).render());

    frame.addBlank();
    if (settings.saving) {
      frame.addRow(CalloutWidget(
        width: frame.width,
        label: '保存中',
        message: '正在保存…',
        tone: TuiTone.info,
        supportsColor: supportsColor,
      ).render());
    } else if (settings.lastError != null) {
      frame.addRow(CalloutWidget(
        width: frame.width,
        label: '保存失败',
        message: settings.lastError!,
        tone: TuiTone.error,
        supportsColor: supportsColor,
      ).render());
    } else {
      frame.addRow(CalloutWidget(
        width: frame.width,
        label: '当前值',
        message: '${settings.segmentIntervalMs} ms / '
            '${settings.massWindowSize} 片',
        tone: TuiTone.success,
        supportsColor: supportsColor,
      ).render());
    }

    frame.addBlank();
    frame.addRow(CalloutWidget(
      width: frame.width,
      label: '实验参数',
      message: '过小间隔或过大窗口可能降低设备稳定性；按 Enter 保存。',
      tone: TuiTone.warning,
      supportsColor: supportsColor,
    ).render());
  }
}
