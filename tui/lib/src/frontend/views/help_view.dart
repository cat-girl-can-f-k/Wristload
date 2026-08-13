import '../theme/ansi_text.dart';
import '../theme/tui_theme.dart';
import '../widgets/frame.dart';
import '../widgets/panel.dart';

/// Renders the keyboard shortcuts help overlay.
class HelpView {
  HelpView({required this.frame, this.supportsColor});

  final Frame frame;
  final bool? supportsColor;

  void render() {
    frame.addRow(SectionHeader(
      width: frame.width,
      eyebrow: 'KEYMAP',
      title: '快捷键参考',
      meta: '全局 / 当前视图',
      supportsColor: supportsColor,
    ).render());
    frame.addBlank();

    final entries = [
      ('Tab / Shift+Tab', '切换焦点区'),
      ('1-5', '切换主视图'),
      ('↑ / ↓ 或 j / k', '移动列表选择'),
      ('g / G', '列表顶部 / 底部'),
      ('Enter', '确认当前非危险动作'),
      ('r', '刷新已配对设备'),
      ('R', '开始 / 停止扫描'),
      ('m', '手动添加设备地址'),
      ('c', '连接 / 断开'),
      ('a', '输入 authkey'),
      ('i', '导入文件路径'),
      ('s', '开始队列'),
      ('x', '取消任务'),
      ('d', '删除队列条目'),
      ('l', '日志跟随开关'),
      ('F / T', '宽屏日志级别 / 类别筛选'),
      ('L / [ ]', '宽屏日志跟随 / 滚动'),
      ('0', '重置日志筛选'),
      ('e', '导出脱敏日志'),
      ('? / F1', '打开帮助'),
      ('Esc', '关闭弹层 / 取消输入'),
      ('q', '退出'),
    ];

    final gap = TuiTheme.muted(' │ ', supportsColor: supportsColor);
    final columnWidth =
        ((frame.width - 3) ~/ 2).clamp(1, frame.width).toInt();
    final split = (entries.length + 1) ~/ 2;
    for (var i = 0; i < split; i++) {
      final left = _entry(entries[i], columnWidth);
      final rightIndex = i + split;
      final right = rightIndex < entries.length
          ? _entry(entries[rightIndex], columnWidth)
          : ' ' * columnWidth;
      frame.addRow('$left$gap$right');
    }

    frame.addBlank();
    frame.addRow(CalloutWidget(
      width: frame.width,
      label: '安全',
      message: 'authkey 仅保留在进程内存，不会写入 Keychain 或日志。',
      tone: TuiTone.success,
      supportsColor: supportsColor,
    ).render());
    frame.addRow(CalloutWidget(
      width: frame.width,
      label: '范围',
      message: '仅支持 macOS 经典蓝牙 / RFCOMM，不支持 BLE GATT。',
      tone: TuiTone.info,
      supportsColor: supportsColor,
    ).render());
  }

  String _entry((String, String) entry, int width) {
    final keyWidth = width.clamp(8, 18).toInt();
    final key = AnsiText.fit(
      TuiTheme.key(entry.$1, supportsColor: supportsColor),
      keyWidth,
    );
    final descriptionWidth = (width - keyWidth - 1).clamp(0, width).toInt();
    return '$key ${AnsiText.fit(entry.$2, descriptionWidth)}';
  }
}
