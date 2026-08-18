import 'cell_width.dart';
import 'port.dart';
import 'state.dart';
import 'theme.dart';

/// The layout changes its physical composition, not its information model.
/// Every value rendered here originates from [UiSnapshot] or UI-local state.
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
  directedConnect,
  disconnect,
  details,
  save,
  remove,
  authKey,
  install,
  cancelInstall,
  autoConnect,
  theme,
  openLogs,
  previousCommandPage,
  nextCommandPage,
}

class UiHitRegion {
  const UiHitRegion({
    required this.rect,
    required this.action,
    this.deviceId,
    this.isCommandAction = false,
  });

  final UiRect rect;
  final UiHitAction action;
  final String? deviceId;

  /// Command hits are the exact actions visibly rendered in the command bar.
  /// The shell uses this to keep arrow-key focus aligned with mouse targets.
  final bool isCommandAction;
}

class UiLayoutResult {
  UiLayoutResult({
    required this.text,
    required this.mode,
    required List<UiHitRegion> hitRegions,
    required List<String> visibleDeviceIds,
    required this.maxScrollOffset,
    List<String> visibleCommandActionNames = const [],
    this.commandPage = 0,
    this.commandPageCount = 1,
  })  : hitRegions = List.unmodifiable(hitRegions),
        visibleDeviceIds = List.unmodifiable(visibleDeviceIds),
        visibleCommandActionNames =
            List.unmodifiable(visibleCommandActionNames);

  final String text;
  final UiLayoutMode mode;
  final List<UiHitRegion> hitRegions;
  final List<String> visibleDeviceIds;
  final int maxScrollOffset;

  /// Enum names, in visible left-to-right command-bar order.
  final List<String> visibleCommandActionNames;

  /// The currently rendered, zero-based command-bar page.
  final int commandPage;

  /// Total command-bar pages after responsive row wrapping.
  final int commandPageCount;
}

final class _Line {
  const _Line(this.text, [this.tone = UiTone.normal]);

  final String text;
  final UiTone tone;
}

final class _PanelLine {
  const _PanelLine(
    this.text, {
    this.deviceId,
    this.selected = false,
    this.tone = UiTone.normal,
  });

  final String text;
  final String? deviceId;
  final bool selected;
  final UiTone tone;
}

final class _BrowserPanel {
  const _BrowserPanel({
    required this.lines,
    required this.visibleDeviceIds,
    required this.maxScrollOffset,
  });

  final List<_PanelLine> lines;
  final List<String> visibleDeviceIds;
  final int maxScrollOffset;
}

final class _CommandAction {
  const _CommandAction(this.label, this.action);

  final String label;
  final UiHitAction action;
}

final class _CommandDisplay {
  const _CommandDisplay(this.label, this.action);

  final String label;
  final UiHitAction action;
}

