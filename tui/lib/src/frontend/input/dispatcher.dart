import 'dart:async';

import '../port/tui_action_result.dart';
import '../port/tui_frontend_port.dart';
import '../port/tui_snapshot.dart';
import '../state/app_state.dart';
import '../terminal/terminal.dart';
import 'command.dart';

/// Dispatches [UiCommand]s to the [TuiFrontendPort], tracks pending actions,
/// and surfaces safe result messages without exposing secrets or stack traces.
class ActionDispatcher {
  ActionDispatcher({
    required TuiFrontendPort port,
    required AppState state,
    required Terminal terminal,
    void Function(String message, {bool isError})? onNotice,
  })  : _port = port,
        _state = state,
        _terminal = terminal,
        _onNotice = onNotice;

  final TuiFrontendPort _port;
  final AppState _state;
  final Terminal _terminal;
  final void Function(String message, {bool isError})? _onNotice;

  bool _disposed = false;

  Future<void> dispatch(UiCommand command) async {
    if (_disposed) return;

    final name = _commandName(command);
    if (_state.isActionPending(name)) return;
    Future<TuiActionResult> Function()? action;

    switch (command) {
      case NavigateCommand():
        _navigate(command.view);
        return;
      case SelectNextCommand():
        _selectNext();
        return;
      case SelectPreviousCommand():
        _selectPrevious();
        return;
      case SelectFirstCommand():
        _selectFirst();
        return;
      case SelectLastCommand():
        _selectLast();
        return;
      case ActivateCommand():
        _activate();
        return;
      case CancelCommand():
        _state.clearInputs();
        return;
      case QuitCommand():
        return;
      case RefreshPairedCommand():
        if (!_allowed('refreshPairedDevices')) return;
        action = _port.refreshPairedDevices;
      case StartStopScanCommand():
        final scanAction = (_port.snapshot.scan.state == TuiScanState.running ||
                _port.snapshot.scan.state == TuiScanState.starting)
            ? 'stopScan'
            : 'startScan';
        if (!_allowed(scanAction)) return;
        action = () {
          final scan = _port.snapshot.scan.state;
          if (scan == TuiScanState.running || scan == TuiScanState.starting) {
            return _port.stopScan();
          }
          return _port.startScan(duration: const Duration(seconds: 10));
        };
      case AddManualDeviceCommand():
        if (!_allowed('addManualDevice')) return;
        if (_state.manualAddress.isEmpty) {
          _notice('请输入蓝牙地址');
          return;
        }
        if (_state.selectedModelId.isEmpty) {
          _notice('请选择型号');
          return;
        }
        action = () => _port.addManualDevice(
              address: _state.manualAddress,
              modelId: _state.selectedModelId,
              displayName: _state.manualDisplayName.isEmpty
                  ? null
                  : _state.manualDisplayName,
            );
      case OpenManualDeviceCommand():
        if (!_allowed('addManualDevice')) return;
        _state.showAddDevice = true;
        _state.selectedModelId = '';
        _state.manualDeviceField = ManualDeviceField.address;
        return;
      case CycleManualFieldCommand():
        _state.manualDeviceField = switch (_state.manualDeviceField) {
          ManualDeviceField.address => ManualDeviceField.model,
          ManualDeviceField.model => ManualDeviceField.displayName,
          ManualDeviceField.displayName => ManualDeviceField.address,
        };
        return;
      case SelectManualModelCommand(:final delta):
        _selectManualModel(delta);
        return;
      case ConnectCommand():
        final connection = _port.snapshot.connection.state;
        if (connection != TuiConnectionState.disconnected &&
            connection != TuiConnectionState.failed) {
          _state.openConfirmation(
            title: '断开设备',
            message: '断开当前设备连接？',
            confirmLabel: '断开',
            dangerous: true,
            onConfirm: () => dispatch(const DisconnectCommand()),
          );
          return;
        }
        final id = _state.selectedDeviceId;
        if (id == null) {
          _notice('请先选择设备');
          return;
        }
        if (!_port.snapshot.devices.any((device) => device.deviceId == id)) {
          _state.selectedDeviceId = null;
          _notice('所选设备已不在当前列表中');
          return;
        }
        final device =
            _port.snapshot.devices.firstWhere((item) => item.deviceId == id);
        if (!device.allowedActions.contains('connectDevice')) {
          _notice(device.blockedReason ?? '当前设备不允许连接', isError: true);
          return;
        }
        action = () => _port.connectDevice(id);
      case DisconnectCommand():
        if (!_allowed('disconnect')) return;
        action = _port.disconnect;
      case AuthKeyCommand():
        if (!_allowed('submitAuthKey')) return;
        _state.authKeyInput = '';
        _state.authKeyVisible = false;
        _state.showAuthKey = true;
        return;
      case SubmitAuthKeyCommand():
        final value = _state.authKeyInput;
        _state.authKeyInput = '';
        _state.authKeyVisible = false;
        if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(value)) {
          _notice('authkey 必须为 32 位十六进制字符', isError: true);
          return;
        }
        if (!_allowed('submitAuthKey')) return;
        action = () => _port.submitAuthKey(value);
      case ToggleAuthKeyVisibilityCommand():
        _state.authKeyVisible = !_state.authKeyVisible;
        return;
      case ClearAuthKeyCommand():
        if (!_allowed('clearAuthKey')) return;
        action = _port.clearAuthKey;
      case ImportFilesCommand():
        if (!_allowed('importFiles')) return;
        _state.showImport = true;
        return;
      case SubmitImportCommand():
        final lines = _state.importInput
            .split('\n')
            // Paths are literal values; only discard truly empty lines.
            .where((line) => line.isNotEmpty)
            .toList();
        if (lines.isEmpty) {
          _notice('请输入至少一个文件路径');
          return;
        }
        action = () => _port.importFiles(lines);
      case RemoveQueueItemCommand():
        final id = _state.selectedQueueItemId;
        if (id == null) {
          _notice('请先选择队列条目');
          return;
        }
        final item = _queueItem(id);
        if (item == null || !_itemAllowed(item, 'removeQueueItem')) return;
        action = () => _port.removeQueueItem(id);
      case ClearCompletedQueueCommand():
        if (!_allowed('clearCompletedQueue')) return;
        action = _port.clearCompletedQueue;
      case MoveQueueItemCommand(:final delta):
        final id = _state.selectedQueueItemId;
        if (id == null) return;
        final index =
            _port.snapshot.queue.indexWhere((item) => item.itemId == id);
        if (index < 0) return;
        final newIndex =
            (index + delta).clamp(0, _port.snapshot.queue.length - 1).toInt();
        if (newIndex == index) return;
        final item = _port.snapshot.queue[index];
        if (!_itemAllowed(item, 'moveQueueItem')) return;
        action = () => _port.moveQueueItem(id, newIndex);
      case StartQueueCommand():
        if (!_allowed('startQueue')) return;
        if (!command.confirmed) {
          _state.openConfirmation(
            title: '启动安装队列',
            message: '将按当前顺序向已连接设备传输队列内容。继续？',
            confirmLabel: '启动',
            dangerous: true,
            onConfirm: () => dispatch(const StartQueueCommand(confirmed: true)),
          );
          return;
        }
        action = _port.startQueue;
      case RetryQueueItemCommand():
        final id = _state.selectedQueueItemId;
        if (id == null) {
          _notice('请先选择队列条目');
          return;
        }
        final item = _queueItem(id);
        if (item == null || !_itemAllowed(item, 'retryQueueItem')) return;
        action = () => _port.retryQueueItem(id);
      case CancelInstallCommand():
        if (!_allowed('cancelActiveInstall')) return;
        if (!command.confirmed) {
          _state.openConfirmation(
            title: '取消当前安装',
            message: '设备可能保留部分传输数据，确认取消？',
            confirmLabel: '取消安装',
            dangerous: true,
            onConfirm: () => dispatch(const CancelInstallCommand(confirmed: true)),
          );
          return;
        }
        action = _port.cancelActiveInstall;
      case InspectRecoveryCommand():
        if (!_recoveryAllowed('inspectRecovery')) return;
        action = _port.inspectRecovery;
      case ResumeRecoveryCommand():
        if (!_recoveryAllowed('resumeRecovery')) return;
        action = _port.resumeRecovery;
      case DiscardRecoveryCommand():
        if (!_recoveryAllowed('discardRecovery')) return;
        if (!command.confirmed) {
          _state.openConfirmation(
            title: '丢弃恢复检查点',
            message: '该检查点将被删除，无法继续恢复。确认丢弃？',
            confirmLabel: '丢弃',
            dangerous: true,
            onConfirm: () => dispatch(const DiscardRecoveryCommand(confirmed: true)),
          );
          return;
        }
        action = _port.discardRecovery;
      case UpdateSettingsCommand():
        if (!_allowed('updateTransferSettings')) return;
        final settings = _port.snapshot.transferSettings;
        final interval = int.tryParse(_state.segmentIntervalInput.isEmpty
            ? settings.segmentIntervalMs.toString()
            : _state.segmentIntervalInput);
        final window = int.tryParse(_state.massWindowSizeInput.isEmpty
            ? settings.massWindowSize.toString()
            : _state.massWindowSizeInput);
        if (interval == null || interval < 1 || interval > 20) {
          _notice('分段间隔必须为 1 到 20 的整数', isError: true);
          return;
        }
        if (window == null || window < 1 || window > 50) {
          _notice('Mass 窗口大小必须为 1 到 50 的整数', isError: true);
          return;
        }
        action = () => _port.updateTransferSettings(
              segmentIntervalMs: interval,
              massWindowSize: window,
            );
      case CycleSettingsFieldCommand():
        _state.settingsField = switch (_state.settingsField) {
          SettingsField.segmentInterval => SettingsField.massWindowSize,
          SettingsField.massWindowSize => SettingsField.segmentInterval,
        };
        return;
      case ExportLogsCommand():
        if (!_allowed('exportSafeLogs')) return;
        _state.showLogExport = true;
        _state.logExportPathInput = '/tmp/wristload_logs.txt';
        return;
      case SubmitLogExportCommand():
        if (!_allowed('exportSafeLogs')) return;
        final destination = _state.logExportPathInput;
        if (destination.isEmpty) {
          _notice('请输入导出路径');
          return;
        }
        action = () => _port.exportSafeLogs(destination);
      case ToggleHelpCommand():
        _state.showHelp = !_state.showHelp;
        return;
      case ToggleLogFollowCommand():
        if (_state.logsFollowTail) {
          // Pause at the visible tail instead of jumping to the first entry.
          _state.logsScrollOffset = _maxLogScroll();
          _state.logsFollowTail = false;
        } else {
          _state.logsFollowTail = true;
          _state.logsScrollOffset = 0;
        }
        return;
      case CycleLogLevelFilterCommand():
        final values = <TuiLogLevel?>[null, ...TuiLogLevel.values];
        final index = values.indexOf(_state.logsFilter);
        _state.logsFilter = values[(index + 1) % values.length];
        _state.logsScrollOffset = 0;
        return;
      case CycleLogCategoryFilterCommand():
        _state.logsCategoryFilter = _nextCategory(_state.logsCategoryFilter);
        _state.logsScrollOffset = 0;
        return;
      case ResetLogFiltersCommand():
        _state.logsFilter = null;
        _state.logsCategoryFilter = null;
        _state.logsScrollOffset = 0;
        return;
      case ScrollLogsCommand(:final delta):
        if (_state.logsFollowTail) {
          _state.logsScrollOffset = _maxLogScroll();
        }
        _state.logsFollowTail = false;
        _state.logsScrollOffset = (_state.logsScrollOffset + delta)
            .clamp(0, _maxLogScroll())
            .toInt();
        return;
      case OpenPendingDecisionCommand():
        _openPendingDecision();
        return;
      case CycleDecisionFieldCommand():
        _cycleDecisionField();
        return;
      case ConfirmDialogCommand():
        final confirm = _state.onDialogConfirm;
        _state.clearInputs();
        if (confirm != null) await confirm();
        return;
      case ToggleDialogFocusCommand():
        if (_state.activeDecisionId != null) {
          _state.decisionFocusConfirm = !_state.decisionFocusConfirm;
        } else {
          _state.dialogFocusConfirm = !_state.dialogFocusConfirm;
        }
        return;
      case TypeTextCommand(:final text):
        _type(text);
        return;
      case BackspaceCommand():
        _backspace();
        return;
      case DecisionCommand(:final decisionId, :final accepted, :final values):
        final submittedValues = Map<String, String>.from(values);
        action = () => _port.resolveDecision(
              decisionId,
              accepted: accepted,
              values: submittedValues,
            );
    }

