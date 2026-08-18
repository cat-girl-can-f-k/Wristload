import 'dart:async';

import 'input.dart';
import 'layout.dart';
import 'port.dart';
import 'state.dart';
import 'terminal.dart';

typedef UiLogViewerLauncher = Future<void> Function();

/// Terminal lifecycle and input router for the replacement frontend.
/// Native and Bluetooth work is confined behind [UiNextPort].
class UiNextShell {
  UiNextShell({
    required UiTerminal terminal,
    required UiNextPort port,
    UiNextRenderer renderer = const UiNextRenderer(),
    UiLogViewerLauncher? logViewerLauncher,
  })  : _terminal = terminal,
        _port = port,
        _renderer = renderer,
        _logViewerLauncher = logViewerLauncher;

  final UiTerminal _terminal;
  final UiNextPort _port;
  final UiNextRenderer _renderer;
  final UiLogViewerLauncher? _logViewerLauncher;
  final UiNextState state = UiNextState();
  final UiInputDecoder _decoder = UiInputDecoder();
  final Completer<void> _exit = Completer<void>();

  StreamSubscription<List<int>>? _bytesSub;
  StreamSubscription<UiInputEvent>? _eventSub;
  StreamSubscription<void>? _resizeSub;
  StreamSubscription<UiSnapshot>? _snapshotSub;
  UiLayoutResult? _layout;
  Future<void>? _pendingAction;
  Future<void>? _pendingCancelAction;
  Future<void>? _pendingLogViewer;
  String? _localNotice;
  bool _localError = false;
  bool _running = false;
  bool _started = false;
  UiSnapshot? _lastActivitySnapshot;

  UiLayoutResult? get latestLayout => _layout;

  Future<void> run() async {
    if (_started) throw StateError('UiNextShell can only be run once.');
    if (!_terminal.isInteractive) {
      throw StateError('Wristload TUI requires an interactive terminal.');
    }
    _started = true;
    _running = true;
    try {
      _terminal.setAltBuffer(true);
      _terminal.setRawMode(true);
      _terminal.setCursorVisible(false);
      _terminal.setMouseCapture(true);
      _terminal.clearScreen();
      _eventSub = _decoder.events.listen(_handleEvent, onError: _fail);
      _bytesSub = _terminal.byteStream.listen(
        _decoder.addBytes,
        onError: _fail,
        onDone: requestExit,
      );
      _resizeSub = _terminal.onResize.listen((_) => _render(), onError: _fail);
      _snapshotSub = _port.snapshots.listen(
        _handleSnapshot,
        onError: _fail,
        onDone: requestExit,
      );
      _reconcile(_port.snapshot);
      _syncAuthKeyModal(_port.snapshot);
      _recordSnapshotActivity(_port.snapshot);
      _render();
      _runAction(_initializeAndStartScan);
      await _exit.future;
    } finally {
      await dispose();
    }
  }

  void requestExit() {
    if (_exit.isCompleted) return;
    // Stop accepting render-producing events before completing the exit
    // future. Await continuations run later, so a queued snapshot can arrive
    // between `q` and `dispose()` unless this gate closes synchronously.
    _running = false;
    _exit.complete();
  }

  Future<UiActionResult> _initializeAndStartScan() async {
    final initialized = await _port.initialize();
    if (!initialized.accepted || !_running) return initialized;

    // Automatic discovery is a startup convenience, not a competing action
    // for an auto-connect attempt already in progress. `scan` is a toggle at
    // the port boundary, so never call it when scanning is already active.
    final snapshot = _port.snapshot;
    if (snapshot.scanning ||
        snapshot.connectionPhase != UiConnectionPhase.disconnected) {
      return initialized;
    }
    return _port.scan();
  }

  Future<void> dispose() async {
    if (!_started) return;
    _running = false;
    try {
      await _bytesSub?.cancel();
      await _eventSub?.cancel();
      await _resizeSub?.cancel();
      await _snapshotSub?.cancel();
      _decoder.close();
      await _port.dispose();
    } finally {
      // Native/backend disposal must never leave the user's terminal in raw
      // input, alternate-buffer, hidden-cursor, or mouse-capture mode.
      _terminal.setMouseCapture(false);
      _terminal.setCursorVisible(true);
      _terminal.setRawMode(false);
      _terminal.setAltBuffer(false);
      _terminal.reset();
      _started = false;
    }
  }

