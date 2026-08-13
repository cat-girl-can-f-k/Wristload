import 'dart:async';

import '../input/command.dart';
import '../input/dispatcher.dart';
import '../input/key_decoder.dart';
import '../input/key_event.dart';
import '../input/mapper.dart';
import '../port/tui_frontend_port.dart';
import '../port/tui_snapshot.dart';
import '../state/app_state.dart';
import '../terminal/cell_width.dart';
import '../terminal/terminal.dart';
import '../theme/ansi_text.dart';
import '../theme/tui_theme.dart';
import '../views/devices_view.dart';
import '../views/diagnostic_log_panel.dart';
import '../views/help_view.dart';
import '../views/logs_view.dart';
import '../views/queue_view.dart';
import '../views/settings_view.dart';
import '../views/task_view.dart';
import '../widgets/dialog.dart';
import '../widgets/frame.dart';
import '../widgets/input.dart';
import '../widgets/panel.dart';
import '../widgets/shortcuts_bar.dart';
import '../widgets/status_bar.dart';

/// Runs the macOS-only terminal workbench. The frontend consumes only the
/// atomic [TuiSnapshot] and dispatches user intent through [TuiFrontendPort].
class TuiApp {
  TuiApp({
    required Terminal terminal,
    required TuiFrontendPort port,
    required this.previewLabel,
    this.noticeDuration = const Duration(seconds: 4),
  })  : _terminal = terminal,
        _port = port;

  final Terminal _terminal;
  final TuiFrontendPort _port;
  final String previewLabel;
  final Duration noticeDuration;

  late final AppState _state = AppState();
  ActionDispatcher? _dispatcher;
  late final KeyDecoder _keyDecoder = KeyDecoder();
  final _mapper = const KeyMapper();
  StreamSubscription<TuiSnapshot>? _snapshotSub;
  StreamSubscription<List<int>>? _inputSub;
  StreamSubscription<void>? _resizeSub;
  StreamSubscription<KeyEvent>? _keyEventSub;
  final Completer<void> _exitSignal = Completer<void>();

  String _noticeMessage = '';
  bool _noticeIsError = false;
  Timer? _noticeTimer;
  Future<void>? _disposeFuture;
  bool _started = false;
  bool _terminalStarted = false;
  bool _running = false;

  TuiConnectionState? _lastConnectionState;
  String? _lastConnectionTarget;
  bool? _lastAuthKeyLoaded;
  String? _lastSnapshotNoticeId;

  Future<void> run() async {
    if (!_terminal.isInteractive) {
      throw StateError('wristload_tui requires an interactive terminal.');
    }
    if (_started || _disposeFuture != null) {
      throw StateError('TuiApp can only be run once.');
    }
    _started = true;
    _running = true;
    _dispatcher = ActionDispatcher(
      port: _port,
      state: _state,
      terminal: _terminal,
      onNotice: _showNotice,
    );

    try {
      _terminalStarted = true;
      _terminal.setAltBuffer(true);
      _terminal.setRawMode(true);
      _terminal.setCursorVisible(false);
      _terminal.clearScreen();

      _keyEventSub = _keyDecoder.events.listen(
        _handleDecodedKey,
        onError: _handleAsyncError,
      );
      _inputSub = _terminal.byteStream.listen(
        _handleInputBytes,
        onError: _handleAsyncError,
        onDone: _requestExit,
      );
      _resizeSub = _terminal.onResize.listen(
        (_) => _requestFrame(),
        onError: _handleAsyncError,
      );

      _reconcileSnapshot(_port.snapshot);
      _render();
      _snapshotSub = _port.snapshots.listen(
        _handleSnapshot,
        onError: _handleAsyncError,
        onDone: _requestExit,
      );

      unawaited(_initialize().catchError((Object error, StackTrace stack) {
        _handleAsyncError(error, stack);
      }));
      await _exitSignal.future;
    } finally {
      await dispose();
    }
  }

  Future<void> _initialize() async {
    final result = await _port.initialize();
    if (!_running) return;
    if (!result.accepted) _showNotice(result.message, isError: true);
    _requestFrame();
  }

  void _handleInputBytes(List<int> bytes) {
    if (!_running) return;
    try {
      _keyDecoder.addBytes(bytes);
    } on Object catch (error, stackTrace) {
      _handleAsyncError(error, stackTrace);
    }
  }

