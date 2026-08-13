import '../port/tui_snapshot.dart';
import '../state/app_state.dart';
import '../theme/ansi_text.dart';
import '../theme/tui_theme.dart';
import '../widgets/frame.dart';
import '../widgets/input.dart';
import '../widgets/panel.dart';
import '../widgets/table.dart';

/// Renders the device / connection view.
class DevicesView {
  DevicesView(
      {required this.snapshot,
      required this.state,
      required this.frame,
      this.supportsColor});

  final TuiSnapshot snapshot;
  final AppState state;
  final Frame frame;
  final bool? supportsColor;

  void render() {
    frame.addRow(SectionHeader(
      width: frame.width,
      eyebrow: 'DEVICES',
      title: '设备与连接',
      meta: '${snapshot.devices.length} 台设备',
      supportsColor: supportsColor,
    ).render());
    frame.addBlank();

    final helper = snapshot.helper;
    if (helper.state == TuiHelperState.stopped) {
      frame.addRow(CalloutWidget(
        width: frame.width,
        label: 'HELPER 停止',
        message: 'helper 尚未启动，请等待或按 r 刷新配对设备。',
        tone: TuiTone.warning,
        supportsColor: supportsColor,
      ).render());
      frame.addBlank();
    } else if (helper.state == TuiHelperState.failed) {
      frame.addRow(CalloutWidget(
        width: frame.width,
        label: 'HELPER 失败',
        message: helper.message ?? helper.code ?? '未知错误',
        tone: TuiTone.error,
        supportsColor: supportsColor,
      ).render());
      frame.addBlank();
    } else if (helper.state == TuiHelperState.starting) {
      frame.addRow(CalloutWidget(
        width: frame.width,
        label: 'HELPER',
        message: 'helper 启动中…',
        tone: TuiTone.info,
        supportsColor: supportsColor,
      ).render());
      frame.addBlank();
    }

    if (snapshot.devices.isEmpty) {
      if (snapshot.scan.state == TuiScanState.running) {
        frame.addRow(CalloutWidget(
          width: frame.width,
          label: '扫描中',
          message: '正在扫描… ${snapshot.scan.remaining?.inSeconds ?? 0}s',
          tone: TuiTone.accent,
          supportsColor: supportsColor,
        ).render());
      } else {
        frame.addRow(CalloutWidget(
          width: frame.width,
          label: '空闲',
          message: '未发现设备。按 r 刷新已配对设备，或按 R 开始扫描。',
          tone: TuiTone.muted,
          supportsColor: supportsColor,
        ).render());
      }
    } else {
      _renderDeviceTable();
    }

    frame.addBlank();
    final conn = snapshot.connection;
    frame.addRows(PanelWidget(
      width: frame.width,
      title: '连接状态',
      lines: ['当前连接: ${_styledConnSummary(conn)}'],
      tone: _connTone(conn),
      supportsColor: supportsColor,
    ).render());

    if (state.showAddDevice) {
      frame.addBlank();
      final lines = <String>[
        InputWidget(
          width: frame.width,
          label: '地址',
          value: state.manualAddress,
          hint: 'AA-BB-CC-DD-EE-FF',
          focused: state.manualDeviceField == ManualDeviceField.address,
          supportsColor: supportsColor,
        ).render(),
      ];
      final modelFocus = state.manualDeviceField == ManualDeviceField.model;
      final modelLine =
          '${modelFocus ? '▶' : ' '} 型号: ${state.selectedModelId.isEmpty ? '使用上下键选择' : state.selectedModelId}';
      lines.add(modelFocus
          ? TuiTheme.selected(modelLine, supportsColor: supportsColor)
          : modelLine);
      final models = snapshot.supportedModels.where((model) => model.supported);
      for (final model in models.take(5)) {
        final prefix = model.modelId == state.selectedModelId ? '▶ ' : '  ';
        final line = '$prefix${model.modelId} ${model.displayName}';
        lines.add(model.modelId == state.selectedModelId
            ? TuiTheme.selected(line, supportsColor: supportsColor)
            : TuiTheme.muted(line, supportsColor: supportsColor));
      }
      lines.add(
        InputWidget(
          width: frame.width,
          label: '显示名称',
          value: state.manualDisplayName,
          hint: '可选',
          focused: state.manualDeviceField == ManualDeviceField.displayName,
          supportsColor: supportsColor,
        ).render(),
      );
      lines.add(TuiTheme.muted(
        'Tab 切换字段，Enter 保存。',
        supportsColor: supportsColor,
      ));
      frame.addRows(PanelWidget(
        width: frame.width,
        title: '手动添加设备',
        lines: lines,
        tone: TuiTone.accent,
        supportsColor: supportsColor,
      ).render());
    }
  }