  void _handleSnapshot(UiSnapshot snapshot) {
    if (!_running) return;
    // Application state is authoritative. Do not let an old action result keep
    // masking newer connection, installation, or error transitions.
    _localNotice = null;
    _localError = false;
    _reconcile(snapshot);
    // Missing credentials are resolved before any native Bluetooth operation.
    // The application publishes this phase synchronously after a connect
    // intent, so opening the modal here keeps rendering free of side effects.
    _syncAuthKeyModal(snapshot);
    _recordSnapshotActivity(snapshot);
    _render();
  }

  void _syncAuthKeyModal(UiSnapshot snapshot) {
    if (snapshot.connectionPhase != UiConnectionPhase.awaitingAuthKey) {
      state.clearAuthKeyPromptDismissal();
      // A generation-bound prompt was opened by the application because it
      // was actually awaiting credentials. Once that attempt progresses or
      // fails, it must not linger over the connection state. A manual [a]
      // prompt has no generation and remains under the user's control.
      if (state.modal == UiModal.authKey &&
          state.modalTargetConnectionGeneration != null) {
        state.closeModal();
      }
      return;
    }
    final targetId = snapshot.pendingAuthDeviceId;
    if (targetId == null) return;

    final generation = snapshot.connectionGeneration;
    final modalTargetsAnotherAttempt = state.modal == UiModal.authKey &&
        (state.modalTargetDeviceId != targetId ||
            state.modalTargetConnectionGeneration != generation);
    if (modalTargetsAnotherAttempt) state.closeModal();

    if (state.modal == null &&
        !state.isAuthKeyPromptDismissedFor(targetId, generation)) {
      // Keep the visible selection and the pending auth target aligned. The
      // target remains stable even if a later snapshot reorders devices.
      state.select(targetId);
      state.openModal(
        UiModal.authKey,
        targetDeviceId: targetId,
        targetConnectionGeneration: generation,
      );
    }
  }

  void _reconcile(UiSnapshot snapshot) {
    if (snapshot.devices.any((device) => device.id == state.selectedDeviceId)) {
      return;
    }
    UiDevice? preferred;
    for (final device in snapshot.devices) {
      if (device.id == snapshot.connectedDeviceId || device.connected) {
        preferred = device;
        break;
      }
    }
    state.select(preferred?.id ??
        (snapshot.devices.isEmpty ? null : snapshot.devices.first.id));
    state.scrollOffset = 0;
  }

  void _handleEvent(UiInputEvent event) {
    if (!_running) return;
    if (event is UiMouseEvent) {
      _handleMouse(event);
    } else if (event is UiPasteEvent && state.modal != null) {
      state.input += event.text.replaceAll(RegExp(r'[\r\n]'), '');
      _render();
    } else if (event is UiKeyPress) {
      _handleKey(event);
    }
  }

  void _handleMouse(UiMouseEvent event) {
    // Keyboard input is already routed to the modal. Do the same for mouse
    // input so a visible authkey prompt cannot activate controls beneath it.
    if (state.modal != null) return;
    if (event.isScroll) {
      final delta = event.scrollDirection == UiScrollDirection.up ? -1 : 1;
      state.scrollOffset = (state.scrollOffset + delta).clamp(0, _maxOffset);
      _render();
      return;
    }
    if (!event.isPress || event.button != UiMouseButton.left) return;
    final layout = _layout;
    if (layout == null) return;
    for (final hit in layout.hitRegions.reversed) {
      if (!hit.rect.contains(event.column, event.row)) continue;
      if (hit.action == UiHitAction.device) {
        state.select(hit.deviceId);
        state.focusRegion(UiFocusTarget.deviceBrowser);
        _render();
      } else {
        if (hit.isCommandAction) {
          state.focusCommandBar(hit.action.name);
          // Mouse activation and keyboard navigation share one focus state.
          // Paint it before an asynchronous command can publish a snapshot.
          _render();
        }
        _dispatch(hit.action);
      }
      return;
    }
  }