  void _handleDecodedKey(KeyEvent event) {
    if (!_running) return;
    unawaited(_onKeyEvent(event).catchError((Object error, StackTrace stack) {
      _handleAsyncError(error, stack);
    }));
  }

  void _handleSnapshot(TuiSnapshot snapshot) {
    if (!_running) return;
    _reconcileSnapshot(snapshot);
    _requestFrame();
  }

  void _reconcileSnapshot(TuiSnapshot snapshot) {
    final notice = snapshot.notice;
    if (notice == null) {
      _lastSnapshotNoticeId = null;
    } else if (notice.id != _lastSnapshotNoticeId) {
      _lastSnapshotNoticeId = notice.id;
      _showNotice(
        notice.message,
        isError: notice.severity == TuiDecisionSeverity.error,
      );
    }

    if (_state.selectedDeviceId != null &&
        !snapshot.devices.any(
            (device) => device.deviceId == _state.selectedDeviceId)) {
      _state.selectedDeviceId = null;
    }
    if (_state.selectedQueueItemId != null &&
        !snapshot.queue.any(
            (item) => item.itemId == _state.selectedQueueItemId)) {
      _state.selectedQueueItemId = null;
    }
    if (_state.activeDecisionId != null &&
        !snapshot.pendingDecisions.any(
            (decision) => decision.decisionId == _state.activeDecisionId)) {
      _state.clearDecision();
    }

    final connection = snapshot.connection;
    final target = connection.targetDeviceId ?? connection.targetAddress;
    final enteringAwaiting =
        connection.state == TuiConnectionState.awaitingAuthKey &&
            (_lastConnectionState != TuiConnectionState.awaitingAuthKey ||
                target != _lastConnectionTarget ||
                (_lastAuthKeyLoaded == true && !snapshot.authKeyLoaded));
    if (enteringAwaiting && !snapshot.authKeyLoaded) {
      _openAuthKeyPrompt();
    } else if (connection.state != TuiConnectionState.awaitingAuthKey &&
        _state.showAuthKey) {
      _closeAuthKeyPrompt();
    }
    _lastConnectionState = connection.state;
    _lastConnectionTarget = target;
    _lastAuthKeyLoaded = snapshot.authKeyLoaded;
  }

  void _openAuthKeyPrompt() {
    _state.showAuthKey = true;
    _state.modal = ModalKind.authKey;
    _state.authKeyInput = '';
    _state.authKeyVisible = false;
  }

  void _closeAuthKeyPrompt() {
    _state.showAuthKey = false;
    _state.authKeyInput = '';
    _state.authKeyVisible = false;
    if (_state.modal == ModalKind.authKey) _state.modal = null;
  }

  void _handleAsyncError(Object error, [StackTrace? stackTrace]) {
    if (!_running) return;
    _running = false;
    if (!_exitSignal.isCompleted) {
      _exitSignal.completeError(error, stackTrace ?? StackTrace.current);
    }
  }

  void _requestFrame() {
    if (!_running) return;
    try {
      _render();
    } on Object catch (error, stackTrace) {
      _handleAsyncError(error, stackTrace);
    }
  }

  void _render() {
    if (!_running) return;
    final snapshot = _port.snapshot;
    final width = _terminal.columns;
    final height = _terminal.rows;
    if (width < 60 || height < 20) {
      _renderTooSmall(width, height);
      return;
    }

    final wide = _isWide(width);
    _state.wideLayout = wide;
    final bodyHeight = (height - 5).clamp(1, height).toInt();
    final canvas = List<String>.filled(height, ' ' * width);
    canvas[0] = _brandLine(snapshot, width);
    canvas[1] = TuiTheme.paint(
      '─' * width,
      TuiTone.muted,
      supportsColor: _terminal.supportsColor,
    );

    final body = _renderBody(snapshot, width, bodyHeight, wide);
    for (var index = 0; index < body.length && index < bodyHeight; index++) {
      canvas[index + 2] = AnsiText.fit(body[index], width);
    }

    if (_noticeMessage.isNotEmpty) {
      final tone = _noticeIsError ? TuiTone.error : TuiTone.info;
      canvas[height - 3] = AnsiText.fit(
        TuiTheme.paint(
          '${_noticeIsError ? '×' : '›'} $_noticeMessage',
          tone,
          bold: true,
          supportsColor: _terminal.supportsColor,
        ),
        width,
      );
    }
    canvas[height - 2] = ShortcutsBar(
      width: width,
      supportsColor: _terminal.supportsColor,
    ).render(snapshot, _state);
    canvas[height - 1] = previewLabel.isEmpty
        ? TuiTheme.muted(
            'rev ${snapshot.revision}  ·  Ctrl+C 安全退出',
            supportsColor: _terminal.supportsColor,
          )
        : TuiTheme.muted(
            '[$previewLabel]  ·  rev ${snapshot.revision}',
            supportsColor: _terminal.supportsColor,
          );

    final overlay = _overlayRows(snapshot, width, height);
    if (overlay != null) _placeOverlay(canvas, overlay, width, height);

    _terminal.moveHome();
    _terminal.clearScreen();
    _terminal.write('${canvas.join('\n')}\n');
    _terminal.flush();
  }

