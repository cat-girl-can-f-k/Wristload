import 'cell_width.dart';
import 'port.dart';
import 'state.dart';
import 'theme.dart';

enum UiLayoutMode { compact, wrapped, wide }

class UiRect {
  const UiRect(this.left, this.top, this.right, this.bottom);

  final int left;
  final int top;
  final int right;
  final int bottom;

  bool contains(int column, int row) =>
      column >= left && column <= right && row >= top && row <= bottom;
}

enum UiHitAction {
  device,
  scan,
  connect,
  disconnect,
  details,
  save,
  remove,
  authKey,
  install,
  cancelInstall,
  autoConnect,
  theme,
}

class UiHitRegion {
  const UiHitRegion({required this.rect, required this.action, this.deviceId});

  final UiRect rect;
  final UiHitAction action;
  final String? deviceId;
}

class UiLayoutResult {
  UiLayoutResult({
    required this.text,
    required this.mode,
    required List<UiHitRegion> hitRegions,
    required List<String> visibleDeviceIds,
    required this.maxScrollOffset,
  })  : hitRegions = List.unmodifiable(hitRegions),
        visibleDeviceIds = List.unmodifiable(visibleDeviceIds);

  final String text;
  final UiLayoutMode mode;
  final List<UiHitRegion> hitRegions;
  final List<String> visibleDeviceIds;
  final int maxScrollOffset;
}

class UiNextRenderer {
  const UiNextRenderer();

  UiLayoutResult render({
    required UiSnapshot snapshot,
    required UiNextState state,
    required int width,
    required int height,
    required bool color,
  }) {
    final theme = UiTheme.resolve(snapshot.themeId);
    final safeWidth = width.clamp(1, 1000);
    final safeHeight = height.clamp(1, 1000);
    final mode = safeWidth >= 110
        ? UiLayoutMode.wide
        : safeWidth >= 75
            ? UiLayoutMode.wrapped
            : UiLayoutMode.compact;
    final lines = <String>[];
    final hits = <UiHitRegion>[];
    final visible = <String>[];

    void add(String line, {UiTone tone = UiTone.normal}) {
      if (lines.length >= safeHeight) return;
      final plain = _fit(line, safeWidth);
      lines.add(theme.paint(plain, tone, enabled: color));
    }

    add(' wristload  TUI / macOS', tone: UiTone.primary);
    add(_statusLine(snapshot, safeWidth), tone: UiTone.muted);
    add('─' * safeWidth, tone: UiTone.primary);

    var maxDetailOffset = 0;
    if (state.detailOpen) {
      maxDetailOffset = _renderDetail(
        snapshot,
        state,
        safeWidth,
        safeHeight,
        lines,
        color,
        theme,
      );
    } else {
      add(snapshot.devices.isEmpty
          ? (snapshot.scanning ? ' 正在搜索设备…' : ' 没有设备，按 r 开始扫描')
          : ' 设备名称 -- MAC地址 -- 可否支持 -- authkey');
      final footerRows = _footerRows(snapshot, state, safeWidth);
      final available =
          (safeHeight - lines.length - footerRows).clamp(0, safeHeight);
      final blocks = snapshot.devices
          .map((device) => _deviceBlock(device, mode, safeWidth))
          .toList(growable: false);
      final maxOffset = blocks.isEmpty ? 0 : blocks.length - 1;
      state.scrollOffset = state.scrollOffset.clamp(0, maxOffset);
      var used = 0;
      for (var index = state.scrollOffset; index < blocks.length; index++) {
        final block = blocks[index];
        if (used > 0 && used + block.length > available) break;
        if (block.length > available - used && used > 0) break;
        final startRow = lines.length + 1;
        final selected = state.selectedDeviceId == snapshot.devices[index].id;
        for (final line in block.take(available - used)) {
          add(
            selected ? _selectedLine(line) : line,
            tone: selected ? UiTone.selection : UiTone.normal,
          );
          used++;
        }
        if (used == 0) break;
        visible.add(snapshot.devices[index].id);
        hits.add(UiHitRegion(
          rect: UiRect(1, startRow, safeWidth, lines.length),
          action: UiHitAction.device,
          deviceId: snapshot.devices[index].id,
        ));
        if (used >= available) break;
      }

      while (lines.length < safeHeight - footerRows) {
        add('');
      }
      _renderFooter(
        snapshot,
        state,
        safeWidth,
        safeHeight,
        lines,
        hits,
        color,
        theme,
      );
      if (state.modal != null) {
        _renderModal(state, safeWidth, safeHeight, lines, color, theme);
      }
      return _finish(
          lines, safeWidth, safeHeight, mode, hits, visible, maxOffset);
    }

    _renderDetailFooter(safeWidth, safeHeight, lines, hits, color, theme);
    return _finish(
      lines,
      safeWidth,
      safeHeight,
      mode,
      hits,
      visible,
      maxDetailOffset,
    );
  }