  void _renderDeviceTable() {
    final cols = [
      const TableColumn('名称', 18),
      const TableColumn('MAC 地址', 20),
      const TableColumn('配对', 6, align: TableAlign.right),
      const TableColumn('来源', 10),
      const TableColumn('RSSI', 6, align: TableAlign.right),
      const TableColumn('型号', 22),
      const TableColumn('支持', 10),
    ];
    final tableWidth =
        cols.fold<int>(0, (sum, c) => sum + c.width) + (cols.length - 1) * 1;
    if (tableWidth > frame.width) {
      // Fall back to compact list if terminal is too narrow.
      for (var i = 0; i < snapshot.devices.length; i++) {
        final d = snapshot.devices[i];
        final selected = d.deviceId == state.selectedDeviceId;
        final prefix = selected ? '▶ ' : '  ';
        final parts = [
          d.name ?? '未知名称',
          d.address,
          if (d.paired) '已配对' else '未配对',
          d.sources.map(_sourceLabel).join(','),
          if (d.rssi != null) '${d.rssi}dBm' else '',
          d.matchedModelName ?? '',
          _supportLabel(d),
        ];
        final line = '$prefix${parts.join(' │ ')}';
        frame.addRow(selected
            ? TuiTheme.selected(line, supportsColor: supportsColor)
            : line);
      }
      return;
    }

    final rows = snapshot.devices.map((d) {
      final selected = d.deviceId == state.selectedDeviceId;
      return [
        selected
            ? TuiTheme.selected(
                '▶${d.name ?? '未知名称'}',
                supportsColor: supportsColor,
              )
            : ' ${d.name ?? '未知名称'}',
        d.address,
        d.paired ? '是' : '否',
        d.sources.map(_sourceLabel).join(','),
        d.rssi != null ? '${d.rssi}' : '',
        d.matchedModelName ?? '未知',
        _supportLabel(d),
      ];
    }).toList();

    final table = TableWidget(
      columns: cols,
      rows: rows,
      supportsColor: supportsColor,
    );
    frame.addRows(table.render());
  }

  String _sourceLabel(TuiDeviceSource source) => switch (source) {
        TuiDeviceSource.paired => '配对',
        TuiDeviceSource.inquiry => '扫描',
        TuiDeviceSource.manual => '手动',
      };

  String _supportLabel(TuiDevice d) {
    if (d.supportState == TuiSupportState.supported) {
      return TuiTheme.paint(
        '支持',
        TuiTone.success,
        bold: true,
        supportsColor: supportsColor,
      );
    }
    if (d.blockedReason != null) {
      return TuiTheme.paint(
        AnsiText.truncate(d.blockedReason!, 10),
        TuiTone.error,
        supportsColor: supportsColor,
      );
    }
    return TuiTheme.paint(
      '未知',
      TuiTone.warning,
      supportsColor: supportsColor,
    );
  }

  String _styledConnSummary(TuiConnectionInfo conn) => TuiTheme.paint(
        _connSummary(conn),
        _connTone(conn),
        bold: conn.state == TuiConnectionState.ready ||
            conn.state == TuiConnectionState.failed ||
            conn.failureCode != null,
        supportsColor: supportsColor,
      );

  String _connSummary(TuiConnectionInfo conn) {
    if (conn.state == TuiConnectionState.disconnected) {
      if (conn.failureCode == null && conn.failureMessage == null) {
        return '未连接';
      }
      return '未连接 · ${conn.failureMessage ?? conn.failureCode}';
    }
    final target = conn.targetDeviceName ?? conn.targetAddress ?? '未知';
    final stateLabel = switch (conn.state) {
      TuiConnectionState.connecting => '连接中',
      TuiConnectionState.awaitingAuthKey => '等待 authkey',
      TuiConnectionState.authenticating => '鉴权中',
      TuiConnectionState.reconnecting => '重连中',
      TuiConnectionState.ready => '已就绪',
      TuiConnectionState.disconnecting => '断开中',
      TuiConnectionState.failed => '失败',
      _ => '',
    };
    return '$target ($stateLabel)${conn.failureMessage != null ? ' - ${conn.failureMessage}' : ''}';
  }

  TuiTone _connTone(TuiConnectionInfo conn) {
    if (conn.failureCode != null) return TuiTone.error;
    return switch (conn.state) {
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
  }
}