  bool _isWide(int width) => width >= 116;

  String _brandLine(TuiSnapshot snapshot, int width) {
    final brand = TuiTheme.paint(
      ' WRISTLOAD ',
      TuiTone.accent,
      bold: true,
      supportsColor: _terminal.supportsColor,
    );
    final mode = TuiTheme.muted(
      '// MACOS OPS',
      supportsColor: _terminal.supportsColor,
    );
    final status = StatusBar(
      width: width,
      supportsColor: _terminal.supportsColor,
    ).render(snapshot);
    return AnsiText.truncate('$brand$mode   $status', width);
  }

  List<String> _renderBody(
    TuiSnapshot snapshot,
    int width,
    int height,
    bool wide,
  ) {
    final leftWidth = wide ? width - _rightWidth(width) - 1 : width;
    final left = _renderMainView(snapshot, leftWidth, height);
    if (!wide) return left;

    final rightWidth = width - leftWidth - 1;
    final right = _renderDiagnosticColumn(snapshot, rightWidth, height);
    final rows = <String>[];
    for (var index = 0; index < height; index++) {
      final leftLine = index < left.length ? left[index] : '';
      final rightLine = index < right.length ? right[index] : '';
      rows.add(
        '${AnsiText.fit(leftLine, leftWidth)}'
        '${TuiTheme.paint('│', TuiTone.muted, supportsColor: _terminal.supportsColor)}'
        '${AnsiText.fit(rightLine, rightWidth)}',
      );
    }
    return rows;
  }

  int _rightWidth(int width) =>
      (width * 0.34).round().clamp(44, 58).toInt();

  List<String> _renderMainView(
    TuiSnapshot snapshot,
    int width,
    int height,
  ) {
    final frame = Frame(width: width, height: height);
    switch (_state.currentView) {
      case View.devices:
        DevicesView(
          snapshot: snapshot,
          state: _state,
          frame: frame,
          supportsColor: _terminal.supportsColor,
        ).render();
      case View.queue:
        QueueView(
          snapshot: snapshot,
          state: _state,
          frame: frame,
          supportsColor: _terminal.supportsColor,
        ).render();
      case View.task:
        TaskView(
          snapshot: snapshot,
          state: _state,
          frame: frame,
          supportsColor: _terminal.supportsColor,
        ).render();
      case View.settings:
        SettingsView(
          snapshot: snapshot,
          state: _state,
          frame: frame,
          supportsColor: _terminal.supportsColor,
        ).render();
      case View.logs:
        LogsView(
          snapshot: snapshot,
          state: _state,
          frame: frame,
          supportsColor: _terminal.supportsColor,
        ).render();
    }
    return _frameRows(frame, height);
  }

  List<String> _renderDiagnosticColumn(
    TuiSnapshot snapshot,
    int width,
    int height,
  ) {
    final frame = Frame(width: width, height: height);
    final level = _state.logsFilter?.name ?? 'all';
    final category = _state.logsCategoryFilter?.name ?? 'all';
    frame.addRow(SectionHeader(
      width: width,
      eyebrow: 'LIVE LOG',
      title: '诊断流',
      meta: '${snapshot.logs.length} events',
      tone: TuiTone.info,
      supportsColor: _terminal.supportsColor,
    ).render());
    frame.addRow(AnsiText.truncate(
      '${_state.logsFollowTail ? '● FOLLOW' : '○ PAUSED'}  lvl=$level  cat=$category',
      width,
    ));
    final panelHeight = (height - 4).clamp(1, height).toInt();
    final logLines = DiagnosticLogPanel(
      entries: snapshot.logs,
      width: width - 2,
      height: panelHeight,
      levels: _state.logsFilter == null ? null : {_state.logsFilter!},
      categories: _state.logsCategoryFilter == null
          ? null
          : {_state.logsCategoryFilter!},
      followTail: _state.logsFollowTail,
      scrollOffset: _state.logsScrollOffset,
      ansi: TuiTheme.useColor(_terminal.supportsColor),
    ).render();
    frame.addRows(PanelWidget(
      width: width,
      title: 'EVENTS',
      lines: logLines,
      tone: _state.logsFollowTail ? TuiTone.success : TuiTone.warning,
      supportsColor: _terminal.supportsColor,
    ).render());
    return _frameRows(frame, height);
  }