  UiLayoutResult _finish(
    List<String> lines,
    int width,
    int height,
    UiLayoutMode mode,
    List<UiHitRegion> hits,
    List<String> visible,
    int maxOffset,
  ) {
    while (lines.length < height) {
      lines.add(' ' * width);
    }
    return UiLayoutResult(
      text: '${lines.take(height).join('\n')}\n',
      mode: mode,
      hitRegions: hits,
      visibleDeviceIds: visible,
      maxScrollOffset: maxOffset,
    );
  }

  List<String> _deviceBlock(UiDevice device, UiLayoutMode mode, int width) {
    final support = _support(device.support);
    final marker = device.connected
        ? '●'
        : device.saved
            ? '◆'
            : ' ';
    if (mode == UiLayoutMode.wide) {
      return _wrapCells(
        '  $marker ${device.name} -- ${device.macAddress} -- $support -- ${device.authKeyLabel}',
        width,
        continuationIndent: 4,
      );
    }
    if (mode == UiLayoutMode.wrapped) {
      return <String>[
        ..._wrapCells('  $marker ${device.name}', width, continuationIndent: 4),
        ..._wrapCells(
          '    ${device.macAddress} -- $support -- ${device.authKeyLabel}',
          width,
          continuationIndent: 4,
        ),
      ];
    }
    return <String>[
      ..._wrapCells('  $marker ${device.name}', width, continuationIndent: 4),
      '    MAC: ${device.macAddress}',
      '    支持: $support',
      ..._wrapCells(
        '    authkey: ${device.authKeyLabel}',
        width,
        continuationIndent: 4,
      ),
    ];
  }

  int _renderDetail(
    UiSnapshot snapshot,
    UiNextState state,
    int width,
    int height,
    List<String> lines,
    bool color,
    UiTheme theme,
  ) {
    final device = _selected(snapshot, state);
    if (device == null) {
      lines.add(_fit(' 没有选中的设备', width));
      return 0;
    }
    final detailLines = <String>[
      theme.paint(_fit(' 设备详情', width), UiTone.primary, enabled: color),
    ];
    void addWrapped(String label, String value) {
      for (final line
          in _wrapCells(' $label$value', width, continuationIndent: 3)) {
        detailLines.add(line);
      }
    }

    addWrapped('名称: ', device.name);
    addWrapped('MAC: ', device.macAddress);
    addWrapped('支持: ', _support(device.support));
    addWrapped('authkey: ', device.authKeyLabel);
    addWrapped('保存: ', device.saved ? '是' : '否');
    addWrapped('连接: ', device.connected ? '已连接' : '未连接');
    final message =
        snapshot.error ?? snapshot.notice ?? snapshot.install.message;
    if (message != null && message.isNotEmpty) addWrapped('状态: ', message);

    final availableRows = (height - lines.length - 1).clamp(0, height);
    final maxOffset =
        (detailLines.length - availableRows).clamp(0, detailLines.length);
    state.scrollOffset = state.scrollOffset.clamp(0, maxOffset);
    lines.addAll(detailLines.skip(state.scrollOffset).take(availableRows));
    return maxOffset;
  }

