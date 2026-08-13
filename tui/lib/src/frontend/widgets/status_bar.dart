import '../port/tui_snapshot.dart';
import '../theme/ansi_text.dart';
import '../theme/tui_theme.dart';

/// Renders the top status bar summarizing platform, helper, scan, connection,
/// authkey and active task.
class StatusBar {
  StatusBar({required this.width, this.supportsColor});

  final int width;
  final bool? supportsColor;

  String render(TuiSnapshot snapshot) {
    final platformTone = snapshot.platform.currentSupported
        ? TuiTone.info
        : TuiTone.error;
    final parts = <String>[
      TuiTheme.badge(
        'macOS-only',
        platformTone,
        supportsColor: supportsColor,
      ),
    ];

    final helper = snapshot.helper;
    parts.add(_status('Helper', _helperLabel(helper), _helperTone(helper.state)));

    final scan = snapshot.scan;
    if (scan.state != TuiScanState.idle) {
      parts.add(_status('扫描', _scanLabel(scan), _scanTone(scan.state)));
    }

    final conn = snapshot.connection;
    if (conn.state != TuiConnectionState.disconnected ||
        conn.failureCode != null) {
      parts.add(_status(
        '连接',
        _connLabel(conn),
        conn.failureCode == null ? _connTone(conn.state) : TuiTone.error,
      ));
    }

    if (snapshot.authKeyLoaded) {
      parts.add(TuiTheme.badge(
        '已鉴权',
        TuiTone.success,
        supportsColor: supportsColor,
      ));
    }

    final task = snapshot.activeTask;
    if (task != null) {
      parts.add(_status(
        _stageLabel(task.stage),
        task.fileName,
        _taskTone(task.stage),
      ));
    }

    final separator = TuiTheme.muted(' │ ', supportsColor: supportsColor);
    return AnsiText.truncate(parts.join(separator), width);
  }

  String _status(String name, String value, TuiTone tone) =>
      '${TuiTheme.muted(name, supportsColor: supportsColor)}:'
      '${TuiTheme.paint(
        value,
        tone,
        bold: tone == TuiTone.success || tone == TuiTone.error,
        supportsColor: supportsColor,
      )}';

  String _helperLabel(TuiHelperInfo helper) => switch (helper.state) {
        TuiHelperState.stopped => '停止',
        TuiHelperState.starting => '启动中',
        TuiHelperState.ready => '就绪',
        TuiHelperState.failed => helper.code ?? '失败',
        TuiHelperState.disposed => '已释放',
      };

  String _scanLabel(TuiScanInfo scan) => switch (scan.state) {
        TuiScanState.idle => '空闲',
        TuiScanState.starting => '启动中',
        TuiScanState.running =>
          '运行中${scan.remaining != null ? ' ${scan.remaining!.inSeconds}s' : ''}',
        TuiScanState.stopping => '停止中',
        TuiScanState.failed => '失败',
      };

  String _connLabel(TuiConnectionInfo conn) {
    final name = conn.targetDeviceName ?? conn.targetAddress ?? '?';
    final label = '${_connStateLabel(conn.state)} $name';
    if (conn.failureCode == null) return label;
    if (conn.failureCode == 'rfcomm_rebuild_required') {
      return '$label · 需重建 RFCOMM';
    }
    return '$label · ${conn.failureMessage ?? conn.failureCode}';
  }

  String _connStateLabel(TuiConnectionState state) => switch (state) {
        TuiConnectionState.disconnected => '未连接',
        TuiConnectionState.connecting => '连接中',
        TuiConnectionState.awaitingAuthKey => '待鉴权',
        TuiConnectionState.authenticating => '鉴权中',
        TuiConnectionState.reconnecting => '重连中',
        TuiConnectionState.ready => '就绪',
        TuiConnectionState.disconnecting => '断开中',
        TuiConnectionState.failed => '失败',
      };

  String _stageLabel(TuiTaskStage stage) => switch (stage) {
        TuiTaskStage.validating => '校验',
        TuiTaskStage.waitingForProtocol => '等待协议',
        TuiTaskStage.transferring => '传输',
        TuiTaskStage.awaitingDevice => '等待设备',
        TuiTaskStage.succeeded => '成功',
        TuiTaskStage.failed => '失败',
        TuiTaskStage.cancelled => '已取消',
        TuiTaskStage.stateUnknown => '状态未知',
      };

  TuiTone _helperTone(TuiHelperState state) => switch (state) {
        TuiHelperState.ready => TuiTone.success,
        TuiHelperState.failed => TuiTone.error,
        TuiHelperState.starting => TuiTone.info,
        TuiHelperState.stopped || TuiHelperState.disposed => TuiTone.muted,
      };

  TuiTone _scanTone(TuiScanState state) => switch (state) {
        TuiScanState.failed => TuiTone.error,
        TuiScanState.running => TuiTone.accent,
        TuiScanState.starting || TuiScanState.stopping => TuiTone.info,
        TuiScanState.idle => TuiTone.muted,
      };

  TuiTone _connTone(TuiConnectionState state) => switch (state) {
        TuiConnectionState.ready => TuiTone.success,
        TuiConnectionState.failed => TuiTone.error,
        TuiConnectionState.awaitingAuthKey => TuiTone.warning,
        TuiConnectionState.connecting ||
        TuiConnectionState.authenticating ||
        TuiConnectionState.reconnecting ||
        TuiConnectionState.disconnecting =>
          TuiTone.info,
        TuiConnectionState.disconnected => TuiTone.muted,
      };

  TuiTone _taskTone(TuiTaskStage stage) => switch (stage) {
        TuiTaskStage.succeeded => TuiTone.success,
        TuiTaskStage.failed => TuiTone.error,
        TuiTaskStage.cancelled || TuiTaskStage.stateUnknown => TuiTone.warning,
        TuiTaskStage.transferring => TuiTone.accent,
        TuiTaskStage.validating ||
        TuiTaskStage.waitingForProtocol ||
        TuiTaskStage.awaitingDevice =>
          TuiTone.info,
      };
}