  List<String> _frameRows(Frame frame, int height) {
    final rows = frame.rows.toList();
    while (rows.length < height) rows.add('');
    return rows.take(height).map((row) => AnsiText.fit(row, frame.width)).toList();
  }

  List<String>? _overlayRows(
    TuiSnapshot snapshot,
    int width,
    int height,
  ) {
    if (_state.modal == ModalKind.confirm && _state.onDialogConfirm != null) {
      return DialogWidget(
        width: width,
        title: _state.dialogTitle,
        message: _state.dialogMessage,
        confirmLabel: _state.dialogConfirmLabel,
        cancelLabel: _state.dialogCancelLabel,
        dangerous: _state.dialogDangerous,
        focusConfirm: _state.dialogFocusConfirm,
        supportsColor: _terminal.supportsColor,
      ).render();
    }
    if (_state.activeDecisionId != null) {
      final decision = snapshot.pendingDecisions
          .where((item) => item.decisionId == _state.activeDecisionId)
          .firstOrNull;
      if (decision != null) return _decisionRows(decision, width);
    }
    if (_state.showAuthKey) return _authKeyRows(snapshot, width);
    if (_state.showLogExport) return _logExportRows(width);
    if (_state.showHelp) return _helpRows(width, height);
    return null;
  }

  List<String> _authKeyRows(TuiSnapshot snapshot, int width) => DialogWidget(
        width: width,
        title: '首次连接 · 输入 authkey',
        message:
            '目标: ${snapshot.connection.targetDeviceName ?? snapshot.connection.targetAddress ?? '未知'}',
        lines: [
          InputWidget(
            width: (width - 12).clamp(20, width).toInt(),
            label: 'authkey',
            value: _state.authKeyInput,
            masked: !_state.authKeyVisible,
            focused: true,
            hint: '32 位十六进制字符',
            supportsColor: _terminal.supportsColor,
          ).render(),
          TuiTheme.muted(
            'Enter 提交 · Esc 取消 · v 显示/隐藏（只保留在进程内存）',
            supportsColor: _terminal.supportsColor,
          ),
        ],
        confirmLabel: '提交',
        cancelLabel: '取消',
        focusConfirm: true,
        supportsColor: _terminal.supportsColor,
      ).render();

  List<String> _logExportRows(int width) => DialogWidget(
        width: width,
        title: '导出安全日志',
        message: '只导出 facade 提供的脱敏诊断记录。',
        lines: [
          InputWidget(
            width: (width - 12).clamp(20, width).toInt(),
            label: '路径',
            value: _state.logExportPathInput,
            focused: true,
            hint: '/tmp/wristload_logs.txt',
            supportsColor: _terminal.supportsColor,
          ).render(),
          TuiTheme.muted(
            'Enter 导出 · Esc 取消',
            supportsColor: _terminal.supportsColor,
          ),
        ],
        confirmLabel: '导出',
        cancelLabel: '取消',
        focusConfirm: true,
        supportsColor: _terminal.supportsColor,
      ).render();

  List<String> _decisionRows(TuiPendingDecision decision, int width) {
    final lines = <String>[
      for (final fact in decision.facts) '• $fact',
    ];
    for (var index = 0; index < decision.inputFields.length; index++) {
      final field = decision.inputFields[index];
      lines.add(InputWidget(
        width: (width - 12).clamp(20, width).toInt(),
        label: field.label,
        value: _state.decisionValues[field.fieldId] ?? '',
        focused: index == _state.decisionFieldIndex,
        hint: field.format,
        supportsColor: _terminal.supportsColor,
      ).render());
    }
    lines.add(TuiTheme.muted(
      decision.inputFields.isEmpty
          ? 'y / Enter 确认 · Esc 取消'
          : 'Tab 切换输入 · y 确认 · Esc 取消',
      supportsColor: _terminal.supportsColor,
    ));
    return DialogWidget(
      width: width,
      title: decision.title,
      message: decision.message,
      lines: lines,
      confirmLabel: decision.confirmLabel,
      cancelLabel: decision.cancelLabel,
      dangerous: decision.severity != TuiDecisionSeverity.info,
      focusConfirm: _state.decisionFocusConfirm,
      supportsColor: _terminal.supportsColor,
    ).render();
  }

