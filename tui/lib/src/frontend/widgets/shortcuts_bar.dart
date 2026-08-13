import '../port/tui_snapshot.dart';
import '../state/app_state.dart';
import '../theme/ansi_text.dart';
import '../theme/tui_theme.dart';

/// Renders the bottom shortcut bar. Only actions allowed by the snapshot are
/// shown as active; blocked actions are shown dimmed with their reason.
class ShortcutsBar {
  ShortcutsBar({required this.width, this.supportsColor});

  final int width;
  final bool? supportsColor;

  String render(TuiSnapshot snapshot, AppState state) {
    final entries = <String>[];

    if (state.showHelp) {
      entries.add(_entry('?', '关闭帮助'));
    } else {
      entries.add(_entry('?', '帮助'));
    }

    entries.add(_entry('1-5', '视图'));
    if (state.wideLayout) {
      entries.add(_entry('F/T', '日志筛选'));
      entries.add(_entry('L', '日志跟随'));
      entries.add(_entry('[ ]', '日志滚动'));
    }

    switch (state.currentView) {
      case View.devices:
        _addIfAllowed(entries, snapshot, 'r', '刷新配对', 'refreshPairedDevices');
        _addIfAllowed(entries, snapshot, 'R', '扫描', 'startScan',
            alternate: 'stopScan');
        _addIfAllowed(entries, snapshot, 'm', '手动地址', 'addManualDevice');
        if (snapshot.connection.state == TuiConnectionState.disconnected) {
          _addIfAllowed(entries, snapshot, 'c', '连接', 'connectDevice');
        } else {
          entries.add(_entry('c', '断开'));
        }
        _addIfAllowed(entries, snapshot, 'a', '鉴权', 'submitAuthKey');
      case View.queue:
        _addIfAllowed(entries, snapshot, 'i', '导入', 'importFiles');
        _addIfAllowed(entries, snapshot, 's', '开始队列', 'startQueue');
        _addIfAllowed(entries, snapshot, 'x', '取消', 'cancelActiveInstall');
        _addIfAllowed(entries, snapshot, 'd', '删除', 'removeQueueItem');
        _addIfAllowed(entries, snapshot, '↑/↓', '移动', 'moveQueueItem');
        _addIfAllowed(entries, snapshot, 'R', '重试', 'retryQueueItem');
        _addIfAllowed(
          entries,
          snapshot,
          'C',
          '清理完成',
          'clearCompletedQueue',
        );
      case View.task:
        _addIfAllowed(entries, snapshot, 'x', '取消', 'cancelActiveInstall');
        _addIfAllowed(entries, snapshot, 'c', '检查恢复', 'inspectRecovery');
      case View.settings:
        _addIfAllowed(
            entries, snapshot, 'Enter', '保存', 'updateTransferSettings');
      case View.logs:
        entries.add(_entry('l', '跟随:${state.logsFollowTail ? "开" : "关"}'));
        _addIfAllowed(entries, snapshot, 'e', '导出', 'exportSafeLogs');
    }

    entries.add(_entry('q', '退出'));

    final separator = TuiTheme.muted(' │ ', supportsColor: supportsColor);
    return AnsiText.truncate(entries.join(separator), width);
  }

  void _addIfAllowed(
    List<String> entries,
    TuiSnapshot snapshot,
    String key,
    String label,
    String action, {
    String? alternate,
  }) {
    final allowed = snapshot.allowedActions.contains(action) ||
        (alternate != null && snapshot.allowedActions.contains(alternate));
    if (allowed) {
      entries.add(_entry(key, label));
    } else {
      final reason = snapshot.blockedReasons[action];
      final text = '$key $label (${reason ?? '不可用'})';
      entries.add(TuiTheme.muted(text, supportsColor: supportsColor));
    }
  }

  String _entry(String key, String label) =>
      '${TuiTheme.key(key, supportsColor: supportsColor)} $label';
}
