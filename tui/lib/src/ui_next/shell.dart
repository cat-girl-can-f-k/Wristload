import 'dart:async';

import 'input.dart';
import 'layout.dart';
import 'port.dart';
import 'state.dart';
import 'terminal.dart';

/// Terminal lifecycle and input router for the replacement frontend.
/// Native and Bluetooth work is confined behind [UiNextPort].
class UiNextShell {
  UiNextShell({
    required UiTerminal terminal,
    required UiNextPort port,
    UiNextRenderer renderer = const UiNextRenderer(),
  })  : _terminal = terminal,
        _port = port,
        _renderer = renderer;

  final UiTerminal _terminal;
  final UiNextPort _port;
  final UiNextRenderer _renderer;
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
  String? _localNotice;
  bool _localError = false;
  bool _running = false;
  bool _started = false;

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
      _render();
      _runAction(_port.initialize());
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
    _render();
  }

  void _syncAuthKeyModal(UiSnapshot snapshot) {
    if (snapshot.connectionPhase != UiConnectionPhase.awaitingAuthKey) {
      state.authKeyPromptDismissed = false;
      return;
    }
    if (state.modal == null && !state.authKeyPromptDismissed) {
      state.modal = UiModal.authKey;
      state.input = '';
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
        _render();
      } else {
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
      state.detailOpen ? _scroll(-1) : _moveSelection(-1);
    } else if (key.name == 'down' || key.name == 'j') {
      state.detailOpen ? _scroll(1) : _moveSelection(1);
    } else if (key.name == 'page-up') {
      state.detailOpen ? _scroll(-3) : _moveSelection(-3);
    } else if (key.name == 'page-down') {
      state.detailOpen ? _scroll(3) : _moveSelection(3);
    } else if (key.name == 'enter') {
      state.detailOpen = !state.detailOpen;
      state.scrollOffset = 0;
      _render();
    } else if (key.name == 'esc' && state.detailOpen) {
      state.detailOpen = false;
      state.scrollOffset = 0;
      _render();
    } else if (key.name == 'r') {
      _runAction(_port.scan());
    } else if (key.name == 'c') {
      _withSelected(_port.connect);
    } else if (key.name == 'x') {
      _runAction(_port.disconnect());
    } else if (key.name == 's') {
      final device = _selected;
      if (device != null) {
        _runAction(device.saved
            ? _port.removeSavedDevice(device.id)
            : _port.saveDevice(device.id));
      }
    } else if (key.name == 'a') {
      _openModal(UiModal.authKey);
    } else if (key.name == 'i') {
      _openModal(UiModal.installPath);
    } else if (key.name == 'z') {
      _runAction(_port.cancelInstall(), cancelInstall: true);
    } else if (key.name == 't') {
      _runAction(_port.setAutoConnect(!_port.snapshot.autoConnect));
    } else if (key.name == 'm') {
      _cycleTheme();
    }
  }

  void _handleModalKey(UiKeyPress key) {
    if (key.name == 'esc') {
      final cancelledAuthKey = state.modal == UiModal.authKey;
      if (cancelledAuthKey) state.authKeyPromptDismissed = true;
      state.modal = null;
      state.input = '';
      _render();
      // Cancelling input is purely local. It must not start, stop, or otherwise
      // touch the Bluetooth backend; the user can explicitly press disconnect
      // when they want to abandon the pending application state.
    } else if (key.name == 'enter') {
      final device = _selected;
      final input = state.input.trim();
      final modal = state.modal;
      if (device == null || input.isEmpty || modal == null) return;
      state.modal = null;
      state.input = '';
      _runAction(modal == UiModal.authKey
          ? _port.submitAuthKey(device.id, input)
          : _port.installResource(device.id, input));
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
      _runAction(_port.scan());
    } else if (action == UiHitAction.connect) {
      _withSelected(_port.connect);
    } else if (action == UiHitAction.disconnect) {
      _runAction(_port.disconnect());
    } else if (action == UiHitAction.details) {
      state.detailOpen = !state.detailOpen;
      _render();
    } else if (action == UiHitAction.save) {
      _withSelected(_port.saveDevice);
    } else if (action == UiHitAction.remove) {
      _withSelected(_port.removeSavedDevice);
    } else if (action == UiHitAction.authKey) {
      _openModal(UiModal.authKey);
    } else if (action == UiHitAction.install) {
      _openModal(UiModal.installPath);
    } else if (action == UiHitAction.cancelInstall) {
      _runAction(_port.cancelInstall(), cancelInstall: true);
    } else if (action == UiHitAction.autoConnect) {
      _runAction(_port.setAutoConnect(!_port.snapshot.autoConnect));
    } else if (action == UiHitAction.theme) {
      _cycleTheme();
    }
  }

  void _openModal(UiModal modal) {
    if (_selected == null) return;
    state.modal = modal;
    state.input = '';
    _render();
  }

  void _cycleTheme() {
    const themes = <String>['black-blue', 'black-cyan', 'black-green'];
    final current = _port.snapshot.themeId;
    final index = themes.indexOf(current);
    final next = themes[(index < 0 ? 0 : index + 1) % themes.length];
    _runAction(_port.setThemeId(next));
  }

  void _moveSelection(int delta) {
    final devices = _port.snapshot.devices;
    if (devices.isEmpty) return;
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
    _runAction(action(device.id));
  }

  void _runAction(Future<UiActionResult> future, {bool cancelInstall = false}) {
    if (cancelInstall ? _pendingCancelAction != null : _pendingAction != null) {
      return;
    }
    late final Future<void> tracked;
    tracked = future.then((result) {
      if (!_running) return;
      _localNotice = result.message;
      _localError = !result.accepted;
      _render();
    }, onError: (Object error, StackTrace stack) {
      if (!_running) return;
      _localNotice = error.toString();
      _localError = true;
      _render();
    }).whenComplete(() {
      if (cancelInstall) {
        if (identical(_pendingCancelAction, tracked)) {
          _pendingCancelAction = null;
        }
      } else if (identical(_pendingAction, tracked)) {
        _pendingAction = null;
      }
    });
    if (cancelInstall) {
      _pendingCancelAction = tracked;
    } else {
      _pendingAction = tracked;
    }
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
    _terminal.moveHome();
    _terminal.write(_layout!.text);
    _terminal.flush();
  }

  int get _maxOffset => _layout?.maxScrollOffset ?? 0;

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