  void _handleKey(UiKeyPress key) {
    if (state.modal != null) {
      _handleModalKey(key);
      return;
    }
    if (key.name == 'q' || key.name == 'ctrl-c') {
      requestExit();
    } else if (key.name == 'up' || key.name == 'k') {
      if (state.detailOpen) {
        _scroll(-1);
      } else if (state.commandBarFocused) {
        state.focusRegion(UiFocusTarget.deviceBrowser);
        _render();
      } else {
        _moveSelection(-1);
      }
    } else if (key.name == 'down' || key.name == 'j') {
      if (state.detailOpen) {
        _scroll(1);
      } else if (state.commandBarFocused) {
        // Command-bar navigation is horizontal. Down only reaches it from the
        // browser; left/right select an action and up returns to devices.
        return;
      } else {
        _moveBrowserOrEnterCommandBar(1);
      }
    } else if ((key.name == 'left' || key.name == 'h') &&
        state.commandBarFocused) {
      _moveCommandFocus(-1);
    } else if ((key.name == 'right' || key.name == 'l') &&
        state.commandBarFocused) {
      _moveCommandFocus(1);
    } else if (key.name == 'page-up') {
      state.detailOpen ? _scroll(-3) : _moveSelection(-3);
    } else if (key.name == 'page-down') {
      state.detailOpen ? _scroll(3) : _moveSelection(3);
    } else if (key.name == 'enter') {
      if (state.commandBarFocused) {
        _dispatchFocusedCommand();
      } else {
        _activatePrimaryConnectionAction();
      }
    } else if (key.name == 'd' || key.name == 'tab') {
      _toggleDetails();
    } else if (key.name == 'esc' && state.detailOpen) {
      state.detailOpen = false;
      state.scrollOffset = 0;
      _render();
    } else if (key.name == 'r') {
      _runAction(_port.scan);
    } else if (key.name == 'c') {
      _requestConnect();
    } else if (key.name == 'g') {
      _requestDirectedConnect();
    } else if (key.name == 'x') {
      _requestDisconnect();
    } else if (key.name == 's') {
      final device = _selected;
      if (device != null) {
        _runAction(
          () => device.saved
              ? _port.removeSavedDevice(device.id)
              : _port.saveDevice(device.id),
        );
      }
    } else if (key.name == 'a') {
      _openModal(UiModal.authKey);
    } else if (key.name == 'i') {
      _openModal(UiModal.installPath);
    } else if (key.name == 'z') {
      _runAction(_port.cancelInstall, cancelInstall: true);
    } else if (key.name == 't') {
      _runAction(
        () => _port.setAutoConnect(!_port.snapshot.autoConnect),
      );
    } else if (key.name == 'm') {
      _cycleTheme();
    } else if (key.name == 'L') {
      _openLogViewer();
    }
  }

  void _handleModalKey(UiKeyPress key) {
    if (key.name == 'esc') {
      final cancelledAuthKey = state.modal == UiModal.authKey;
      if (cancelledAuthKey) {
        final targetId = state.modalTargetDeviceId;
        final generation = state.modalTargetConnectionGeneration;
        if (targetId != null && generation != null) {
          state.dismissAuthKeyPromptFor(targetId, generation);
        }
      }
      state.closeModal();
      _render();
      // Cancelling input is purely local. It must not start, stop, or otherwise
      // touch the Bluetooth backend; the user can explicitly press disconnect
      // when they want to abandon the pending application state.
    } else if (key.name == 'enter') {
      final input = state.input.trim();
      final modal = state.modal;
      final targetId = state.modalTargetDeviceId ?? _selected?.id;
      if (targetId == null || input.isEmpty || modal == null) return;
      state.closeModal();
      // The credential submission can await storage or native setup before it
      // publishes its next snapshot. Remove the prompt from the terminal now
      // so the user sees the transition immediately rather than a stale input
      // box while the connection attempt starts.
      _render();
      _runAction(
        () => modal == UiModal.authKey
            ? _port.submitAuthKey(targetId, input)
            : _port.installResource(targetId, input),
      );
    } else if (key.name == 'backspace' || key.name == 'delete') {
      if (state.input.isNotEmpty) {
        state.input = state.input.substring(0, state.input.length - 1);
        _render();
      }
    } else if (key.isPrintable) {
      state.input += key.raw;
      _render();
    }
  }