  void _renderFooter(
    UiSnapshot snapshot,
    UiNextState state,
    int width,
    int height,
    List<String> lines,
    List<UiHitRegion> hits,
    bool color,
    UiTheme theme,
  ) {
    final actions = _actions(snapshot, state);
    final rows = _actionRows(actions, width);
    while (lines.length < height - rows.length - 1) {
      lines.add(' ' * width);
    }
    for (final row in rows) {
      if (lines.length >= height - 1) break;
      final rowNumber = lines.length + 1;
      final buffer = StringBuffer(' ');
      var column = 2;
      for (final action in row) {
        if (buffer.length > 1) {
          buffer.write('  ');
          column += 2;
        }
        final start = column;
        buffer.write(action.$1);
        column += UiCellWidth.of(action.$1);
        hits.add(UiHitRegion(
          rect: UiRect(start, rowNumber, column - 1, rowNumber),
          action: action.$2,
        ));
      }
      lines.add(theme.paint(_fit(buffer.toString(), width), UiTone.primary,
          enabled: color));
    }
    final notice =
        snapshot.error ?? snapshot.notice ?? _installLabel(snapshot.install);
    if (lines.length < height) {
      lines.add(theme.paint(
        _fit(' ${notice ?? '↑↓/滚轮选择  q退出'}', width),
        snapshot.error == null ? UiTone.muted : UiTone.error,
        enabled: color,
      ));
    }
  }

  List<(String, UiHitAction)> _actions(
    UiSnapshot snapshot,
    UiNextState state,
  ) {
    final selected = _selected(snapshot, state);
    return <(String, UiHitAction)>[
      ('[r]扫描', UiHitAction.scan),
      ('[c]连接', UiHitAction.connect),
      ('[x]断开', UiHitAction.disconnect),
      ('[Enter]详情', UiHitAction.details),
      (
        selected?.saved == true ? '[s]取消保存' : '[s]保存',
        selected?.saved == true ? UiHitAction.remove : UiHitAction.save
      ),
      ('[a]密钥', UiHitAction.authKey),
      ('[i]安装', UiHitAction.install),
      if (snapshot.install.phase != UiInstallPhase.idle)
        ('[z]取消安装', UiHitAction.cancelInstall),
      ('[t]自动:${snapshot.autoConnect ? '开' : '关'}', UiHitAction.autoConnect),
      ('[m]主题', UiHitAction.theme),
    ];
  }

  int _footerRows(UiSnapshot snapshot, UiNextState state, int width) =>
      _actionRows(_actions(snapshot, state), width).length + 1;

  void _renderDetailFooter(
    int width,
    int height,
    List<String> lines,
    List<UiHitRegion> hits,
    bool color,
    UiTheme theme,
  ) {
    while (lines.length < height - 1) {
      lines.add(' ' * width);
    }
    const label = '[Enter/Esc] 返回设备列表';
    if (lines.length < height) {
      lines.add(
          theme.paint(_fit(' $label', width), UiTone.primary, enabled: color));
    }
    if (lines.length != height) return;
    hits.add(UiHitRegion(
      rect: UiRect(2, height, UiCellWidth.of(label) + 1, height),
      action: UiHitAction.details,
    ));
  }

  void _renderModal(
    UiNextState state,
    int width,
    int height,
    List<String> lines,
    bool color,
    UiTheme theme,
  ) {
    if (height < 3) return;
    while (lines.length < height) {
      lines.add(' ' * width);
    }
    final title = state.modal == UiModal.authKey ? '输入 authkey' : '输入资源路径';
    final value = state.modal == UiModal.authKey
        ? ('*' * state.input.length)
        : state.input;
    final modalWidth = width.clamp(1, 64);
    final prompt = _fit(' $title: $value█', modalWidth);
    final hint = _fit(' Enter 确认  Esc 取消', modalWidth);
    lines[height - 3] = theme.paint(
      _fit(prompt, width),
      UiTone.selection,
      enabled: color,
    );
    lines[height - 2] = theme.paint(
      _fit(hint, width),
      UiTone.primary,
      enabled: color,
    );
  }

  List<List<(String, UiHitAction)>> _actionRows(
    List<(String, UiHitAction)> actions,
    int width,
  ) {
    final rows = <List<(String, UiHitAction)>>[];
    var current = <(String, UiHitAction)>[];
    var currentWidth = 1;
    for (final action in actions) {
      final needed = UiCellWidth.of(action.$1) + (current.isEmpty ? 0 : 2);
      if (current.isNotEmpty && currentWidth + needed > width) {
        rows.add(current);
        current = [];
        currentWidth = 1;
      }
      current.add(action);
      currentWidth += needed;
    }
    if (current.isNotEmpty) rows.add(current);
    return rows;
  }