    _state.markPending(name);
    var clearTransientInputs = false;

    try {
      final result = await action();
      if (_disposed) return;
      if (!result.accepted) {
        _notice(result.message, isError: true);
      } else if (result.message != '已接受：$name') {
        _notice(result.message);
      }
      clearTransientInputs = result.accepted;
    } on Object {
      // Never surface exception text or stack traces to the UI.
      _notice('操作失败，请检查日志或重试。', isError: true);
    } finally {
      _state.clearPending(name);
      // Preserve rejected values so the user can correct them, except authkey
      // input which is erased before it is sent.
      if (clearTransientInputs &&
          (command is AddManualDeviceCommand ||
              command is SubmitImportCommand ||
              command is SubmitLogExportCommand ||
              command is SubmitAuthKeyCommand ||
              command is UpdateSettingsCommand ||
              command is DecisionCommand)) {
        _state.clearInputs();
      }
    }
  }

  void _navigate(int index) {
    final views = View.values;
    if (index < 0 || index >= views.length) return;
    _state.currentView = views[index];
    _state.clearInputs();
  }

  void _selectNext() {
    switch (_state.currentView) {
      case View.devices:
        _selectById(_port.snapshot.devices, (d) => d.deviceId,
            (id) => _state.selectedDeviceId = id);
      case View.queue:
        _selectById(_port.snapshot.queue, (q) => q.itemId,
            (id) => _state.selectedQueueItemId = id);
      case View.logs:
        if (_state.logsFollowTail) {
          _state.logsScrollOffset = _maxLogScroll();
        }
        _state.logsFollowTail = false;
        _state.logsScrollOffset = (_state.logsScrollOffset + 1)
            .clamp(0, _maxLogScroll())
            .toInt();
      default:
        break;
    }
  }

  void _selectPrevious() {
    switch (_state.currentView) {
      case View.devices:
        _selectById(_port.snapshot.devices, (d) => d.deviceId,
            (id) => _state.selectedDeviceId = id,
            direction: -1);
      case View.queue:
        _selectById(_port.snapshot.queue, (q) => q.itemId,
            (id) => _state.selectedQueueItemId = id,
            direction: -1);
      case View.logs:
        if (_state.logsFollowTail) {
          _state.logsScrollOffset = _maxLogScroll();
        }
        _state.logsFollowTail = false;
        _state.logsScrollOffset = (_state.logsScrollOffset - 1)
            .clamp(0, _maxLogScroll())
            .toInt();
      default:
        break;
    }
  }

  void _selectFirst() {
    switch (_state.currentView) {
      case View.devices:
        final list = _port.snapshot.devices;
        _state.selectedDeviceId = list.isEmpty ? null : list.first.deviceId;
      case View.queue:
        final list = _port.snapshot.queue;
        _state.selectedQueueItemId = list.isEmpty ? null : list.first.itemId;
      case View.logs:
        _state.logsFollowTail = false;
        _state.logsScrollOffset = 0;
      default:
        break;
    }
  }

  void _selectLast() {
    switch (_state.currentView) {
      case View.devices:
        final list = _port.snapshot.devices;
        _state.selectedDeviceId = list.isEmpty ? null : list.last.deviceId;
      case View.queue:
        final list = _port.snapshot.queue;
        _state.selectedQueueItemId = list.isEmpty ? null : list.last.itemId;
      case View.logs:
        _state.logsFollowTail = false;
        _state.logsScrollOffset = _maxLogScroll();
      default:
        break;
    }
  }

  void _selectById<T>(
    List<T> items,
    String Function(T) idOf,
    void Function(String?) setId, {
    int direction = 1,
  }) {
    if (items.isEmpty) {
      setId(null);
      return;
    }
    final currentId = _activeSelectionId();
    final currentIndex = items.indexWhere((item) => idOf(item) == currentId);
    int nextIndex;
    if (currentIndex < 0) {
      nextIndex = direction > 0 ? 0 : items.length - 1;
    } else {
      nextIndex = (currentIndex + direction).clamp(0, items.length - 1).toInt();
    }
    setId(idOf(items[nextIndex]));
  }

  String? _activeSelectionId() {
    return switch (_state.currentView) {
      View.devices => _state.selectedDeviceId,
      View.queue => _state.selectedQueueItemId,
      _ => null,
    };
  }

  void _activate() {
    switch (_state.currentView) {
      case View.devices:
        final conn = _port.snapshot.connection.state;
        if (conn == TuiConnectionState.ready ||
            conn == TuiConnectionState.connecting ||
            conn == TuiConnectionState.authenticating ||
            conn == TuiConnectionState.awaitingAuthKey ||
            conn == TuiConnectionState.reconnecting) {
          _state.openConfirmation(
            title: '断开设备',
            message: '断开当前设备连接？',
            confirmLabel: '断开',
            dangerous: true,
            onConfirm: () => dispatch(const DisconnectCommand()),
          );
        } else {
          dispatch(const ConnectCommand());
        }
      case View.queue:
        final id = _state.selectedQueueItemId;
        if (id != null) {
          final item =
              _port.snapshot.queue.where((q) => q.itemId == id).firstOrNull;
          if (item != null && item.isFailure && item.canRetry) {
            dispatch(const RetryQueueItemCommand());
          }
        }
      default:
        break;
    }
  }

  void _type(String text) {
    if (_state.showAuthKey) {
      _state.authKeyInput += text;
    } else if (_state.showImport) {
      _state.importInput += text;
    } else if (_state.showLogExport) {
      _state.logExportPathInput += text;
    } else if (_state.showAddDevice) {
      switch (_state.manualDeviceField) {
        case ManualDeviceField.address:
          _state.manualAddress += text;
        case ManualDeviceField.model:
          break;
        case ManualDeviceField.displayName:
          _state.manualDisplayName += text;
      }
    } else if (_state.currentView == View.settings) {
      switch (_state.settingsField) {
        case SettingsField.segmentInterval:
          _state.segmentIntervalInput += text;
        case SettingsField.massWindowSize:
          _state.massWindowSizeInput += text;
      }
    } else if (_state.activeDecisionId != null) {
      final field = _activeDecisionField();
      if (field != null) {
        _state.decisionValues[field.fieldId] =
            '${_state.decisionValues[field.fieldId] ?? ''}$text';
      }
    }
  }

  void _backspace() {
    if (_state.showAuthKey && _state.authKeyInput.isNotEmpty) {
      _state.authKeyInput =
          _state.authKeyInput.substring(0, _state.authKeyInput.length - 1);
    } else if (_state.showImport && _state.importInput.isNotEmpty) {
      _state.importInput =
          _state.importInput.substring(0, _state.importInput.length - 1);
    } else if (_state.showLogExport &&
        _state.logExportPathInput.isNotEmpty) {
      _state.logExportPathInput = _state.logExportPathInput
          .substring(0, _state.logExportPathInput.length - 1);
    } else if (_state.showAddDevice) {
      switch (_state.manualDeviceField) {
        case ManualDeviceField.address:
          if (_state.manualAddress.isNotEmpty) {
            _state.manualAddress = _state.manualAddress
                .substring(0, _state.manualAddress.length - 1);
          }
        case ManualDeviceField.model:
          break;
        case ManualDeviceField.displayName:
          if (_state.manualDisplayName.isNotEmpty) {
            _state.manualDisplayName = _state.manualDisplayName
                .substring(0, _state.manualDisplayName.length - 1);
          }
      }
    } else if (_state.currentView == View.settings) {
      switch (_state.settingsField) {
        case SettingsField.segmentInterval:
          if (_state.segmentIntervalInput.isNotEmpty) {
            _state.segmentIntervalInput = _state.segmentIntervalInput
                .substring(0, _state.segmentIntervalInput.length - 1);
          }
        case SettingsField.massWindowSize:
          if (_state.massWindowSizeInput.isNotEmpty) {
            _state.massWindowSizeInput = _state.massWindowSizeInput
                .substring(0, _state.massWindowSizeInput.length - 1);
          }
      }
    } else if (_state.activeDecisionId != null) {
      final field = _activeDecisionField();
      if (field != null) {
        final value = _state.decisionValues[field.fieldId] ?? '';
        if (value.isNotEmpty) {
          _state.decisionValues[field.fieldId] =
              value.substring(0, value.length - 1);
        }
      }
    }
  }

  int _maxLogScroll() {
    final logCount = _port.snapshot.logs.where((entry) {
      final levelMatches =
          _state.logsFilter == null || entry.level == _state.logsFilter;
      final categoryMatches = _state.logsCategoryFilter == null ||
          entry.category == _state.logsCategoryFilter;
      return levelMatches && categoryMatches;
    }).length;
    // The diagnostic viewport differs between the persistent wide-layout
    // column and the standalone narrow logs view. Keep this in sync with
    // TuiApp._renderDiagnosticColumn and LogsView respectively.
    final visibleRows =
        (_terminal.rows - (_state.wideLayout ? 9 : 11))
            .clamp(1, _terminal.rows)
            .toInt();
    return (logCount - visibleRows).clamp(0, logCount).toInt();
  }

  bool _allowed(String action) {
    if (_port.snapshot.allowedActions.contains(action)) return true;
    _notice(_port.snapshot.blockedReasons[action] ?? '当前状态不允许此操作', isError: true);
    return false;
  }

  TuiLogCategory? _nextCategory(TuiLogCategory? current) {
    final values = <TuiLogCategory?>[null, ...TuiLogCategory.values];
    final index = values.indexOf(current);
    return values[(index + 1) % values.length];
  }

  TuiQueueItem? _queueItem(String id) => _port.snapshot.queue
      .where((item) => item.itemId == id)
      .firstOrNull;

  bool _itemAllowed(TuiQueueItem item, String action) {
    if (item.allowedActions.contains(action)) return true;
    _notice(item.blockedReason ?? '当前队列条目不允许此操作', isError: true);
    return false;
  }

  bool _recoveryAllowed(String action) {
    final snapshot = _port.snapshot;
    if (snapshot.allowedActions.contains(action) ||
        snapshot.recovery.allowedActions.contains(action)) {
      return true;
    }
    _notice(
      snapshot.blockedReasons[action] ??
          snapshot.recovery.message ??
          '当前恢复状态不允许此操作',
      isError: true,
    );
    return false;
  }

  void _selectManualModel(int delta) {
    final models = _port.snapshot.supportedModels
        .where((model) => model.supported)
        .toList();
    if (models.isEmpty) {
      _notice('当前没有可选型号', isError: true);
      return;
    }
    final currentIndex =
        models.indexWhere((model) => model.modelId == _state.selectedModelId);
    final nextIndex = currentIndex < 0
        ? (delta < 0 ? models.length - 1 : 0)
        : (currentIndex + delta).clamp(0, models.length - 1).toInt();
    _state.selectedModelId = models[nextIndex].modelId;
  }

  void _openPendingDecision() {
    final decision = _port.snapshot.pendingDecisions.firstOrNull;
    if (decision == null) {
      _notice('没有待确认项');
      return;
    }
    _state.activeDecisionId = decision.decisionId;
    _state.decisionFieldIndex = 0;
    _state.decisionFocusConfirm = false;
    _state.decisionValues
      ..clear()
      ..addEntries(
        decision.inputFields.map((field) => MapEntry(field.fieldId, '')),
      );
  }

  void _cycleDecisionField() {
    final decision = _activeDecision();
    if (decision == null || decision.inputFields.isEmpty) return;
    _state.decisionFieldIndex =
        (_state.decisionFieldIndex + 1) % decision.inputFields.length;
  }

  TuiPendingDecision? _activeDecision() {
    final id = _state.activeDecisionId;
    if (id == null) return null;
    return _port.snapshot.pendingDecisions
        .where((item) => item.decisionId == id)
        .firstOrNull;
  }

  TuiDecisionInputField? _activeDecisionField() {
    final decision = _activeDecision();
    if (decision == null || decision.inputFields.isEmpty) return null;
    final index = _state.decisionFieldIndex
        .clamp(0, decision.inputFields.length - 1)
        .toInt();
    return decision.inputFields[index];
  }

  /// Adjusts frontend selection when the current ID no longer exists in the
  /// latest snapshot. Keeps the ID if present, otherwise selects the nearest
  /// remaining item or clears the selection.
  void reconcileSelection() {
    final snapshot = _port.snapshot;
    final deviceIds = snapshot.devices.map((d) => d.deviceId).toSet();
    if (state.selectedDeviceId != null &&
        !deviceIds.contains(state.selectedDeviceId)) {
      state.selectedDeviceId =
          snapshot.devices.isEmpty ? null : snapshot.devices.first.deviceId;
    }
    final itemIds = snapshot.queue.map((q) => q.itemId).toSet();
    if (state.selectedQueueItemId != null &&
        !itemIds.contains(state.selectedQueueItemId)) {
      state.selectedQueueItemId =
          snapshot.queue.isEmpty ? null : snapshot.queue.first.itemId;
    }
  }

  void _notice(String message, {bool isError = false}) {
    _onNotice?.call(message, isError: isError);
  }

  static String _commandName(UiCommand command) =>
      command.runtimeType.toString();

  void dispose() {
    _disposed = true;
  }

  AppState get state => _state;
}