  void _dispatch(UiHitAction action) {
    if (action == UiHitAction.scan) {
      _runAction(_port.scan);
    } else if (action == UiHitAction.connect) {
      _requestConnect();
    } else if (action == UiHitAction.directedConnect) {
      _requestDirectedConnect();
    } else if (action == UiHitAction.disconnect) {
      _requestDisconnect();
    } else if (action == UiHitAction.details) {
      _toggleDetails();
    } else if (action == UiHitAction.save) {
      _withSelected(_port.saveDevice);
    } else if (action == UiHitAction.remove) {
      _withSelected(_port.removeSavedDevice);
    } else if (action == UiHitAction.authKey) {
      _openModal(UiModal.authKey);
    } else if (action == UiHitAction.install) {
      _openModal(UiModal.installPath);
    } else if (action == UiHitAction.cancelInstall) {
      _runAction(_port.cancelInstall, cancelInstall: true);
    } else if (action == UiHitAction.autoConnect) {
      _runAction(
        () => _port.setAutoConnect(!_port.snapshot.autoConnect),
      );
    } else if (action == UiHitAction.theme) {
      _cycleTheme();
    } else if (action == UiHitAction.openLogs) {
      _openLogViewer();
    } else if (action == UiHitAction.previousCommandPage) {
      _moveCommandPage(-1, selectLast: true);
    } else if (action == UiHitAction.nextCommandPage) {
      _moveCommandPage(1);
    }
  }

  bool get _canStartConnection =>
      _port.snapshot.connectionPhase == UiConnectionPhase.disconnected ||
      _port.snapshot.connectionPhase == UiConnectionPhase.failed;