  String _statusLine(UiSnapshot snapshot, int width) {
    final scan = snapshot.scanning ? '扫描中' : '扫描停止';
    final connection = switch (snapshot.connectionPhase) {
      UiConnectionPhase.disconnected => '未连接',
      UiConnectionPhase.connecting => '连接中',
      UiConnectionPhase.awaitingAuthKey => '等待 authkey',
      UiConnectionPhase.authenticating => '鉴权中',
      UiConnectionPhase.ready => '已连接',
      UiConnectionPhase.disconnecting => '断开中',
      UiConnectionPhase.failed => '连接失败',
    };
    return _fit(
      ' $scan  •  $connection  •  自动:${_autoConnect(snapshot.autoConnectState)}  •  ${snapshot.devices.length} 台设备',
      width,
    );
  }

  String _autoConnect(UiAutoConnectState state) => switch (state) {
        UiAutoConnectState.disabled => '关',
        UiAutoConnectState.idle => '待命',
        UiAutoConnectState.connecting => '连接中',
        UiAutoConnectState.ready => '就绪',
        UiAutoConnectState.noSavedDevice => '无历史',
        UiAutoConnectState.missingAuthKey => '缺密钥',
        UiAutoConnectState.failed => '失败',
        UiAutoConnectState.suppressedAfterDisconnect => '已暂停',
      };

  String _support(UiDeviceSupport support) => switch (support) {
        UiDeviceSupport.supported => '支持',
        UiDeviceSupport.unsupported => '不支持',
        UiDeviceSupport.unknown => '未知',
      };

  String? _installLabel(UiInstallStatus install) => switch (install.phase) {
        UiInstallPhase.idle => null,
        UiInstallPhase.preparing => '正在准备 ${install.fileName ?? '资源'}',
        UiInstallPhase.transferring =>
          '正在传输 ${install.fileName ?? '资源'} ${install.percent}%',
        UiInstallPhase.awaitingDevice => '传输完成，等待设备业务结果',
        UiInstallPhase.succeeded
            when install.successVerifiedByDeviceBusinessEvent =>
          '设备确认安装成功',
        UiInstallPhase.succeeded => '等待设备安装结果',
        UiInstallPhase.failed => install.message ?? '安装失败',
        UiInstallPhase.unknown => install.message ?? '设备安装结果未知',
      };

  UiDevice? _selected(UiSnapshot snapshot, UiNextState state) {
    for (final device in snapshot.devices) {
      if (device.id == state.selectedDeviceId) return device;
    }
    return null;
  }

  String _fit(String value, int width) {
    // External labels/messages must not inject terminal controls. Theme ANSI
    // sequences are applied after fitting by the caller.
    value = UiCellWidth.sanitizeText(value);
    final actual = UiCellWidth.of(value);
    if (actual <= width) return '$value${' ' * (width - actual)}';
    return UiCellWidth.takePrefix(value, width).text;
  }

  List<String> _wrapCells(
    String value,
    int width, {
    int continuationIndent = 0,
  }) {
    if (width <= 0) return const [''];
    value = UiCellWidth.sanitizeText(value);
    final result = <String>[];
    var remaining = value;
    while (remaining.isNotEmpty) {
      // Keep one cell available for source text even when the continuation
      // indent is wider than the terminal. This guarantees progress without
      // dropping graphemes.
      final requestedIndent = result.isEmpty ? 0 : continuationIndent;
      var indent = requestedIndent.clamp(0, width - 1).toInt();
      final firstWidth = UiCellWidth.firstGraphemeWidth(remaining);
      if (firstWidth > width - indent && firstWidth <= width) {
        indent = width - firstWidth;
      }
      final prefix = ' ' * indent;
      final available = width - indent;
      final prefixPart = UiCellWidth.takePrefix(remaining, available);
      result.add(_fit('$prefix${prefixPart.text}', width));
      if (prefixPart.consumedCodeUnits == 0) break;
      remaining = remaining.substring(prefixPart.consumedCodeUnits);
    }
    return result.isEmpty ? [_fit('', width)] : result;
  }

  String _selectedLine(String line) {
    // At extremely narrow widths the selection marker cannot replace the
    // entire one/two-cell content line; preserve the line and rely on the
    // selection tone so device text remains accessible.
    if (UiCellWidth.of(line) <= 2) return line;
    final content = line.length >= 2 ? line.substring(2) : '';
    return '› $content';
  }
}