  List<String> _helpRows(int width, int height) {
    final dialogWidth = (width - 8).clamp(48, width).toInt();
    final helpFrame = Frame(width: dialogWidth, height: (height - 6).clamp(8, height).toInt());
    HelpView(frame: helpFrame, supportsColor: _terminal.supportsColor).render();
    return _frameRows(helpFrame, helpFrame.height);
  }

  void _placeOverlay(List<String> canvas, List<String> overlay, int width, int height) {
    final overlayWidth = overlay.fold<int>(0, (max, row) => max > CellWidth.of(row) ? max : CellWidth.of(row)).clamp(1, width).toInt();
    final top = ((height - overlay.length) / 2).floor().clamp(2, height - 1).toInt();
    final left = ((width - overlayWidth) / 2).floor().clamp(0, width - 1).toInt();
    for (var index = 0; index < overlay.length; index++) {
      final row = overlay[index];
      if (top + index >= height - 2) break;
      canvas[top + index] = AnsiText.fit('${' ' * left}$row', width);
    }
  }

  void _renderTooSmall(int width, int height) {
    _terminal.moveHome();
    _terminal.clearScreen();
    _terminal.writeLine('终端尺寸不足: ${width}×$height');
    _terminal.writeLine('需要至少 60 列 × 20 行。');
    _terminal.writeLine('按 q 退出。');
    _terminal.flush();
  }

  Future<void> _onKeyEvent(KeyEvent event) async {
    if (!_running) return;
    if (event is KeyPress && event.name == 'ctrl-c') {
      await _exit();
      return;
    }
    final command = _mapper.map(
      event,
      _state,
      KeyMapper.isTextInputFocused(_state),
    );
    if (command == null) return;
    if (command is QuitCommand) {
      if (_hasActiveOperation()) {
        _state.openConfirmation(
          title: '确认退出',
          message: '仍有操作进行中，退出可能留下设备状态未知。继续？',
          confirmLabel: '退出',
          dangerous: true,
          onConfirm: _exit,
        );
        _requestFrame();
        return;
      }
      await _exit();
      return;
    }
    if (command is CancelCommand) {
      if (_state.showAuthKey) _closeAuthKeyPrompt();
      _state.clearInputs();
      _requestFrame();
      return;
    }
    await _dispatcher?.dispatch(command);
    _requestFrame();
  }

  bool _hasActiveOperation() =>
      _port.snapshot.busyOperations.isNotEmpty ||
      _port.snapshot.activeTask != null;

  void _showNotice(String message, {bool isError = false}) {
    _noticeMessage = message;
    _noticeIsError = isError;
    _noticeTimer?.cancel();
    _noticeTimer = Timer(noticeDuration, () {
      _noticeMessage = '';
      _requestFrame();
    });
  }

  Future<void> _exit() async => _requestExit();

  void _requestExit() {
    _running = false;
    if (!_exitSignal.isCompleted) _exitSignal.complete();
  }

  Future<void> dispose() {
    _requestExit();
    return _disposeFuture ??= _cleanup();
  }

  Future<void> _cleanup() async {
    _running = false;
    _noticeTimer?.cancel();
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } on Object catch (error, stackTrace) {
        cleanupError ??= error;
        cleanupStackTrace ??= stackTrace;
      }
    }
    await attempt(() async => _snapshotSub?.cancel());
    await attempt(() async => _inputSub?.cancel());
    await attempt(() async => _resizeSub?.cancel());
    await attempt(() async => _keyEventSub?.cancel());
    await attempt(() => _dispatcher?.dispose());
    await attempt(_keyDecoder.close);
    if (_terminalStarted) {
      await attempt(() => _terminal.setCursorVisible(true));
      await attempt(() => _terminal.setRawMode(false));
      await attempt(() => _terminal.setAltBuffer(false));
      await attempt(_terminal.reset);
    }
    await attempt(_port.dispose);
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError as Object, cleanupStackTrace!);
    }
  }
}