  bool get _canDisconnect => switch (_port.snapshot.connectionPhase) {
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

  void _activatePrimaryConnectionAction() {
    // Browsing a ready device must not make Enter an accidental disconnect.
    // Disconnect remains explicit through the visible command bar or x.
    _requestConnect();
  }

  void _requestConnect() {
    if (_canStartConnection) _withSelected(_port.connect);
  }

  void _requestDirectedConnect() {
    if (_canStartConnection && _selected?.isDirectedSessionTarget == true) {
      _runAction(_port.connectDirectedExactAddress);
    }
  }

  void _requestDisconnect() {
    if (_canDisconnect) _runAction(_port.disconnect);
  }

  void _openModal(UiModal modal) {
    final device = _selected;
    if (device == null) return;
    state.openModal(
      modal,
      targetDeviceId: device.id,
    );
    _render();
  }

  void _toggleDetails() {
    state.detailOpen = !state.detailOpen;
    state.scrollOffset = 0;
    _render();
  }

  void _cycleTheme() {
    const themes = <String>['black-blue', 'black-cyan', 'black-green'];
    final current = _port.snapshot.themeId;
    final index = themes.indexOf(current);
    final next = themes[(index < 0 ? 0 : index + 1) % themes.length];
    _runAction(() => _port.setThemeId(next));
  }

  void _openLogViewer() {
    if (_pendingLogViewer != null) return;
    final launcher = _logViewerLauncher;
    if (launcher == null) {
      _localNotice = '日志查看器不可用';
      _localError = true;
      _render();
      return;
    }
    late final Future<void> tracked;
    tracked = launcher().then<void>((_) {
      if (!_running) return;
      _localNotice = '已在 macOS Terminal 打开诊断日志';
      _localError = false;
      _render();
    }, onError: (Object error, StackTrace stack) {
      if (!_running) return;
      _localNotice = '日志查看器启动失败：' + error.toString();
      _localError = true;
      _render();
    }).whenComplete(() {
      if (identical(_pendingLogViewer, tracked)) _pendingLogViewer = null;
    });
    _pendingLogViewer = tracked;
  }

  void _moveBrowserOrEnterCommandBar(int delta) {
    final devices = _port.snapshot.devices;
    if (devices.isEmpty) {
      _enterCommandBar();
      return;
    }
    final current =
        devices.indexWhere((device) => device.id == state.selectedDeviceId);
    if (delta > 0 && current >= devices.length - 1) {
      _enterCommandBar();
      return;
    }
    _moveSelection(delta);
  }

  void _moveSelection(int delta) {
    if (state.selectionLocked) return;
    final devices = _port.snapshot.devices;
    if (devices.isEmpty) return;
    state.focusRegion(UiFocusTarget.deviceBrowser);
    var index =
        devices.indexWhere((device) => device.id == state.selectedDeviceId);
    if (index < 0) index = 0;
    index = (index + delta).clamp(0, devices.length - 1);
    state.select(devices[index].id);
    if (!(_layout?.visibleDeviceIds.contains(devices[index].id) ?? false)) {
      state.scrollOffset = index;
    }
    _render();
  }

  void _enterCommandBar() {
    final names = _layout?.visibleCommandActionNames ?? const <String>[];
    if (names.isEmpty) return;
    state.focusCommandBar(names.first);
    _render();
  }

  void _moveCommandFocus(int delta) {
    final names = _layout?.visibleCommandActionNames ?? const <String>[];
    if (names.isEmpty) {
      state.clearCommandBarFocus();
      _render();
      return;
    }
    final current = names.indexOf(state.focusedActionName ?? '');
    final next = (current < 0 ? 0 : current) + delta;
    if (next < 0 && (_layout?.commandPage ?? 0) > 0) {
      _moveCommandPage(-1, selectLast: true);
      return;
    }
    if (next >= names.length &&
        (_layout?.commandPage ?? 0) < ((_layout?.commandPageCount ?? 1) - 1)) {
      _moveCommandPage(1);
      return;
    }
    final bounded = next.clamp(0, names.length - 1).toInt();
    state.focusCommandBar(names[bounded]);
    _render();
  }

  void _moveCommandPage(int delta, {bool selectLast = false}) {
    final layout = _layout;
    if (layout == null || layout.commandPageCount <= 1) return;
    final next = (layout.commandPage + delta)
        .clamp(0, layout.commandPageCount - 1)
        .toInt();
    if (next == layout.commandPage) return;
    state.setCommandPage(next);
    state.focusCommandBar();
    _render();
    final names = _layout?.visibleCommandActionNames ?? const <String>[];
    if (names.isEmpty) return;
    state.focusCommandBar(selectLast ? names.last : names.first);
    _render();
  }

  void _dispatchFocusedCommand() {
    final name = state.focusedActionName;
    if (name == null) {
      _enterCommandBar();
      return;
    }
    UiHitAction? action;
    for (final candidate in UiHitAction.values) {
      if (candidate.name == name) {
        action = candidate;
        break;
      }
    }
    if (action == null ||
        !(_layout?.visibleCommandActionNames.contains(action.name) ?? false)) {
      _enterCommandBar();
      return;
    }
    _dispatch(action);
  }

  void _scroll(int delta) {
    state.scrollOffset = (state.scrollOffset + delta).clamp(0, _maxOffset);
    _render();
  }

  void _withSelected(Future<UiActionResult> Function(String) action) {
    final device = _selected;
    if (device == null) {
      _localNotice = '请先选择设备';
      _localError = true;
      _render();
      return;
    }
    _runAction(() => action(device.id));
  }

  void _runAction(
    Future<UiActionResult> Function() action, {
    bool cancelInstall = false,
  }) {
    if (cancelInstall ? _pendingCancelAction != null : _pendingAction != null) {
      return;
    }

    // Reserve synchronously before invoking [action]. A port method can begin
    // work immediately, so reserving afterwards admits a second Enter/click
    // before the first future has been recorded.
    final reservation = Completer<void>();
    if (cancelInstall) {
      _pendingCancelAction = reservation.future;
    } else {
      _pendingAction = reservation.future;
    }

    void release() {
      if (cancelInstall) {
        if (identical(_pendingCancelAction, reservation.future)) {
          _pendingCancelAction = null;
        }
      } else if (identical(_pendingAction, reservation.future)) {
        _pendingAction = null;
      }
      if (!reservation.isCompleted) reservation.complete();
    }

    Future<UiActionResult> future;
    try {
      future = action();
    } catch (error) {
      if (_running) {
        _localNotice = error.toString();
        _localError = true;
        _render();
      }
      release();
      return;
    }
    future.then((result) {
      if (!_running) return;
      _localNotice = result.message;
      _localError = !result.accepted;
      _render();
    }, onError: (Object error, StackTrace stack) {
      if (!_running) return;
      _localNotice = error.toString();
      _localError = true;
      _render();
    }).whenComplete(release);
  }

  void _render() {
    if (!_running) return;
    var snapshot = _port.snapshot;
    if (_localNotice != null) {
      snapshot = UiSnapshot(
        revision: snapshot.revision,
        devices: snapshot.devices,
        connectionPhase: snapshot.connectionPhase,
        connectedDeviceId: snapshot.connectedDeviceId,
        pendingAuthDeviceId: snapshot.pendingAuthDeviceId,
        connectionGeneration: snapshot.connectionGeneration,
        scanning: snapshot.scanning,
        autoConnect: snapshot.autoConnect,
        autoConnectState: snapshot.autoConnectState,
        themeId: snapshot.themeId,
        install: snapshot.install,
        notice: _localError ? snapshot.notice : _localNotice,
        error: _localError ? _localNotice : snapshot.error,
      );
    }
    _layout = _renderer.render(
      snapshot: snapshot,
      state: state,
      width: _terminal.columns,
      height: _terminal.rows,
      color: _terminal.supportsColor,
    );
    state.scrollOffset = state.scrollOffset.clamp(0, _maxOffset);
    if (_normalizeCommandFocus()) {
      _layout = _renderer.render(
        snapshot: snapshot,
        state: state,
        width: _terminal.columns,
        height: _terminal.rows,
        color: _terminal.supportsColor,
      );
      state.scrollOffset = state.scrollOffset.clamp(0, _maxOffset);
    }
    _terminal.moveHome();
    _terminal.write(_layout!.text);
    _terminal.flush();
  }

  int get _maxOffset => _layout?.maxScrollOffset ?? 0;

  bool _normalizeCommandFocus() {
    final names = _layout?.visibleCommandActionNames ?? const <String>[];
    if (state.modal != null || state.detailOpen || names.isEmpty) {
      if (!state.commandBarFocused && state.focusedActionName == null) {
        return false;
      }
      state.clearCommandBarFocus();
      return true;
    }
    if (!state.commandBarFocused) return false;
    if (names.contains(state.focusedActionName)) return false;
    state.focusCommandBar(names.first);
    return true;
  }

  void _recordSnapshotActivity(UiSnapshot snapshot) {
    final previous = _lastActivitySnapshot;
    _lastActivitySnapshot = snapshot;
    if (previous == null) return;
    if (previous.scanning != snapshot.scanning) {
      state.recordActivity(
        category: '扫描',
        message: snapshot.scanning ? '已开始' : '已停止',
      );
    }
    if (previous.connectionPhase != snapshot.connectionPhase) {
      final description = switch (snapshot.connectionPhase) {
        UiConnectionPhase.disconnected => null,
        UiConnectionPhase.connecting => '连接中',
        UiConnectionPhase.awaitingAuthKey => '等待 authkey',
        UiConnectionPhase.authenticating => '正在鉴权',
        UiConnectionPhase.ready => 'Session READY',
        UiConnectionPhase.disconnecting => '正在断开',
        UiConnectionPhase.failed => '连接失败',
      };
      if (description != null) {
        state.recordActivity(
          category: '连接',
          message: description,
          isError: snapshot.connectionPhase == UiConnectionPhase.failed,
        );
      }
    }
    if (previous.install.phase != snapshot.install.phase ||
        (snapshot.install.phase == UiInstallPhase.succeeded &&
            previous.install.successVerifiedByDeviceBusinessEvent !=
                snapshot.install.successVerifiedByDeviceBusinessEvent)) {
      state.recordActivity(
        category: '安装',
        message: _activityInstallMessage(snapshot.install),
        isError: snapshot.install.phase == UiInstallPhase.failed,
      );
    }
  }

  String _activityInstallMessage(UiInstallStatus install) =>
      switch (install.phase) {
        UiInstallPhase.idle => '等待设备安装结果',
        UiInstallPhase.preparing => '正在准备',
        UiInstallPhase.transferring => '正在传输',
        UiInstallPhase.awaitingDevice => '等待设备业务结果',
        UiInstallPhase.succeeded
            when install.successVerifiedByDeviceBusinessEvent =>
          '设备确认安装成功',
        UiInstallPhase.succeeded => '等待设备安装结果',
        UiInstallPhase.failed => '安装失败',
        UiInstallPhase.unknown => '安装结果未知',
      };

  UiDevice? get _selected {
    for (final device in _port.snapshot.devices) {
      if (device.id == state.selectedDeviceId) return device;
    }
    return null;
  }

  void _fail(Object error, [StackTrace? stackTrace]) {
    _running = false;
    if (!_exit.isCompleted) {
      _exit.completeError(error, stackTrace ?? StackTrace.current);
    }
  }
}