/// OpenCode-inspired device workbench renderer. It owns no transport state and
/// deliberately does not reconstruct a pairing/RFCOMM/protocol pipeline from
/// broad application phases.
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
    final safeWidth = width.clamp(1, 1000).toInt();
    final safeHeight = height.clamp(1, 1000).toInt();
    final mode = safeWidth >= 110
        ? UiLayoutMode.wide
        : safeWidth >= 75
            ? UiLayoutMode.wrapped
            : UiLayoutMode.compact;
    final lines = <_Line>[];
    final hits = <UiHitRegion>[];
    final visibleDeviceIds = <String>[];

    if (state.detailOpen) {
      final maxOffset = _renderDetail(
        snapshot: snapshot,
        state: state,
        width: safeWidth,
        height: safeHeight,
        lines: lines,
        hits: hits,
      );
      _overlayModal(snapshot, state, safeWidth, safeHeight, lines);
      return _finish(
        lines: lines,
        width: safeWidth,
        height: safeHeight,
        mode: mode,
        hits: hits,
        visibleDeviceIds: visibleDeviceIds,
        maxScrollOffset: maxOffset,
        theme: theme,
        color: color,
      );
    }

    final header = _headerLines(snapshot, safeWidth);
    final actions = _actions(snapshot, state);
    final maxActionRows = _maxActionRows(safeHeight);
    var actionRows = _actionRows(actions, state, safeWidth);
    var commandPageCount = 1;
    var commandPagerReservedWidth = 0;
    if (actionRows.length > maxActionRows) {
      // Reserve a small, always-visible pager so mouse users can reach the
      // actions that do not fit in a short terminal. Keyboard users cross a
      // page boundary with Left/Right from the first or last action.
      commandPagerReservedWidth = _commandPagerReservedWidthFor(safeWidth);
      final commandContentWidth =
          (safeWidth - commandPagerReservedWidth).clamp(1, safeWidth).toInt();
      actionRows = _actionRows(actions, state, commandContentWidth);
      commandPageCount =
          ((actionRows.length + maxActionRows - 1) ~/ maxActionRows)
              .clamp(1, 999);
    }
    final commandPage =
        state.commandPage.clamp(0, commandPageCount - 1).toInt();
    state.commandPage = commandPage;
    final visibleActionRows = actionRows
        .skip(commandPage * maxActionRows)
        .take(maxActionRows)
        .toList();
    final statusRows =
        safeHeight - header.length - visibleActionRows.length >= 2 ? 1 : 0;
    final contentRows =
        (safeHeight - header.length - visibleActionRows.length - statusRows)
            .clamp(0, safeHeight)
            .toInt();

    lines.addAll(header);
    final dashboard = _dashboardBudget(
      snapshot: snapshot,
      contentRows: contentRows,
      mode: mode,
      width: safeWidth,
    );
    final browser = _browserPanel(
      snapshot: snapshot,
      state: state,
      width: dashboard.browserWidth,
      rows: dashboard.browserRows,
    );
    visibleDeviceIds.addAll(browser.visibleDeviceIds);

    if (mode == UiLayoutMode.wide) {
      _appendWideDashboard(
        lines: lines,
        hits: hits,
        browser: browser,
        inspector: _inspectorLines(snapshot, state, dashboard.inspectorWidth),
        width: safeWidth,
        leftWidth: dashboard.browserWidth,
        rows: dashboard.dashboardRows,
      );
    } else {
      _appendStackedDashboard(
        lines: lines,
        hits: hits,
        browser: browser,
        inspector: _inspectorLines(snapshot, state, safeWidth),
        width: safeWidth,
        browserRows: dashboard.browserRows,
        inspectorRows: dashboard.inspectorRows,
      );
    }

    _appendActivity(
      lines: lines,
      state: state,
      width: safeWidth,
      rows: dashboard.activityRows,
    );
    if (dashboard.installRows > 0) {
      _appendInstall(
        lines: lines,
        snapshot: snapshot,
        width: safeWidth,
        rows: dashboard.installRows,
      );
    }

    final footerStart = safeHeight - visibleActionRows.length - statusRows;
    while (lines.length < footerStart) {
      lines.add(const _Line(''));
    }
    final visibleActionNames = _appendCommandBar(
      lines: lines,
      hits: hits,
      rows: visibleActionRows,
      width: safeWidth,
      commandPage: commandPage,
      commandPageCount: commandPageCount,
      showCommandPager: commandPagerReservedWidth > 0 ||
          (safeWidth == 1 && commandPageCount > 1),
    );
    if (statusRows > 0 && lines.length < safeHeight) {
      lines.add(_Line(
        _statusMessage(snapshot),
        snapshot.error == null ? UiTone.muted : UiTone.error,
      ));
    }

    _overlayModal(snapshot, state, safeWidth, safeHeight, lines);
    return _finish(
      lines: lines,
      width: safeWidth,
      height: safeHeight,
      mode: mode,
      hits: hits,
      visibleDeviceIds: visibleDeviceIds,
      maxScrollOffset: browser.maxScrollOffset,
      visibleCommandActionNames: visibleActionNames,
      commandPage: commandPage,
      commandPageCount: commandPageCount,
      theme: theme,
      color: color,
    );
  }

  List<_Line> _headerLines(UiSnapshot snapshot, int width) {
    final scan = snapshot.scanning ? '● 扫描中' : '○ 扫描停止';
    final count = snapshot.devices.length.toString() + ' 台设备';
    return <_Line>[
      _Line(' WRISTLOAD  /  macOS  ' + scan + '  ' + count, UiTone.primary),
      _Line(
        ' ' +
            _connectionSummary(snapshot.connectionPhase) +
            '  ·  自动连接: ' +
            _autoConnect(snapshot.autoConnectState),
        UiTone.muted,
      ),
      _Line('─' * width, UiTone.primary),
    ];
  }

  _DashboardBudget _dashboardBudget({
    required UiSnapshot snapshot,
    required int contentRows,
    required UiLayoutMode mode,
    required int width,
  }) {
    if (contentRows <= 0) {
      return const _DashboardBudget(
        dashboardRows: 0,
        browserRows: 0,
        inspectorRows: 0,
        activityRows: 0,
        installRows: 0,
        browserWidth: 1,
        inspectorWidth: 1,
      );
    }

    final installationActive = snapshot.install.phase != UiInstallPhase.idle;
    var installRows = 0;
    if (installationActive && contentRows >= 7) {
      installRows = contentRows >= 15 ? 5 : 3;
    }
    var activityRows = contentRows >= 5 ? (contentRows >= 14 ? 4 : 2) : 0;
    var dashboardRows = contentRows - installRows - activityRows;
    if (dashboardRows < 2 && activityRows > 0) {
      activityRows = 0;
      dashboardRows = contentRows - installRows;
    }
    if (dashboardRows < 2 && installRows > 0) {
      installRows = 0;
      dashboardRows = contentRows;
    }

    if (mode == UiLayoutMode.wide) {
      // The separator is a real terminal cell; both panels get independent,
      // wrap-aware widths and recompute on every render/resize.
      final browserWidth = (width * 42 ~/ 100).clamp(36, 58).toInt();
      return _DashboardBudget(
        dashboardRows: dashboardRows,
        browserRows: dashboardRows,
        inspectorRows: dashboardRows,
        activityRows: activityRows,
        installRows: installRows,
        browserWidth: browserWidth,
        inspectorWidth: width - browserWidth - 1,
      );
    }

    if (dashboardRows <= 2) {
      return _DashboardBudget(
        dashboardRows: dashboardRows,
        browserRows: dashboardRows,
        inspectorRows: 0,
        activityRows: activityRows,
        installRows: installRows,
        browserWidth: width,
        inspectorWidth: width,
      );
    }
    final desiredInspector = dashboardRows >= 10
        ? 8
        : dashboardRows >= 6
            ? 3
            : 2;
    final inspectorRows = desiredInspector.clamp(1, dashboardRows - 2).toInt();
    return _DashboardBudget(
      dashboardRows: dashboardRows,
      browserRows: dashboardRows - inspectorRows,
      inspectorRows: inspectorRows,
      activityRows: activityRows,
      installRows: installRows,
      browserWidth: width,
      inspectorWidth: width,
    );
  }

  _BrowserPanel _browserPanel({
    required UiSnapshot snapshot,
    required UiNextState state,
    required int width,
    required int rows,
  }) {
    if (rows <= 0) {
      return const _BrowserPanel(
        lines: [],
        visibleDeviceIds: [],
        maxScrollOffset: 0,
      );
    }
    final actualWidth = width <= 1 ? 1 : width;
    final lines = <_PanelLine>[
      const _PanelLine(' DEVICES', tone: UiTone.primary)
    ];
    final visible = <String>[];
    final maxOffset =
        snapshot.devices.isEmpty ? 0 : snapshot.devices.length - 1;
    state.scrollOffset = state.scrollOffset.clamp(0, maxOffset).toInt();
    final bodyRows = rows - 1;
    if (bodyRows <= 0) {
      return _BrowserPanel(
        lines: lines,
        visibleDeviceIds: visible,
        maxScrollOffset: maxOffset,
      );
    }
    if (snapshot.devices.isEmpty) {
      final empty = snapshot.scanning ? ' 正在搜索设备…' : ' 没有设备，按 r 开始扫描';
      for (final line in _wrapCells(empty, actualWidth, continuationIndent: 2)
          .take(bodyRows)) {
        lines.add(_PanelLine(line, tone: UiTone.muted));
      }
      return _BrowserPanel(
        lines: lines,
        visibleDeviceIds: visible,
        maxScrollOffset: maxOffset,
      );
    }

    var used = 0;
    for (var index = state.scrollOffset;
        index < snapshot.devices.length && used < bodyRows;
        index++) {
      final device = snapshot.devices[index];
      final block = _browserDeviceBlock(device, actualWidth);
      final remaining = bodyRows - used;
      if (used > 0 && block.length > remaining) break;
      final take = block.take(remaining).toList();
      if (take.isEmpty) break;
      final selected = state.selectedDeviceId == device.id;
      for (final line in take) {
        lines.add(_PanelLine(
          selected ? _selectedLine(line) : line,
          deviceId: device.id,
          selected: selected,
          tone: selected ? UiTone.selection : UiTone.normal,
        ));
      }
      visible.add(device.id);
      used += take.length;
    }
    while (lines.length < rows) {
      lines.add(const _PanelLine(''));
    }
    return _BrowserPanel(
      lines: lines,
      visibleDeviceIds: visible,
      maxScrollOffset: maxOffset,
    );
  }

  List<String> _browserDeviceBlock(UiDevice device, int width) {
    final marker = device.connected
        ? '●'
        : device.saved
            ? '◆'
            : '○';
    final status = device.connected
        ? 'READY'
        : device.saved
            ? 'SAVED'
            : _support(device.support);
    return <String>[
      ..._wrapCells(' ' + marker + ' ' + device.name, width,
          continuationIndent: 3),
      ..._wrapCells('   ' + device.macAddress + '  ' + status, width,
          continuationIndent: 3),
    ];
  }

  List<_PanelLine> _inspectorLines(
    UiSnapshot snapshot,
    UiNextState state,
    int width,
  ) {
    final actualWidth = width <= 1 ? 1 : width;
    final device = _selected(snapshot, state);
    final lines = <_PanelLine>[
      const _PanelLine(' DEVICE / CONNECTION', tone: UiTone.primary),
    ];
    if (device == null) {
      lines.addAll(
          _wrapCells(' 选择设备以查看连接信息', actualWidth, continuationIndent: 2)
              .map((line) => _PanelLine(line, tone: UiTone.muted)));
      return lines;
    }
    void add(String label, String value) {
      lines.addAll(
          _wrapCells(' ' + label + value, actualWidth, continuationIndent: 3)
              .map(_PanelLine.new));
    }

    add('名称: ', device.name);
    add('MAC: ', device.macAddress);
    add('支持: ', _support(device.support));
    add('保存: ', device.saved ? '是' : '否');
    add('authkey: ', device.authKeyLabel);
    lines.add(_PanelLine(
      ' CONNECTION  ' + _connectionSummary(snapshot.connectionPhase),
      tone: _connectionTone(snapshot.connectionPhase),
    ));
    lines.add(const _PanelLine(' PIPELINE · 细节未报告', tone: UiTone.muted));
    for (final stage in const <String>[
      'Identity',
      'Pairing',
      'SDP',
      'RFCOMM',
      'L1',
      'f=26',
      'f=27',
    ]) {
      lines.add(_PanelLine(' ' + stage + '  - 未报告', tone: UiTone.muted));
    }
    lines.add(_PanelLine(
      snapshot.connectionPhase == UiConnectionPhase.ready
          ? ' Session  ✓ READY'
          : ' Session  - 未报告',
      tone: snapshot.connectionPhase == UiConnectionPhase.ready
          ? UiTone.success
          : UiTone.muted,
    ));
    return lines;
  }

  void _appendWideDashboard({
    required List<_Line> lines,
    required List<UiHitRegion> hits,
    required _BrowserPanel browser,
    required List<_PanelLine> inspector,
    required int width,
    required int leftWidth,
    required int rows,
  }) {
    if (rows <= 0) return;
    final panelStart = lines.length;
    final safeLeft = leftWidth.clamp(18, width - 19).toInt();
    final rightWidth = width - safeLeft - 1;
    for (var index = 0; index < rows; index++) {
      final left = index < browser.lines.length
          ? browser.lines[index]
          : const _PanelLine('');
      final right =
          index < inspector.length ? inspector[index] : const _PanelLine('');
      final row = lines.length + 1;
      final text =
          _fit(left.text, safeLeft) + '│' + _fit(right.text, rightWidth);
      lines.add(_Line(
        text,
        left.selected
            ? UiTone.selection
            : index == 0
                ? UiTone.primary
                : left.tone,
      ));
      if (left.deviceId != null) {
        hits.add(UiHitRegion(
          rect: UiRect(1, row, safeLeft, row),
          action: UiHitAction.device,
          deviceId: left.deviceId,
        ));
      }
    }
    while (lines.length < panelStart + rows) {
      lines.add(const _Line(''));
    }
  }

  void _appendStackedDashboard({
    required List<_Line> lines,
    required List<UiHitRegion> hits,
    required _BrowserPanel browser,
    required List<_PanelLine> inspector,
    required int width,
    required int browserRows,
    required int inspectorRows,
  }) {
    for (var index = 0;
        index < browserRows && index < browser.lines.length;
        index++) {
      final item = browser.lines[index];
      final row = lines.length + 1;
      lines.add(_Line(item.text, item.selected ? UiTone.selection : item.tone));
      if (item.deviceId != null) {
        hits.add(UiHitRegion(
          rect: UiRect(1, row, width, row),
          action: UiHitAction.device,
          deviceId: item.deviceId,
        ));
      }
    }
    for (var index = 0;
        index < inspectorRows && index < inspector.length;
        index++) {
      final item = inspector[index];
      lines.add(_Line(item.text, item.tone));
    }
  }

  void _appendActivity({
    required List<_Line> lines,
    required UiNextState state,
    required int width,
    required int rows,
  }) {
    if (rows <= 0) return;
    final panelStart = lines.length;
    lines.add(const _Line(' ACTIVITY', UiTone.primary));
    if (rows > 1) {
      final entries = state.recentActivity;
      if (entries.isEmpty) {
        lines.add(_Line(' 等待操作或状态更新', UiTone.muted));
      } else {
        var remaining = rows - 1;
        for (final entry in entries) {
          if (remaining <= 0) break;
          final wrapped = _wrapCells(
            ' ' + entry.category + '  ' + entry.message,
            width,
            continuationIndent: 2,
          );
          for (final line in wrapped.take(remaining)) {
            lines.add(_Line(line, entry.isError ? UiTone.error : UiTone.muted));
            remaining--;
          }
        }
      }
    }
    while (lines.length < panelStart + rows) {
      lines.add(const _Line(''));
    }
  }

  void _appendInstall({
    required List<_Line> lines,
    required UiSnapshot snapshot,
    required int width,
    required int rows,
  }) {
    if (rows <= 0) return;
    final panelStart = lines.length;
    final install = snapshot.install;
    final panel = <_Line>[const _Line(' INSTALL', UiTone.primary)];
    panel.addAll(_wrapCells(' ' + (install.fileName ?? '资源'), width,
            continuationIndent: 2)
        .map(_Line.new));
    panel.add(_Line(' ' + _installPhaseLabel(install), _installTone(install)));
    if (install.totalBytes > 0) {
      panel.add(_Line(
        ' ' +
            install.confirmedBytes.toString() +
            ' / ' +
            install.totalBytes.toString() +
            ' bytes  ' +
            install.percent.toString() +
            '%',
        UiTone.muted,
      ));
    }
    final message = install.message;
    if (message != null && message.trim().isNotEmpty) {
      panel.addAll(_wrapCells(' ' + message, width, continuationIndent: 2)
          .map((line) => _Line(line, UiTone.muted)));
    }
    for (final line in panel.take(rows)) {
      lines.add(line);
    }
    while (lines.length < panelStart + rows) {
      lines.add(const _Line(''));
    }
  }

  List<String> _appendCommandBar({
    required List<_Line> lines,
    required List<UiHitRegion> hits,
    required List<List<_CommandDisplay>> rows,
    required int width,
    required int commandPage,
    required int commandPageCount,
    required bool showCommandPager,
  }) {
    final names = <String>[];
    for (final actions in rows) {
      final row = lines.length + 1;
      final compactPager = showCommandPager &&
          commandPageCount > 1 &&
          width < _commandPagerFullMinimumWidth;
      final buffer = StringBuffer(compactPager ? '' : ' ');
      var column = compactPager ? 1 : 2;
      var hasPreviousAction = false;
      if (showCommandPager && commandPageCount > 1) {
        if (compactPager) {
          final isFirstPage = commandPage == 0;
          final isLastPage = commandPage == commandPageCount - 1;
          if (width >= 3) {
            if (isFirstPage) {
              buffer.write(' >');
              hits.add(UiHitRegion(
                rect: UiRect(2, row, 2, row),
                action: UiHitAction.nextCommandPage,
              ));
            } else if (isLastPage) {
              buffer.write('< ');
              hits.add(UiHitRegion(
                rect: UiRect(1, row, 1, row),
                action: UiHitAction.previousCommandPage,
              ));
            } else {
              buffer.write('<>');
              hits.add(UiHitRegion(
                rect: UiRect(1, row, 1, row),
                action: UiHitAction.previousCommandPage,
              ));
              hits.add(UiHitRegion(
                rect: UiRect(2, row, 2, row),
                action: UiHitAction.nextCommandPage,
              ));
            }
            column = 3;
          } else {
            // At one or two cells, reserve the only visible control for a
            // direction that still makes every page mouse-reachable. The
            // last page exposes the return direction; keyboard keeps its
            // usual bidirectional Left/Right behavior at every width.
            final showNext = !isLastPage;
            buffer.write(showNext ? '>' : '<');
            hits.add(UiHitRegion(
              rect: UiRect(1, row, 1, row),
              action: showNext
                  ? UiHitAction.nextCommandPage
                  : UiHitAction.previousCommandPage,
            ));
            column = 2;
          }
        } else {
          final pager = '<' +
              (commandPage + 1).toString() +
              '/' +
              commandPageCount.toString() +
              '>';
          final previousColumn = column;
          buffer.write(pager);
          column += UiCellWidth.of(pager);
          final nextColumn = column - 1;
          buffer.write(' ');
          column++;
          if (previousColumn <= width) {
            hits.add(UiHitRegion(
              rect: UiRect(previousColumn, row, previousColumn, row),
              action: UiHitAction.previousCommandPage,
            ));
          }
          if (nextColumn <= width) {
            hits.add(UiHitRegion(
              rect: UiRect(nextColumn, row, nextColumn, row),
              action: UiHitAction.nextCommandPage,
            ));
          }
        }
      }
      for (final action in actions) {
        if (hasPreviousAction) {
          buffer.write('  ');
          column += 2;
        }
        final start = column;
        buffer.write(action.label);
        final actionWidth = UiCellWidth.of(action.label);
        column += actionWidth;
        names.add(action.action.name);
        if (start <= width) {
          hits.add(UiHitRegion(
            rect: UiRect(
              start,
              row,
              (column - 1).clamp(start, width).toInt(),
              row,
            ),
            action: action.action,
            isCommandAction: true,
          ));
        }
        hasPreviousAction = true;
      }
      lines.add(_Line(buffer.toString(), UiTone.primary));
    }
    return names;
  }

  List<_CommandAction> _actions(
    UiSnapshot snapshot,
    UiNextState state,
  ) {
    final selected = _selected(snapshot, state);
    final canConnect = selected != null &&
        (snapshot.connectionPhase == UiConnectionPhase.disconnected ||
            snapshot.connectionPhase == UiConnectionPhase.failed);
    final canDisconnect = switch (snapshot.connectionPhase) {
      UiConnectionPhase.connecting ||
      UiConnectionPhase.awaitingAuthKey ||
      UiConnectionPhase.authenticating ||
      UiConnectionPhase.ready =>
        true,
      UiConnectionPhase.disconnected ||
      UiConnectionPhase.disconnecting ||
      UiConnectionPhase.failed =>
        false,
    };
    return <_CommandAction>[
      if (canConnect) const _CommandAction('[Enter/c]连接', UiHitAction.connect),
      if (canDisconnect)
        const _CommandAction('[Enter/x]断开', UiHitAction.disconnect),
      const _CommandAction('[r]扫描', UiHitAction.scan),
      const _CommandAction('[L]日志', UiHitAction.openLogs),
      if (canConnect && selected.isDirectedSessionTarget)
        const _CommandAction('[g]定向连接', UiHitAction.directedConnect),
      if (selected != null) ...[
        const _CommandAction('[i]安装', UiHitAction.install),
        _CommandAction(
          selected.saved ? '[s]取消保存' : '[s]保存',
          selected.saved ? UiHitAction.remove : UiHitAction.save,
        ),
        const _CommandAction('[a]密钥', UiHitAction.authKey),
      ],
      if (snapshot.install.phase != UiInstallPhase.idle)
        const _CommandAction('[z]取消安装', UiHitAction.cancelInstall),
      _CommandAction(
        snapshot.autoConnect ? '[t]自动:开' : '[t]自动:关',
        UiHitAction.autoConnect,
      ),
      const _CommandAction('[m]主题', UiHitAction.theme),
      if (selected != null)
        const _CommandAction('[d/Tab]详情', UiHitAction.details),
    ];
  }

  List<List<_CommandDisplay>> _actionRows(
    List<_CommandAction> actions,
    UiNextState state,
    int width,
  ) {
    final rows = <List<_CommandDisplay>>[];
    var row = <_CommandDisplay>[];
    var used = 1;
    final labelLimit = (width - 1).clamp(1, width).toInt();
    for (final action in actions) {
      final focused = state.commandBarFocused &&
          state.focusedActionName == action.action.name;
      final label = _commandDisplayLabel(
        action: action,
        focused: focused,
        labelLimit: labelLimit,
      );
      final item = _CommandDisplay(label, action.action);
      final needed = UiCellWidth.of(label) + (row.isEmpty ? 0 : 2);
      if (row.isNotEmpty && used + needed > width) {
        rows.add(row);
        row = <_CommandDisplay>[];
        used = 1;
      }
      row.add(item);
      used += UiCellWidth.of(label) + (row.length == 1 ? 0 : 2);
    }
    if (row.isNotEmpty) rows.add(row);
    return rows;
  }

  int _maxActionRows(int height) {
    if (height >= 22) return 3;
    if (height >= 13) return 2;
    return 1;
  }

  static const int _commandPagerFullMinimumWidth = 10;
  static const int _commandPagerFullReservedWidth = 10;

  int _commandPagerReservedWidthFor(int width) {
    if (width >= _commandPagerFullMinimumWidth) {
      return _commandPagerFullReservedWidth;
    }
    if (width >= 3) return 2;
    if (width >= 2) return 1;
    return 0;
  }

  String _commandDisplayLabel({
    required _CommandAction action,
    required bool focused,
    required int labelLimit,
  }) {
    if (labelLimit < 8) {
      final key = _compactCommandKey(action.action);
      if (labelLimit <= 1) return key;
      if (labelLimit == 2) return focused ? '>' + key : ' ' + key;
      if (labelLimit < 5) return focused ? '>' + key + '<' : '[' + key + ']';
      return focused ? '>[' + key + ']<' : '[' + key + ']';
    }
    final decorated =
        focused ? '> ' + action.label + ' <' : '  ' + action.label + '  ';
    return _truncate(decorated, labelLimit);
  }

  String _compactCommandKey(UiHitAction action) => switch (action) {
        UiHitAction.device => '?',
        UiHitAction.scan => 'r',
        UiHitAction.connect => 'c',
        UiHitAction.directedConnect => 'g',
        UiHitAction.disconnect => 'x',
        UiHitAction.details => 'd',
        UiHitAction.save || UiHitAction.remove => 's',
        UiHitAction.authKey => 'a',
        UiHitAction.install => 'i',
        UiHitAction.cancelInstall => 'z',
        UiHitAction.autoConnect => 't',
        UiHitAction.theme => 'm',
        UiHitAction.openLogs => 'L',
        UiHitAction.previousCommandPage || UiHitAction.nextCommandPage => '?',
      };

  int _renderDetail({
    required UiSnapshot snapshot,
    required UiNextState state,
    required int width,
    required int height,
    required List<_Line> lines,
    required List<UiHitRegion> hits,
  }) {
    lines.add(_Line(' WRISTLOAD  /  DEVICE DETAIL', UiTone.primary));
    final device = _selected(snapshot, state);
    final body = <_Line>[];
    if (device == null) {
      body.add(const _Line(' 没有选中的设备', UiTone.muted));
    } else {
      void add(String label, String value) {
        body.addAll(
            _wrapCells(' ' + label + value, width, continuationIndent: 3)
                .map(_Line.new));
      }

      body.add(const _Line(' DEVICE', UiTone.primary));
      add('名称: ', device.name);
      add('MAC: ', device.macAddress);
      add('支持: ', _support(device.support));
      add('authkey: ', device.authKeyLabel);
      add('保存: ', device.saved ? '是' : '否');
    }
    final footerRows = height >= 2 ? 1 : 0;
    final available =
        (height - lines.length - footerRows).clamp(0, height).toInt();
    final maxOffset = (body.length - available).clamp(0, body.length).toInt();
    state.scrollOffset = state.scrollOffset.clamp(0, maxOffset).toInt();
    lines.addAll(body.skip(state.scrollOffset).take(available));
    while (lines.length < height - footerRows) {
      lines.add(const _Line(''));
    }
    if (footerRows > 0) {
      const label = '[d/Tab/Esc] 返回设备列表  [L]日志';
      final row = lines.length + 1;
      lines.add(const _Line(label, UiTone.primary));
      final detailWidth = UiCellWidth.of('[d/Tab/Esc] 返回设备列表');
      hits.add(UiHitRegion(
        rect: UiRect(1, row, detailWidth.clamp(1, width).toInt(), row),
        action: UiHitAction.details,
      ));
      final logsStart = detailWidth + 3;
      if (logsStart <= width) {
        hits.add(UiHitRegion(
          rect: UiRect(
            logsStart,
            row,
            (logsStart + UiCellWidth.of('[L]日志') - 1)
                .clamp(logsStart, width)
                .toInt(),
            row,
          ),
          action: UiHitAction.openLogs,
        ));
      }
    }
    return maxOffset;
  }

  void _overlayModal(
    UiSnapshot snapshot,
    UiNextState state,
    int width,
    int height,
    List<_Line> lines,
  ) {
    if (state.modal == null || height <= 0) return;
    while (lines.length < height) {
      lines.add(const _Line(''));
    }
    final targetId = state.modalTargetDeviceId ?? state.selectedDeviceId;
    UiDevice? target;
    for (final device in snapshot.devices) {
      if (device.id == targetId) {
        target = device;
        break;
      }
    }
    final isAuthKey = state.modal == UiModal.authKey;
    final title = isAuthKey ? ' AUTHKEY / CONNECT TO' : ' INSTALL / TARGET';
    final targetName = target?.name ?? targetId ?? '未选择设备';
    final targetMac = target?.macAddress ?? targetId ?? '-';
    final input = isAuthKey ? ('*' * state.input.length) : state.input;
    final modal = <_Line>[
      _Line(title, UiTone.selection),
      ..._wrapCells(' ' + targetName, width, continuationIndent: 2)
          .map((line) => _Line(line, UiTone.selection)),
      _Line(' MAC: ' + targetMac, UiTone.selection),
      _Line((isAuthKey ? ' authkey: ' : ' path: ') + input + '█',
          UiTone.selection),
      const _Line(' Enter 确认  ·  Esc 取消', UiTone.primary),
    ];
    final visible = modal.take(height).toList();
    final start = height - visible.length;
    for (var index = 0; index < visible.length; index++) {
      lines[start + index] = visible[index];
    }
  }

  UiLayoutResult _finish({
    required List<_Line> lines,
    required int width,
    required int height,
    required UiLayoutMode mode,
    required List<UiHitRegion> hits,
    required List<String> visibleDeviceIds,
    required int maxScrollOffset,
    List<String> visibleCommandActionNames = const [],
    int commandPage = 0,
    int commandPageCount = 1,
    required UiTheme theme,
    required bool color,
  }) {
    while (lines.length < height) {
      lines.add(const _Line(''));
    }
    final text = lines
        .take(height)
        .map((line) => theme.paint(
              _fit(line.text, width),
              line.tone,
              enabled: color,
            ))
        .join('\n');
    return UiLayoutResult(
      text: text + '\n',
      mode: mode,
      hitRegions: hits,
      visibleDeviceIds: visibleDeviceIds,
      maxScrollOffset: maxScrollOffset,
      visibleCommandActionNames: visibleCommandActionNames,
      commandPage: commandPage,
      commandPageCount: commandPageCount,
    );
  }

  UiDevice? _selected(UiSnapshot snapshot, UiNextState state) {
    for (final device in snapshot.devices) {
      if (device.id == state.selectedDeviceId) return device;
    }
    return null;
  }

  String _connectionSummary(UiConnectionPhase phase) => switch (phase) {
        UiConnectionPhase.disconnected => '○ 未连接',
        UiConnectionPhase.connecting => '● 连接中',
        UiConnectionPhase.awaitingAuthKey => '● 等待 authkey',
        UiConnectionPhase.authenticating => '● 鉴权中',
        UiConnectionPhase.ready => '✓ Session READY',
        UiConnectionPhase.disconnecting => '● 正在断开',
        UiConnectionPhase.failed => '✕ 连接失败',
      };

  UiTone _connectionTone(UiConnectionPhase phase) => switch (phase) {
        UiConnectionPhase.ready => UiTone.success,
        UiConnectionPhase.failed => UiTone.error,
        UiConnectionPhase.connecting ||
        UiConnectionPhase.awaitingAuthKey ||
        UiConnectionPhase.authenticating ||
        UiConnectionPhase.disconnecting =>
          UiTone.primary,
        UiConnectionPhase.disconnected => UiTone.muted,
      };

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

  String _installPhaseLabel(UiInstallStatus install) => switch (install.phase) {
        UiInstallPhase.idle => '空闲',
        UiInstallPhase.preparing => '● 正在准备',
        UiInstallPhase.transferring => '● 正在传输',
        UiInstallPhase.awaitingDevice => '● 等待设备业务结果',
        UiInstallPhase.succeeded
            when install.successVerifiedByDeviceBusinessEvent =>
          '✓ 设备确认安装成功',
        UiInstallPhase.succeeded => '● 等待设备安装结果',
        UiInstallPhase.failed => '✕ 安装失败',
        UiInstallPhase.unknown => '○ 设备安装结果未知',
      };

  UiTone _installTone(UiInstallStatus install) => switch (install.phase) {
        UiInstallPhase.succeeded
            when install.successVerifiedByDeviceBusinessEvent =>
          UiTone.success,
        UiInstallPhase.failed => UiTone.error,
        UiInstallPhase.preparing ||
        UiInstallPhase.transferring ||
        UiInstallPhase.awaitingDevice ||
        UiInstallPhase.succeeded =>
          UiTone.primary,
        UiInstallPhase.idle || UiInstallPhase.unknown => UiTone.muted,
      };

  String _statusMessage(UiSnapshot snapshot) {
    final message =
        snapshot.error ?? snapshot.notice ?? _installNotice(snapshot.install);
    return message == null || message.trim().isEmpty
        ? ' ↑↓ 选择  ·  ←→ 操作  ·  Enter 执行  ·  q 退出'
        : ' ' + message;
  }

  String? _installNotice(UiInstallStatus install) => switch (install.phase) {
        UiInstallPhase.idle => null,
        UiInstallPhase.preparing => '正在准备 ' + (install.fileName ?? '资源'),
        UiInstallPhase.transferring => '正在传输 ' +
            (install.fileName ?? '资源') +
            ' ' +
            install.percent.toString() +
            '%',
        UiInstallPhase.awaitingDevice => '传输完成，等待设备业务结果',
        UiInstallPhase.succeeded
            when install.successVerifiedByDeviceBusinessEvent =>
          '设备确认安装成功',
        UiInstallPhase.succeeded => '等待设备安装结果',
        UiInstallPhase.failed => install.message ?? '安装失败',
        UiInstallPhase.unknown => install.message ?? '设备安装结果未知',
      };

  String _fit(String value, int width) {
    final sanitized = UiCellWidth.sanitizeText(value);
    final actual = UiCellWidth.of(sanitized);
    if (actual <= width) return sanitized + (' ' * (width - actual));
    return UiCellWidth.takePrefix(sanitized, width).text;
  }

  String _truncate(String value, int width) {
    final sanitized = UiCellWidth.sanitizeText(value);
    if (UiCellWidth.of(sanitized) <= width) return sanitized;
    return UiCellWidth.takePrefix(sanitized, width).text;
  }

  List<String> _wrapCells(
    String value,
    int width, {
    int continuationIndent = 0,
  }) {
    if (width <= 0) return const [''];
    var remaining = UiCellWidth.sanitizeText(value);
    final result = <String>[];
    while (remaining.isNotEmpty) {
      final requestedIndent = result.isEmpty ? 0 : continuationIndent;
      var indent = requestedIndent.clamp(0, width - 1).toInt();
      final firstWidth = UiCellWidth.firstGraphemeWidth(remaining);
      if (firstWidth > width - indent && firstWidth <= width) {
        indent = width - firstWidth;
      }
      final prefix = ' ' * indent;
      final part = UiCellWidth.takePrefix(remaining, width - indent);
      result.add(_fit(prefix + part.text, width));
      if (part.consumedCodeUnits == 0) break;
      remaining = remaining.substring(part.consumedCodeUnits);
    }
    return result.isEmpty ? <String>[_fit('', width)] : result;
  }

  String _selectedLine(String line) {
    if (UiCellWidth.of(line) <= 2) return line;
    final source = line.length >= 2 ? line.substring(2) : '';
    return '› ' + source;
  }
}

final class _DashboardBudget {
  const _DashboardBudget({
    required this.dashboardRows,
    required this.browserRows,
    required this.inspectorRows,
    required this.activityRows,
    required this.installRows,
    required this.browserWidth,
    required this.inspectorWidth,
  });

  final int dashboardRows;
  final int browserRows;
  final int inspectorRows;
  final int activityRows;
  final int installRows;
  final int browserWidth;
  final int inspectorWidth;
}
