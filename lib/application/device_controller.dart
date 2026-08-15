import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../domain/device_profile.dart';
import '../domain/auth_key_binding.dart';
import '../domain/last_device_store.dart';
import '../domain/auto_connect_preference.dart';
import '../domain/connection_issue.dart';
import '../domain/install_models.dart';
import '../domain/install_checkpoint_store.dart';
import '../domain/install_metadata_reader.dart';
import '../domain/install_task.dart';
import '../domain/watch_app.dart';
import '../domain/mass_ack_idle_timeout.dart';
import '../domain/transfer_settings_store.dart';
import '../domain/protocol/auth_handshake.dart';
import '../domain/protocol/session_cipher.dart';
import '../domain/protocol/spp_protocol.dart';
import '../domain/protocol/mass_transfer.dart';
import '../domain/protocol/zau.dart';
import '../domain/protocol/transport_constants.dart';
import '../domain/verification_gate.dart';
import '../platform/ble_transport.dart';
import '../platform/auth_key_store.dart';
import '../platform/system_time_info.dart';
import '../platform/security_scoped_file_access.dart';
import 'diagnostic_log_service.dart';

typedef QueueInstallPreparer =
    Future<InstallRequest?> Function(InstallRequest request);

class DeviceController extends ChangeNotifier {
  DeviceController({
    BleTransport? transport,
    InstallCheckpointStore? checkpointStore,
    InstallMetadataReader? metadataReader,
    DiagnosticLogService? logger,
  }) : _transport = transport ?? BleTransport(logger: logger ?? appLogger),
       _checkpointStore = checkpointStore ?? InstallCheckpointStore(),
       _metadataReader = metadataReader ?? InstallMetadataReader(),
       _logger = logger ?? appLogger {
    _authKeyBindingsReady = _restoreAuthKeyBindings();
    unawaited(_authKeyBindingsReady);
    _lastDeviceRestore = _restoreLastDeviceRecord();
    unawaited(_lastDeviceRestore);
    _autoConnectPreferenceReady = _restoreAutoConnectPreference();
    unawaited(_autoConnectPreferenceReady);
    _transferSettingsReady = _restoreTransferSettings();
    _checkpointRestore = _restoreInstallCheckpoint();
    _bluetoothInitialization = _initializeBluetoothState();
  }

  final BleTransport _transport;
  final ConnectionIssueTracker _connectionIssues = ConnectionIssueTracker();
  final InstallCheckpointStore _checkpointStore;
  final InstallMetadataReader _metadataReader;
  final DiagnosticLogService _logger;
  late final Future<void> _transferSettingsReady;
  late final Future<void> _checkpointRestore;
  late final Future<void> _authKeyBindingsReady;
  late final Future<void> _lastDeviceRestore;
  late final Future<void> _autoConnectPreferenceReady;
  bool _disposed = false;
  bool _hasActiveGattTransport = false;

  /// Completes after the persisted install checkpoint has been inspected.
  ///
  /// Restoration only rebuilds local retry state. It never connects to a
  /// device, authenticates, or sends protocol data.
  Future<void> get checkpointRestoreReady => _checkpointRestore;

  /// Completes after persisted authkey/device bindings have been restored.
  Future<void> get authKeyBindingsReady => _authKeyBindingsReady;
  StreamSubscription<DiscoveredEventArgs>? _scanSubscription;
  StreamSubscription<BluetoothLowEnergyStateChangedEventArgs>?
  _bluetoothStateSubscription;
  bool _isScanning = false;
  int _scanGeneration = 0;
  BluetoothLowEnergyState _bluetoothState = BluetoothLowEnergyState.unknown;
  bool _bluetoothStateKnown = false;
  bool _authorizationRequestInFlight = false;
  late final Future<void> _bluetoothInitialization;
  Timer? _scanResultsFlushTimer;
  Timer? _savedDeviceRequestTimer;
  // High-frequency communication tracing must not rebuild every listening
  // widget for each packet. Entries are still retained in full; only the UI
  // notification is coalesced for a short interval.
  Timer? _logNotifyTimer;
  bool _logNotificationPending = false;
  static const _logNotifyInterval = Duration(milliseconds: 100);
  final Map<String, DiscoveredEventArgs> _pendingScanResults = {};

  List<DiscoveredEventArgs> scanResults = const [];
  Peripheral? connectedDevice;
  String? connectedDeviceName;
  String? connectedClassicAddress;
  DeviceProfile? connectedProfile;
  Peripheral? _lastPeripheral;
  bool _connectionAttemptInProgress = false;
  bool _connectionTearingDown = false;
  // The shell must not infer that every inactive state is a normal disconnect.
  // A failed classic pairing/SDP/RFCOMM attempt should remain visible so the
  // user can read the native failure and retry deliberately.
  bool _resumeScanningAfterConnectionEnd = false;
  List<GATTService> services = const [];
  InstallTask? latestTask;

  /// 固件版本（从版本特征读取，如 2.1.2）。
  String? connectedFirmwareVersion;

  /// 设备电量（%），连接后随状态查询获取；null 表示未取到（UI 不渲染）。
  int? batteryPercent;

  /// 设备存储（字节），null 表示未取到。
  int? storageUsedBytes;
  int? storageTotalBytes;
  List<WatchAppItem> installedWatchApps = const [];
  bool watchAppsLoading = false;
  String? watchAppsError;
  int _sessionEpoch = 0;
  // A quick-app read and an uninstall both own the same visible loading/error
  // state. A disconnect clears [watchAppsLoading] immediately so a new
  // session may start before an old RFCOMM waiter has finished. Keep separate
  // read and operation generations so an old response, ACK, timeout, or
  // finally block cannot overwrite the newer session's state.
  int _quickAppReadGeneration = 0;
  int _quickAppOperationGeneration = 0;
  int? _quickAppsLoadedSessionEpoch;
  int? _statusRefreshEpoch;
  LastDeviceRecord? _lastDeviceRecord;
  String? _requestedSavedDeviceId;
  String? _requestedSavedDeviceName;
  bool _autoConnectInFlight = false;
  int? _authKeyRejectedEpoch;

  bool get statusRefreshInProgress => _statusRefreshEpoch != null;

  /// Monotonic identity of the authenticated connection used by the quick-app
  /// page. UI work that awaits a controller command can use this to avoid
  /// presenting the outcome of an operation from a previous connection.
  int get quickAppSessionEpoch => _sessionEpoch;

  /// True after this authenticated session has produced a device list, or an
  /// uninstall request has been transport-confirmed and applied locally.
  /// The page uses this to avoid issuing another automatic command merely
  /// because the user changed navigation tabs. Explicit refreshes remain
  /// available.
  bool get quickAppsLoadedForCurrentSession =>
      _quickAppsLoadedSessionEpoch == _sessionEpoch;

  /// A pending user-facing connection notice. Diagnostic details remain in
  /// [logs] and are never used as presentation state.
  ConnectionIssue? get pendingConnectionIssue => _connectionIssues.pending;

  int get consecutiveConnectionFailures =>
      _connectionIssues.consecutivePortConflicts;

  void dismissConnectionIssue(int id) {
    if (_connectionIssues.acknowledge(id)) notifyListeners();
  }

  bool recordConnectionFailureForTest(Object error) {
    final published = _connectionIssues.recordConnectionFailure(error);
    if (published) notifyListeners();
    return published;
  }

  bool recordUnexpectedDisconnectForTest() {
    final published = _connectionIssues.recordUnexpectedDisconnect();
    if (published) notifyListeners();
    return published;
  }

  void _advanceSessionEpoch() {
    _sessionEpoch++;
    _statusRefreshEpoch = null;
    _quickAppReadGeneration++;
    _quickAppOperationGeneration++;
    _quickAppsLoadedSessionEpoch = null;
    watchAppsLoading = false;
    watchAppsError = null;
    // A recovery task belongs to the session that scheduled it.  Invalidating
    // the session must also prevent an older task from clearing state owned by
    // a newer connection.
    _postAuthRecoveryEpoch = null;
  }

  /// 安装队列（串行执行）。
  final List<QueueEntry> installQueue = [];
  bool _queueRunning = false;
  static const queueSuccessDisplayDuration = Duration(milliseconds: 2400);
  QueueInstallPreparer? queueInstallPreparer;

  bool get queueRunning => _queueRunning;

  int get pendingCount =>
      installQueue.where((e) => e.stage == QueueStage.waiting).length;
  int get installingCount =>
      installQueue.where((e) => e.stage == QueueStage.installing).length;

  /// 把安装请求加入队列，等待用户从队列页开始串行安装。
  void enqueue(InstallRequest request) {
    installQueue.add(QueueEntry(request: request));
    _log('已加入安装队列（当前待安装 $pendingCount 项）');
    notifyListeners();
  }

  /// 将失败、取消或状态未知的条目重新放回串行队列。
  ///
  /// 重试会重新发送同一安装包。MassPrepare 由设备返回可信的已发送
  /// 偏移，因此不会因为本地界面重试而强制从零开始。
  bool retryQueueEntry(QueueEntry entry) {
    if (!installQueue.contains(entry) ||
        entry.stage == QueueStage.installing ||
        !entry.canRetry) {
      return false;
    }
    unawaited(_retryQueueEntry(entry));
    return true;
  }

  Future<void> _retryQueueEntry(QueueEntry entry) async {
    entry
      ..stage = QueueStage.waiting
      ..message = null;
    notifyListeners();
    if (!await _restoreInstallSessionForRetry()) {
      if (installQueue.contains(entry) && entry.stage == QueueStage.waiting) {
        entry
          ..stage = QueueStage.stateUnknown
          ..message = '未能恢复鉴权会话；请重新连接设备后再次尝试安装。';
        notifyListeners();
      }
      return;
    }
    if (installQueue.contains(entry) && entry.stage == QueueStage.waiting) {
      await runQueue(preferredEntry: entry);
    }
  }

  /// 从队列移除（安装中禁止）。
  void removeQueueEntry(int index) {
    if (index < 0 || index >= installQueue.length) return;
    if (installQueue[index].stage == QueueStage.installing) return;
    installQueue.removeAt(index);
    notifyListeners();
  }

  /// 拖拽排序（安装中禁止）。
  void reorderQueue(int oldIndex, int newIndex) {
    if (installQueue.any((e) => e.stage == QueueStage.installing)) return;
    if (oldIndex < 0 || oldIndex >= installQueue.length) return;
    if (newIndex > installQueue.length) newIndex = installQueue.length;
    if (oldIndex < newIndex) newIndex--;
    final entry = installQueue.removeAt(oldIndex);
    installQueue.insert(newIndex, entry);
    notifyListeners();
  }

  /// 只清空已成功完成的条目，失败或取消项保留以便重试。
  void clearCompletedQueue() {
    installQueue.removeWhere((entry) => entry.stage == QueueStage.done);
    notifyListeners();
  }

  /// Dismisses the current installation summary without changing queue history.
  void clearLatestTask() {
    latestTask = null;
    notifyListeners();
  }

  /// 串行执行队列。
  Future<void> runQueue({QueueEntry? preferredEntry}) async {
    if (_queueRunning) return;
    _queueRunning = true;
    try {
      while (true) {
        // An explicit retry may target the requested item, while failed
        // history remains visible and does not block later waiting entries.
        final preferred =
            preferredEntry != null &&
                installQueue.contains(preferredEntry) &&
                preferredEntry.stage == QueueStage.waiting
            ? preferredEntry
            : null;
        final next =
            preferred ??
            installQueue
                .where((e) => e.stage == QueueStage.waiting)
                .firstOrNull;
        if (next == null) break;
        preferredEntry = null;
        final preparer = queueInstallPreparer;
        if (preparer != null) {
          try {
            final prepared = await preparer(next.request);
            if (!installQueue.contains(next) ||
                next.stage != QueueStage.waiting) {
              break;
            }
            if (prepared == null) {
              // The user declined a required preflight confirmation. This is
              // an abandoned add-to-queue action, not a waiting installation.
              installQueue.remove(next);
              notifyListeners();
              continue;
            }
            next.request = prepared;
          } on Object catch (exception) {
            next.message = '安装前检查失败：$exception';
            _log(next.message!);
            notifyListeners();
            break;
          }
        }
        final taskBeforeInstall = latestTask;
        next.stage = QueueStage.installing;
        next.message = null;
        notifyListeners();
        await startInstall(next.request);
        final task = latestTask;
        final producedTask =
            task != null &&
            !identical(task, taskBeforeInstall) &&
            task.kind == next.request.kind &&
            task.fileName == next.request.metadata.fileName &&
            task.md5Hex == next.request.metadata.md5Hex;
        if (!producedTask) {
          next
            ..stage = QueueStage.waiting
            ..message = task?.message;
          notifyListeners();
          break;
        }
        if (task.stage == InstallStage.waitingForProtocol ||
            task.stage == InstallStage.idle ||
            task.stage == InstallStage.validating ||
            task.stage == InstallStage.transferring ||
            task.stage == InstallStage.awaitingDevice) {
          next
            ..stage = QueueStage.waiting
            ..message = task.message;
          notifyListeners();
          break;
        }
        next.stage = switch (task.stage) {
          InstallStage.succeeded => QueueStage.done,
          InstallStage.cancelled => QueueStage.cancelled,
          InstallStage.failed => QueueStage.failed,
          InstallStage.stateUnknown => QueueStage.stateUnknown,
          _ => QueueStage.failed,
        };
        next.message = task.message;
        if (next.isFailure) next.failureAttempts++;
        notifyListeners();

        if (next.stage == QueueStage.done) {
          await Future<void>.delayed(queueSuccessDisplayDuration);
          if (_disposed) break;
          if (installQueue.contains(next) && next.stage == QueueStage.done) {
            installQueue.remove(next);
            _log('安装成功条目已从队列移除：' + next.request.metadata.fileName);
            notifyListeners();
          }
        }

        // Keep failed items for retry, but continue with later waiting items
        // whenever the authenticated transport is still usable.
      }
    } finally {
      _queueRunning = false;
      notifyListeners();
    }
  }

  String? error;
  bool sessionReady = false;
  bool sppConnecting = false;
  ConnectionMode connectionMode = ConnectionMode.modern;

  /// authkey（绑定 token，32 位 hex = 16 字节）。连接前由 UI 弹窗输入。
  /// 校验规则：32 位十六进制字符。协议验证通过前仅保留在内存中；只有
  /// f=27 成功后才会写入对应设备的安全存储。
  String? authKey;
  String? _authKeyDeviceId;
  List<AuthKeyBinding> authKeyBindings = const [];
  int _authKeyPersistenceGeneration = 0;
  Future<void> _savedDeviceMutationTail = Future<void>.value();

  /// 运行日志（时间戳 + 消息），供真机验证时观察 BLE/协议行为。
  List<String> logs = const [];

  static final RegExp _authKeyPattern = RegExp(r'^[0-9a-fA-F]{32}$');
  static final _secureStorage = AuthKeyStore();
  static final _authKeyBindingStore = AuthKeyBindingStore();
  static final _lastDeviceStore = LastDeviceStore();
  static final _autoConnectPreferenceStore = AutoConnectPreferenceStore();
  static final _transferSettings = TransferSettingsStore();

  /// Delay between consecutive Mass writes. The negotiated L1 receive window
  /// still limits outstanding packets, so a small value does not bypass flow
  /// control or ACK validation.
  int segmentIntervalMs = 5;
  int massWindowSize = 50;
  bool autoTimeSync = false;

  /// Whether startup should reconnect the persisted last authenticated device.
  /// Enabled by default to preserve the historical Wristload behavior.
  bool autoConnectLastDeviceEnabled = AutoConnectPreferenceStore.defaultEnabled;
  bool _autoTimeSyncChangedByUser = false;

  Future<void> get autoConnectPreferenceReady => _autoConnectPreferenceReady;

  Future<void> _restoreAutoConnectPreference() async {
    try {
      autoConnectLastDeviceEnabled = await _autoConnectPreferenceStore.read();
    } on Object catch (exception) {
      autoConnectLastDeviceEnabled = AutoConnectPreferenceStore.defaultEnabled;
      _log('读取启动自动连接偏好失败：$exception');
    }
    notifyListeners();
  }

  void setAutoConnectLastDeviceEnabled(bool enabled) {
    if (autoConnectLastDeviceEnabled == enabled) return;
    autoConnectLastDeviceEnabled = enabled;
    unawaited(_autoConnectPreferenceStore.write(enabled));
    _log('启动时自动连接上次设备已' + (enabled ? '开启' : '关闭') + '。');
    notifyListeners();
  }

  void _persistTransferSettings() {
    unawaited(
      _transferSettings.write(
        segmentIntervalMs: segmentIntervalMs,
        massWindowSize: massWindowSize,
        autoTimeSync: autoTimeSync,
      ),
    );
  }

  void setAutoTimeSync(bool value) {
    if (autoTimeSync == value) return;
    _autoTimeSyncChangedByUser = true;
    autoTimeSync = value;
    _persistTransferSettings();
    _log('自动同步时间与时区已${value ? '开启' : '关闭'}。');
    notifyListeners();
    if (value && sessionReady && !installInProgress && !timeSyncInProgress) {
      unawaited(syncSystemTime(automatic: true));
    }
  }

  void setSegmentIntervalMs(int value) {
    final clamped = value.clamp(1, 20);
    if (segmentIntervalMs == clamped) return;
    segmentIntervalMs = clamped;
    _persistTransferSettings();
    _log('传输窗口间隔已设为 $clamped ms，下一个发送窗口起生效。');
    notifyListeners();
  }

  void setMassWindowSize(int value) {
    final clamped = value.clamp(1, 50).toInt();
    if (massWindowSize == clamped) return;
    massWindowSize = clamped;
    _persistTransferSettings();
    _log(
      clamped <= 3
          ? '每窗口分片数已设为 $clamped（设备协商范围内）。'
          : '每窗口分片数已设为 $clamped（实验模式，超过设备协商值 3）。',
    );
    notifyListeners();
  }

  Future<void> _restoreTransferSettings() async {
    final saved = await _transferSettings.read();
    final interval = saved.segmentIntervalMs;
    final window = saved.massWindowSize;
    if (!_autoTimeSyncChangedByUser) {
      autoTimeSync = saved.autoTimeSync ?? false;
    }
    if (interval != null && interval >= 1 && interval <= 20) {
      segmentIntervalMs = interval;
    }
    if (window != null && window >= 1 && window <= 50) {
      massWindowSize = window;
    }
    notifyListeners();
  }

  /// A peripheral selected by the scanner is only a transport candidate.
  ///
  /// Desktop classic-Bluetooth pairing and RFCOMM socket setup can both
  /// succeed before the device accepts the authkey handshake. Those stages
  /// must never unlock the device page, installation controls, or the global
  /// "connected" indicator. Legacy experimental GATT devices deliberately
  /// retain their established-transport behavior because they do not yet have
  /// a verified authkey protocol.
  bool get isConnected {
    if (connectedDevice == null) return false;
    final profile = connectedProfile;
    // A profile can be cleared while an old native callback is still in
    // flight.  Treat that state as unverified instead of falling back to
    // "connectedDevice != null", which was the source of phantom device
    // pages on macOS.  Tests and established sessions without a profile still
    // have to present an explicit verified session.
    if (profile == null) return sessionReady;
    return profile.generation != ProtocolGeneration.v2Vela || sessionReady;
  }

  /// True while a system pairing request, RFCOMM connection, or authkey
  /// handshake is in flight.  This is intentionally distinct from
  /// [isConnected] so the UI can show progress without exposing device
  /// actions for an unverified candidate.
  bool get isConnecting => _connectionAttemptInProgress || sppConnecting;

  /// Native teardown must finish before a new scan or connection begins.
  bool get isConnectionBusy => isConnecting || _connectionTearingDown;

  /// True only after a user explicitly requests a disconnect. Pairing, SDP,
  /// RFCOMM, and authentication failures deliberately leave this false so the
  /// home page preserves their diagnostic context rather than hiding it with
  /// a fresh scan.
  bool get shouldResumeScanningAfterConnectionEnd =>
      _resumeScanningAfterConnectionEnd;

  bool get isScanning => _isScanning;

  BluetoothLowEnergyState get bluetoothState => _bluetoothState;

  bool get bluetoothStateKnown => _bluetoothStateKnown;

  bool get bluetoothAvailable =>
      _bluetoothState == BluetoothLowEnergyState.poweredOn;

  /// Whether BLE is conclusively unavailable for a disconnected device.
  ///
  /// A macOS saved-device RFCOMM session can authenticate before
  /// CoreBluetooth publishes its first state transition.  In that window the
  /// manager remains [unknown], which is an initialization state rather than
  /// an adapter failure and must not be rendered as a red warning.
  bool get bluetoothUnavailable =>
      bluetoothStateKnown &&
      (bluetoothState == BluetoothLowEnergyState.poweredOff ||
          bluetoothState == BluetoothLowEnergyState.unauthorized ||
          bluetoothState == BluetoothLowEnergyState.unsupported);

  /// Unknown keeps the original scan behavior during adapter initialization.
  bool get canScan => !_bluetoothStateKnown || bluetoothAvailable;

  String get bluetoothStateMessage => switch (_bluetoothState) {
    BluetoothLowEnergyState.poweredOff => '蓝牙已关闭，请在系统设置中开启蓝牙。',
    BluetoothLowEnergyState.unauthorized => '蓝牙权限未授权，请允许 Wristload 使用蓝牙。',
    BluetoothLowEnergyState.unsupported => '当前系统不支持蓝牙低功耗扫描。',
    BluetoothLowEnergyState.unknown => '正在检测蓝牙状态…',
    BluetoothLowEnergyState.poweredOn => '蓝牙可用。',
  };

  bool get hasAuthKey => authKey != null;

  Peripheral? get _connectionTarget => connectedDevice ?? _lastPeripheral;

  /// Clears every field that can make a failed transport candidate look like
  /// an active device. The authkey is deliberately retained: a failed
  /// connection must not silently discard user input or a previously saved
  /// credential.
  void _clearConnectionCandidate({bool keepBusy = false}) {
    connectedDevice = null;
    _lastPeripheral = null;
    connectedDeviceName = null;
    connectedClassicAddress = null;
    connectedProfile = null;
    services = const [];
    connectedFirmwareVersion = null;
    lastTimeSyncSummary = null;
    batteryPercent = null;
    storageUsedBytes = null;
    storageTotalBytes = null;
    installedWatchApps = const [];
    watchAppsLoading = false;
    watchAppsError = null;
    sessionReady = false;
    _authenticatedAt = null;
    _resumeAuthenticatedSession = false;
    _sessionCipher = null;
    _hasActiveGattTransport = false;
    if (!keepBusy) {
      sppConnecting = false;
      _connectionAttemptInProgress = false;
    }
  }

  void _finishFailedConnection(String message) {
    error = message;
    _resumeScanningAfterConnectionEnd = false;
    _clearSppHandshakeState();
    _clearConnectionCandidate();
    _connectionTearingDown = false;
    _postAuthRecoveryEpoch = null;
    _log(message);
    notifyListeners();
  }

  Future<void> _initializeBluetoothState() async {
    try {
      _bluetoothStateSubscription = _transport.bluetoothStateChanged.listen(
        (event) => _handleBluetoothState(event.state),
        onError: (Object error, StackTrace stackTrace) {
          _logBluetooth(
            '蓝牙状态监听失败：$error',
            level: DiagnosticLogLevel.warning,
            fields: <String, Object?>{
              'errorType': error.runtimeType.toString(),
            },
          );
        },
      );
      _handleBluetoothState(_transport.bluetoothState);
    } on Object catch (error) {
      // Unsupported test hosts should retain the original scan behavior.
      _logBluetooth(
        '蓝牙状态初始化不可用：$error',
        level: DiagnosticLogLevel.debug,
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _requestBluetoothAuthorization();
    }
  }

  Future<void> _requestBluetoothAuthorization() async {
    if (_authorizationRequestInFlight || _disposed) return;
    _authorizationRequestInFlight = true;
    try {
      final authorized = await _transport.requestBluetoothAuthorization();
      _logBluetooth(
        authorized ? '蓝牙权限已授权。' : '蓝牙权限未授权。',
        level: authorized
            ? DiagnosticLogLevel.info
            : DiagnosticLogLevel.warning,
        fields: <String, Object?>{'authorized': authorized},
      );
      if (!authorized) {
        _handleBluetoothState(BluetoothLowEnergyState.unauthorized);
      }
    } on Object catch (error) {
      _handleBluetoothState(BluetoothLowEnergyState.unauthorized);
      _logBluetooth(
        '蓝牙权限申请失败：$error',
        level: DiagnosticLogLevel.warning,
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
    } finally {
      _authorizationRequestInFlight = false;
    }
  }

  void _handleBluetoothState(BluetoothLowEnergyState state) {
    final changed = !_bluetoothStateKnown || _bluetoothState != state;
    _bluetoothState = state;
    _bluetoothStateKnown = true;
    if (!changed) return;
    _logBluetooth(
      '蓝牙状态：${state.name}',
      fields: <String, Object?>{
        'state': state.name,
        'available': state == BluetoothLowEnergyState.poweredOn,
        'platform': defaultTargetPlatform.name,
      },
    );
    if (state == BluetoothLowEnergyState.unauthorized &&
        defaultTargetPlatform == TargetPlatform.android) {
      unawaited(_requestBluetoothAuthorization());
    }
    if (state != BluetoothLowEnergyState.poweredOn && _isScanning) {
      unawaited(stopScan());
    }
    notifyListeners();
  }

  void _logBluetooth(
    String message, {
    DiagnosticLogLevel level = DiagnosticLogLevel.info,
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    final entry = switch (level) {
      DiagnosticLogLevel.trace => _logger.trace(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.BleGattDriver',
        event: 'bluetooth_state',
        fields: fields,
      ),
      DiagnosticLogLevel.debug => _logger.debug(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.BleGattDriver',
        event: 'bluetooth_state',
        fields: fields,
      ),
      DiagnosticLogLevel.info => _logger.info(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.BleGattDriver',
        event: 'bluetooth_state',
        fields: fields,
      ),
      DiagnosticLogLevel.warning => _logger.warning(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.BleGattDriver',
        event: 'bluetooth_state',
        fields: fields,
      ),
      DiagnosticLogLevel.error => _logger.error(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.BleGattDriver',
        event: 'bluetooth_state',
        fields: fields,
      ),
      DiagnosticLogLevel.fatal => _logger.fatal(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.BleGattDriver',
        event: 'bluetooth_state',
        fields: fields,
      ),
    };
    _appendLogEntry(entry);
  }

  Future<void> _restoreAuthKeyBindings() async {
    final generation = _authKeyPersistenceGeneration;
    try {
      final bindings = await _authKeyBindingStore.read();
      if (generation != _authKeyPersistenceGeneration) return;
      authKeyBindings = bindings;
      notifyListeners();
    } on Object {
      _log('无法读取历史绑定设备列表');
    }
  }

  Future<void> _restoreLastDeviceRecord() async {
    try {
      _lastDeviceRecord = await _lastDeviceStore.read();
      if (_lastDeviceRecord != null) {
        _log('已恢复上次连接设备标识；等待启动扫描匹配。');
      }
    } on Object catch (exception) {
      _log('读取上次连接设备标识失败：$exception');
    }
  }

  /// Requests a one-shot startup reconnect. Only an identity is persisted;
  /// the authkey is read from secure storage after a matching scan result.
  Future<bool> autoConnectLastDevice() async {
    await _autoConnectPreferenceReady;
    if (!autoConnectLastDeviceEnabled) {
      _log('启动自动连接已关闭，跳过上次设备连接。');
      return false;
    }
    await Future.wait(<Future<void>>[
      _lastDeviceRestore,
      _authKeyBindingsReady,
    ]);
    final record = _lastDeviceRecord;
    if (_disposed || record == null || isConnectionBusy || isConnected) {
      return false;
    }
    // On macOS a V2 binding has a confirmed CoreBluetooth-ID -> classic
    // Bluetooth mapping. Reuse it directly, without waiting for a BLE
    // advertisement that may not be emitted during application startup.
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      AuthKeyBinding? binding;
      for (final candidate in authKeyBindings) {
        if (_sameDeviceId(candidate.id, record.id)) {
          binding = candidate;
          break;
        }
      }
      if (binding != null) {
        final profile = DeviceProfile.matchAdvertisementName(binding.name);
        if (profile != null &&
            profile.generation == ProtocolGeneration.v2Vela) {
          _log('启动自动连接使用已保存 macOS 蓝牙 ID 直连，跳过扫描。');
          return connectSavedDevice(binding);
        }
      }
    }
    _requestedSavedDeviceId = record.id;
    _requestedSavedDeviceName = record.name;
    _autoConnectInFlight = false;
    _savedDeviceRequestTimer?.cancel();
    _savedDeviceRequestTimer = Timer(const Duration(seconds: 12), () {
      if (_requestedSavedDeviceId != null && !_autoConnectInFlight) {
        _log('启动自动连接未在扫描窗口内找到上次设备。');
        _requestedSavedDeviceId = null;
        _requestedSavedDeviceName = null;
      }
    });
    await beginScan();
    unawaited(_tryConnectRequestedSavedDevice());
    return _isScanning;
  }

  /// Starts a scan-backed connection for a device selected from the history.
  /// A CoreBluetooth peripheral cannot be reconstructed from a stored UUID.
  Future<bool> connectSavedDevice(AuthKeyBinding binding) async {
    if (_disposed || isConnectionBusy || isConnected) return false;
    await _authKeyBindingsReady;
    if (!await useSavedAuthKeyForDevice(binding.id)) {
      error = '已保存设备缺少可用 authkey，请手动输入后再连接。';
      _log(error!);
      notifyListeners();
      return false;
    }
    // macOS CoreBluetooth peripherals cannot be reconstructed from a stored
    // UUID, but the V2 SPP bridge deliberately persists the UUID -> paired
    // classic-device mapping after authentication. Reuse that mapping
    // directly for historical devices; this avoids a discovery window (and
    // the fragile BLE advertisement refresh) while keeping GATT devices on
    // the existing scan-backed path below.
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final profile = DeviceProfile.matchAdvertisementName(binding.name);
      UUID? uuid;
      try {
        uuid = UUID.fromString(binding.id);
      } on Object {
        uuid = null;
      }
      if (profile != null &&
          profile.generation == ProtocolGeneration.v2Vela &&
          uuid != null) {
        _requestedSavedDeviceId = null;
        _requestedSavedDeviceName = null;
        _savedDeviceRequestTimer?.cancel();
        _savedDeviceRequestTimer = null;
        _autoConnectInFlight = true;
        final peripheral = _PersistedPeripheral(uuid);
        _connectionIssues.selectTarget(binding.id);
        _authKeyRejectedEpoch = null;
        _resumeScanningAfterConnectionEnd = false;
        _clearConnectionCandidate();
        _connectionAttemptInProgress = true;
        _connectionTearingDown = false;
        _lastPeripheral = peripheral;
        connectedDeviceName = binding.name.trim();
        connectedClassicAddress = null;
        connectedProfile = profile;
        _log('历史设备使用 macOS 持久化蓝牙 ID 直连，跳过 BLE 扫描与系统配对。');
        notifyListeners();
        try {
          await _connectDesktopV2(peripheral, profile, directIdentity: true);
        } finally {
          _autoConnectInFlight = false;
        }
        return true;
      }
      _log('历史设备 ID 或型号不可用于 macOS RFCOMM 直连，回退扫描匹配。');
    }
    _requestedSavedDeviceId = binding.id;
    _requestedSavedDeviceName = binding.name;
    _autoConnectInFlight = false;
    _savedDeviceRequestTimer?.cancel();
    _savedDeviceRequestTimer = Timer(const Duration(seconds: 20), () {
      if (_requestedSavedDeviceId != null && !_autoConnectInFlight) {
        _log('历史设备连接请求超时：扫描中未找到匹配设备。');
        _requestedSavedDeviceId = null;
        _requestedSavedDeviceName = null;
        notifyListeners();
      }
    });
    await beginScan();
    unawaited(_tryConnectRequestedSavedDevice());
    return true;
  }

  Future<void> _tryConnectRequestedSavedDevice() async {
    final requestedId = _requestedSavedDeviceId;
    if (_disposed ||
        requestedId == null ||
        _autoConnectInFlight ||
        isConnectionBusy ||
        isConnected) {
      return;
    }
    final exact = scanResults.where(
      (result) => _sameDeviceId(result.peripheral.uuid.toString(), requestedId),
    );
    DiscoveredEventArgs? match = exact.firstOrNull;
    if (match == null && (_requestedSavedDeviceName?.isNotEmpty ?? false)) {
      final name = _requestedSavedDeviceName!.trim().toLowerCase();
      final named = scanResults
          .where(
            (result) =>
                (result.advertisement.name ?? '').trim().toLowerCase() == name,
          )
          .toList(growable: false);
      if (named.length == 1) match = named.single;
    }
    if (match == null) return;
    _autoConnectInFlight = true;
    try {
      if (!await useSavedAuthKeyForDevice(match.peripheral.uuid.toString())) {
        _log('历史设备匹配成功，但安全存储中没有 authkey；不会重复请求。');
        return;
      }
      _log('已匹配保存设备，开始自动连接。');
      await connect(match);
    } finally {
      _autoConnectInFlight = false;
      _requestedSavedDeviceId = null;
      _requestedSavedDeviceName = null;
      _savedDeviceRequestTimer?.cancel();
      _savedDeviceRequestTimer = null;
    }
  }

  Future<String?> readAuthKeyFor(String id) async {
    try {
      final value = await _secureStorage.readFor(id);
      if (value == null || !_authKeyPattern.hasMatch(value)) return null;
      return value.toLowerCase();
    } on Object {
      return null;
    }
  }

  bool _sameDeviceId(String left, String right) =>
      left.trim().toLowerCase() == right.trim().toLowerCase();

  /// Whether the in-memory authkey can be used for [deviceId].  A null owner
  /// represents a key deliberately applied by a tool and not yet associated
  /// with a device; the next explicit connection may claim it for that device.
  bool hasAuthKeyForDevice(String deviceId) =>
      authKey != null &&
      (_authKeyDeviceId == null || _sameDeviceId(_authKeyDeviceId!, deviceId));

  /// Restores an authkey only from the secure record for [deviceId].  This
  /// prevents a credential saved for one band from being silently reused for a
  /// different discovered device.
  Future<bool> useSavedAuthKeyForDevice(String deviceId) async {
    final id = deviceId.trim();
    if (id.isEmpty) return false;
    if (authKey != null && _authKeyDeviceId == null) {
      _authKeyDeviceId = id;
      _log('已将当前运行中的 authkey 关联到本次选择的设备；验证成功后才会保存。');
      notifyListeners();
      return true;
    }
    if (hasAuthKeyForDevice(id)) return true;

    final saved = await readAuthKeyFor(id);
    if (saved == null) return false;
    _authKeyPersistenceGeneration++;
    authKey = saved;
    _authKeyDeviceId = id;
    error = null;
    _log('已读取此设备已保存的 authkey；将进行应用层身份校验。');
    notifyListeners();
    return true;
  }

  /// Serializes every application-owned saved-device mutation.  The metadata
  /// store contains the complete binding list, so per-device parallel writes
  /// would still lose updates.  More importantly, a delete queued after an
  /// f=27 save must be the final persistent operation for that device.
  Future<T> _enqueueSavedDeviceMutation<T>(Future<T> Function() mutation) {
    final queued = _savedDeviceMutationTail.then<T>((_) => mutation());
    _savedDeviceMutationTail = queued.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return queued;
  }

  Future<void> _rememberAuthKeyBindingNow({
    required String id,
    required String name,
    required String normalizedKey,
  }) async {
    try {
      await _secureStorage.writeFor(id, normalizedKey);
    } on Object {
      // Keep metadata even when platform secure storage is unavailable.
    }
    final next = [
      ...authKeyBindings.where((binding) => !_sameDeviceId(binding.id, id)),
      AuthKeyBinding(id: id, name: name, uuid: id, updatedAt: DateTime.now()),
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    authKeyBindings = next;
    try {
      await _authKeyBindingStore.write(next);
    } on Object catch (exception) {
      // This call can run after f=27 succeeds. A metadata persistence failure
      // must not turn an authenticated RFCOMM session into an async error.
      _log('设备 authkey 绑定元数据保存失败：$exception');
    }
    notifyListeners();
  }

  /// Saves an explicitly edited binding without changing the active session's
  /// in-memory authkey. This is also used after f=27 confirms authentication.
  Future<void> rememberAuthKeyBinding({
    required String id,
    required String name,
    required String key,
  }) {
    final deviceId = id.trim();
    final normalized = key.trim().toLowerCase();
    if (deviceId.isEmpty || !_authKeyPattern.hasMatch(normalized)) {
      return Future<void>.value();
    }
    _authKeyPersistenceGeneration++;
    return _enqueueSavedDeviceMutation(
      () => _rememberAuthKeyBindingNow(
        id: deviceId,
        name: name.trim().isEmpty ? '已保存设备' : name.trim(),
        normalizedKey: normalized,
      ),
    );
  }

  /// Persists the records which are earned only after f=27 succeeds. Keeping
  /// the classic identity and authkey mutation in the same queue means an
  /// immediately-following user deletion always wins over this async work.
  Future<void> _persistAuthenticatedDevice({
    required Peripheral device,
    required String advertisedName,
    required String? key,
  }) {
    final normalized = key?.trim().toLowerCase();
    _authKeyPersistenceGeneration++;
    return _enqueueSavedDeviceMutation(() async {
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        await _confirmMacOSRfcommIdentity(device, advertisedName);
      }
      if (normalized != null && _authKeyPattern.hasMatch(normalized)) {
        await _rememberAuthKeyBindingNow(
          id: device.uuid.toString(),
          name: advertisedName.trim().isEmpty ? '已保存设备' : advertisedName,
          normalizedKey: normalized,
        );
      }
      final id = device.uuid.toString();
      final name = advertisedName.trim().isEmpty
          ? '已保存设备'
          : advertisedName.trim();
      await _lastDeviceStore.write(id: id, name: name);
      _lastDeviceRecord = LastDeviceRecord(id: id, name: name);
    });
  }

  bool get installInProgress => _installInProgress;

  bool get timeSyncInProgress => _timeSyncInProgress;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  void setConnectionMode(ConnectionMode mode) {
    if (isConnectionBusy || isConnected || connectionMode == mode) return;
    connectionMode = mode;
    _log(
      mode == ConnectionMode.modern
          ? '已切换到现代设备模式（V2 RFCOMM 安装）。'
          : '已切换到经典设备实验模式；只开放安全连接与协议取证，不开放安装。',
    );
    notifyListeners();
  }

  void reportError(String message) {
    error = message;
    _log(message);
  }

  void _appendLogEntry(DiagnosticLogEntry entry) {
    final next = [...logs, entry.displayText];
    // Keep diagnostics useful without retaining an unbounded session history.
    logs = next.length <= 500 ? next : next.sublist(next.length - 500);

    // Trace/debug/info records can arrive in bursts while RFCOMM is moving
    // data. Schedule one rebuild per interval instead of one rebuild per
    // packet. Error and fatal records remain immediate so failures are visible
    // without delay. This changes only presentation scheduling, never the
    // journal or transport path.
    final urgent =
        entry.level == DiagnosticLogLevel.error ||
        entry.level == DiagnosticLogLevel.fatal;
    // Keep the journal hot path allocation-free when no widget is listening.
    // The next build reads the retained log state directly, so a delayed
    // notification is unnecessary and would leave fake timers in tests.
    if (_disposed || !hasListeners) return;
    if (urgent) {
      _logNotifyTimer?.cancel();
      _logNotifyTimer = null;
      _logNotificationPending = false;
      notifyListeners();
      return;
    }
    if (_logNotificationPending) return;
    _logNotificationPending = true;
    _logNotifyTimer = Timer(_logNotifyInterval, () {
      _logNotifyTimer = null;
      if (_disposed) {
        _logNotificationPending = false;
        return;
      }
      _logNotificationPending = false;
      notifyListeners();
    });
  }

  void _log(String message) {
    final level = classifyLogLevel(message);
    final category = classifyLogMessage(message);
    final fields = <String, Object?>{'source': 'DeviceController'};
    final entry = switch (level) {
      DiagnosticLogLevel.trace => _logger.trace(
        message,
        category: category,
        component: 'wristload.DeviceManager',
        event: 'device_manager',
        fields: fields,
      ),
      DiagnosticLogLevel.debug => _logger.debug(
        message,
        category: category,
        component: 'wristload.DeviceManager',
        event: 'device_manager',
        fields: fields,
      ),
      DiagnosticLogLevel.info => _logger.info(
        message,
        category: category,
        component: 'wristload.DeviceManager',
        event: 'device_manager',
        fields: fields,
      ),
      DiagnosticLogLevel.warning => _logger.warning(
        message,
        category: category,
        component: 'wristload.DeviceManager',
        event: 'device_manager',
        fields: fields,
      ),
      DiagnosticLogLevel.error => _logger.error(
        message,
        category: category,
        component: 'wristload.DeviceManager',
        event: 'device_manager',
        fields: fields,
      ),
      DiagnosticLogLevel.fatal => _logger.fatal(
        message,
        category: category,
        component: 'wristload.DeviceManager',
        event: 'device_manager',
        fields: fields,
      ),
    };
    _appendLogEntry(entry);
  }

  void _logQuickAppRead(
    String message, {
    DiagnosticLogLevel level = DiagnosticLogLevel.info,
    required String event,
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    final entry = switch (level) {
      DiagnosticLogLevel.trace => _logger.trace(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.DeviceManager',
        event: event,
        fields: fields,
      ),
      DiagnosticLogLevel.debug => _logger.debug(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.DeviceManager',
        event: event,
        fields: fields,
      ),
      DiagnosticLogLevel.info => _logger.info(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.DeviceManager',
        event: event,
        fields: fields,
      ),
      DiagnosticLogLevel.warning => _logger.warning(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.DeviceManager',
        event: event,
        fields: fields,
      ),
      DiagnosticLogLevel.error => _logger.error(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.DeviceManager',
        event: event,
        fields: fields,
      ),
      DiagnosticLogLevel.fatal => _logger.fatal(
        message,
        category: DiagnosticLogCategory.communication,
        component: 'wristload.DeviceManager',
        event: event,
        fields: fields,
      ),
    };
    _appendLogEntry(entry);
  }

  void _logWire(
    String direction,
    List<int> bytes, {
    String phase = 'rfcomm',
    int? sequence,
    int? channel,
    int? opCode,
    int? generation,
  }) {
    final fields = <String, Object?>{
      'source': 'DeviceController',
      'transport': 'RFCOMM/SPP',
      'platform': defaultTargetPlatform.name,
      'direction': direction,
      'phase': phase,
      'bytes': bytes.length,
      'wireHex': _wireHex(bytes),
      if (sequence != null) 'sequence': sequence,
      if (channel != null) 'channel': channel,
      if (opCode != null) 'opCode': opCode,
      if (generation != null) 'generation': generation,
    };
    final entry = _logger.trace(
      'RFCOMM $direction $phase',
      category: DiagnosticLogCategory.communication,
      component: 'wristload.DeviceManager',
      event: 'rfcomm_${direction.toLowerCase()}_${phase.toLowerCase()}',
      fields: fields,
    );
    _appendLogEntry(entry);
  }

  void clearLogs() {
    logs = const [];
    _logger.clear();
    notifyListeners();
  }

  /// 校验并设置本次连接使用的 authkey。
  ///
  /// 这里不持久化凭据。持久化必须等到设备 f=27 鉴权确认后，由
  /// [rememberAuthKeyBinding] 写入该设备自己的安全存储项，避免取消配对或
  /// RFCOMM 失败也留下可自动复用的密钥。
  Future<bool> setAuthKey(String key, {String? deviceId}) async {
    final trimmed = key.trim();
    if (!_authKeyPattern.hasMatch(trimmed)) {
      error = 'authkey 必须是 32 位十六进制字符（收到 ${trimmed.length} 个字符）';
      _log('authkey 输入无效：${trimmed.length} 个字符');
      notifyListeners();
      return false;
    }
    _authKeyPersistenceGeneration++;
    authKey = trimmed.toLowerCase();
    final owner = deviceId?.trim();
    _authKeyDeviceId = owner == null || owner.isEmpty ? null : owner;
    // A user-initiated scan deliberately dismisses the prior failure. Failed
    // pairing/SDP/RFCOMM attempts never invoke this path automatically.
    _resumeScanningAfterConnectionEnd = false;
    error = null;
    _log('authkey 已载入当前连接；设备确认后才会保存到安全存储。');
    notifyListeners();
    return true;
  }

  /// Forget the authkey associated with [deviceId].
  ///
  /// Set [clearActiveKey] only when this is the currently authenticated (or
  /// currently selected) device. Deleting a historical device must not erase
  /// the credential currently used by another live session.
  Future<bool> _forgetAuthKeyForDeviceNow(
    String deviceId, {
    bool clearActiveKey = true,
    bool reportResult = true,
  }) async {
    final id = deviceId.trim();
    final clearedActiveKey =
        clearActiveKey &&
        (id.isEmpty ||
            _authKeyDeviceId == null ||
            _sameDeviceId(_authKeyDeviceId!, id));
    if (clearedActiveKey) {
      authKey = null;
      _authKeyDeviceId = null;
      error = null;
    }
    var persistentDeletionSucceeded = true;

    if (id.isNotEmpty) {
      try {
        await _secureStorage.deleteFor(id);
      } on Object catch (exception) {
        persistentDeletionSucceeded = false;
        _log('设备 authkey 删除失败（继续清理其他保存项）：$exception');
      }
    }
    if (clearedActiveKey) {
      try {
        await _secureStorage.delete();
      } on Object catch (exception) {
        persistentDeletionSucceeded = false;
        _log('旧版全局 authkey 删除失败：$exception');
      }
    }

    if (id.isNotEmpty) {
      final next = authKeyBindings
          .where((binding) => !_sameDeviceId(binding.id, id))
          .toList(growable: false);
      authKeyBindings = next;
      try {
        await _authKeyBindingStore.write(next);
      } on Object catch (exception) {
        persistentDeletionSucceeded = false;
        _log('设备 authkey 绑定元数据删除失败：$exception');
      }
      try {
        await _lastDeviceStore.clearFor(id);
        if (_lastDeviceRecord != null &&
            _sameDeviceId(_lastDeviceRecord!.id, id)) {
          _lastDeviceRecord = null;
        }
      } on Object catch (exception) {
        persistentDeletionSucceeded = false;
        _log('上次连接设备记录删除失败：$exception');
      }
    }
    if (reportResult) {
      _log(
        persistentDeletionSucceeded
            ? (id.isEmpty
                  ? '已取消保存 authkey；下次连接需要手动输入。'
                  : clearedActiveKey
                  ? '已取消保存当前设备 authkey；下次连接需要手动输入。'
                  : '已删除历史设备 authkey；当前设备凭据保持不变。')
            : '部分已保存 authkey 信息未能清除；请查看诊断日志。',
      );
      notifyListeners();
    }
    return persistentDeletionSucceeded;
  }

  Future<bool> forgetAuthKeyForDevice(
    String deviceId, {
    bool clearActiveKey = true,
  }) {
    _authKeyPersistenceGeneration++;
    return _enqueueSavedDeviceMutation(
      () =>
          _forgetAuthKeyForDeviceNow(deviceId, clearActiveKey: clearActiveKey),
    );
  }

  /// Deletes every application-owned saved record for [deviceId].
  ///
  /// This is intentionally separate from [disconnect]: it clears the authkey
  /// records, binding metadata, and (on macOS) Wristload's
  /// CoreBluetooth-to-classic identity association, while leaving the active
  /// RFCOMM/GATT session and the operating system Bluetooth pairing untouched.
  Future<bool> deleteSavedDevice(UUID deviceId) {
    return deleteSavedDeviceById(deviceId.toString());
  }

  /// Deletes a saved-device record even when it originated from an older
  /// binding format.  Valid UUIDs additionally remove Wristload's macOS
  /// CoreBluetooth-to-classic mapping; malformed legacy ids still lose their
  /// credentials and binding metadata.
  Future<bool> deleteSavedDeviceById(String deviceId) {
    final id = deviceId.trim();
    if (id.isEmpty) {
      _log('删除已保存设备被拒绝：设备标识为空。');
      return Future<bool>.value(false);
    }
    final activeId = connectedDevice?.uuid.toString();
    final clearActiveKey = sessionReady
        ? activeId != null && _sameDeviceId(activeId, id)
        : _authKeyDeviceId != null && _sameDeviceId(_authKeyDeviceId!, id);
    UUID? uuid;
    try {
      uuid = UUID.fromString(id);
    } on Object {
      // Legacy malformed ids still have an authkey and binding to remove.
    }
    _authKeyPersistenceGeneration++;
    return _enqueueSavedDeviceMutation(() async {
      var deleted = await _forgetAuthKeyForDeviceNow(
        id,
        clearActiveKey: clearActiveKey,
        reportResult: false,
      );
      if (uuid == null) {
        _log('已保存设备没有可用的经典蓝牙标识；已删除本地凭据和历史绑定。');
      } else {
        try {
          await _transport.forgetRfcommIdentity(uuid);
        } on Object catch (exception) {
          deleted = false;
          _log('已保存设备经典蓝牙身份映射删除失败：$exception');
        }
      }
      _log(
        deleted
            ? clearActiveKey
                  ? '已删除当前设备的已保存记录；当前连接和系统蓝牙配对保持不变，下次连接需要手动输入 authkey。'
                  : '已删除历史设备的已保存记录；当前连接和系统蓝牙配对保持不变。'
            : '已从当前会话删除设备凭据，但部分已保存设备信息未能清除；重启后可能仍会恢复。',
      );
      notifyListeners();
      return deleted;
    });
  }

  /// Compatibility wrapper for callers that only need to remove a binding.
  /// The richer deletion path also clears the saved-device and macOS identity
  /// records owned by Wristload.
  Future<void> removeAuthKeyBinding(String id) async {
    await deleteSavedDeviceById(id);
  }

  /// Deletes the current device's application-owned saved state without
  /// disconnecting it.
  Future<bool> deleteCurrentSavedDevice() {
    final device = connectedDevice;
    if (device == null) {
      _log('删除已保存设备被拒绝：当前没有已连接设备。');
      return Future<bool>.value(false);
    }
    return deleteSavedDevice(device.uuid);
  }

  /// Forget the saved authkey for the currently displayed connected device.
  Future<bool> forgetCurrentDeviceAuthKey() {
    return forgetAuthKeyForDevice(
      connectedDevice?.uuid.toString() ?? '',
      clearActiveKey: true,
    );
  }

  /// Forget the global/legacy authkey. Kept for callers that do not have a
  /// device identifier (for example, settings or migration code).
  Future<bool> forgetAuthKey() {
    return forgetAuthKeyForDevice('', clearActiveKey: true);
  }

  Future<void> beginScan() async {
    if (_isScanning) {
      _log('BLE 扫描已在进行，忽略重复请求。');
      return;
    }
    if (isConnectionBusy) {
      _log('BLE 扫描请求被延后：设备连接或断开尚未完成。');
      return;
    }
    // Startup scanning and Android's runtime permission dialog can otherwise
    // race each other and produce a transient `permission_pending` failure.
    await _bluetoothInitialization;
    if (isConnectionBusy) {
      _log('BLE 扫描请求已取消：设备连接或断开尚未完成。');
      return;
    }
    final unavailable =
        _bluetoothStateKnown &&
        _bluetoothState != BluetoothLowEnergyState.poweredOn &&
        _bluetoothState != BluetoothLowEnergyState.unknown;
    if (unavailable) {
      error = bluetoothStateMessage;
      _logBluetooth(
        '扫描请求被拒绝：蓝牙不可用。',
        level: DiagnosticLogLevel.warning,
        fields: <String, Object?>{'state': _bluetoothState.name},
      );
      notifyListeners();
      return;
    }
    error = null;
    scanResults = const [];
    _pendingScanResults.clear();
    _scanResultsFlushTimer?.cancel();
    _scanResultsFlushTimer = null;
    _isScanning = true;
    _scanGeneration++;
    _log('开始 BLE 扫描…');
    try {
      await _scanSubscription?.cancel();
      _scanSubscription = _transport.discoveries.listen(
        (result) {
          if (!_isScanning) return;
          final name = (result.advertisement.name ?? '').trim();
          if (name.isEmpty) return;
          final id = result.peripheral.uuid.toString();
          final pending = _pendingScanResults[id];
          DiscoveredEventArgs? published;
          for (final item in scanResults) {
            if (item.peripheral.uuid.toString() == id) {
              published = item;
              break;
            }
          }
          final previous = pending ?? published;
          final previousName = (previous?.advertisement.name ?? '').trim();
          // RSSI changes arrive many times per second. Only rebuild when a device
          // is new or a later scan response provides a different/better name.
          if (previous != null && previousName == name) return;
          _pendingScanResults[id] = result;
          _scanResultsFlushTimer ??= Timer(
            const Duration(milliseconds: 250),
            _flushScanResults,
          );
        },
        onError: (Object value) {
          _isScanning = false;
          _scanResultsFlushTimer?.cancel();
          _scanResultsFlushTimer = null;
          error = '扫描失败：$value';
          _log('扫描失败：$value');
          notifyListeners();
        },
      );
      await _transport.startScan();
      if (!_isScanning) {
        await _transport.stopScan();
        return;
      }
      final desktopV2UsesRfcomm =
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS;
      _log(
        desktopV2UsesRfcomm
            ? '扫描已启动（已识别的 V2 设备将直接使用 RFCOMM，不经过 GATT）。'
            : '扫描已启动（点击连接将先读取 GATT 版本）。',
      );
    } catch (exception) {
      _isScanning = false;
      _scanResultsFlushTimer?.cancel();
      _scanResultsFlushTimer = null;
      error = '启动扫描失败：$exception';
      _log(error!);
      notifyListeners();
    }
  }

  /// Performs the macOS startup discovery warm-up.
  ///
  /// CoreBluetooth can report an initialized central before its first
  /// discovery session has actually started delivering advertisements. A
  /// short first session followed by a clean stop/restart gives the native
  /// run loop a chance to settle and avoids leaving the app in the state where
  /// the first home-page scan silently returns no devices. This is deliberately
  /// separate from [beginScan] so user-triggered scans retain their original
  /// lifecycle.
  Future<void> beginStartupScan() async {
    if (_disposed || isConnectionBusy || isConnected || _isScanning) return;
    await _bluetoothInitialization;
    if (_disposed ||
        isConnectionBusy ||
        isConnected ||
        _isScanning ||
        !canScan) {
      return;
    }

    await beginScan();
    if (_disposed || !_isScanning || isConnectionBusy || isConnected) return;
    final startupGeneration = _scanGeneration;

    // Keep the first native discovery session alive for at least one run-loop
    // turn. The generation check makes a user stop/restart win over warm-up.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (_disposed ||
        !_isScanning ||
        _scanGeneration != startupGeneration ||
        isConnectionBusy ||
        isConnected) {
      return;
    }

    _log('启动扫描预热：重启 BLE 扫描以刷新 macOS 发现会话。');
    await stopScan();
    if (_disposed || isConnectionBusy || isConnected || !canScan) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (_disposed || isConnectionBusy || isConnected || _isScanning) return;
    await beginScan();
  }

  Future<void> stopScan() async {
    if (!_isScanning) return;
    _isScanning = false;
    _scanGeneration++;
    _flushScanResults();
    notifyListeners();
    try {
      await _transport.stopScan();
      _log('BLE 扫描已停止。');
    } catch (exception) {
      error = '停止扫描失败：$exception';
      _log(error!);
    }
  }

  void _flushScanResults() {
    _scanResultsFlushTimer = null;
    if (_disposed || _pendingScanResults.isEmpty) return;
    final updates = Map<String, DiscoveredEventArgs>.fromEntries(
      scanResults.map(
        (item) => MapEntry(item.peripheral.uuid.toString(), item),
      ),
    );
    updates.addAll(_pendingScanResults);
    _pendingScanResults.clear();
    final indexed = updates.values
        .toList(growable: false)
        .asMap()
        .entries
        .toList();
    indexed.sort((left, right) {
      final leftKnown =
          DeviceProfile.matchAdvertisementName(
            left.value.advertisement.name ?? '',
          ) !=
          null;
      final rightKnown =
          DeviceProfile.matchAdvertisementName(
            right.value.advertisement.name ?? '',
          ) !=
          null;
      if (leftKnown != rightKnown) return leftKnown ? -1 : 1;
      return left.key.compareTo(right.key);
    });
    scanResults = indexed
        .map((entry) => entry.value)
        .take(20)
        .toList(growable: false);
    notifyListeners();
    if (_isScanning) {
      unawaited(_tryConnectRequestedSavedDevice());
    }
  }

  Future<void> connect(DiscoveredEventArgs result) async {
    final advertisedName = (result.advertisement.name ?? '').trim();
    final profile = DeviceProfile.matchAdvertisementName(advertisedName);
    if (profile == null) {
      error = advertisedName.isEmpty
          ? '连接被拒绝：设备没有可用于型号校验的名称。'
          : '连接被拒绝：无法从设备名称识别受支持型号（$advertisedName）。';
      _log(error!);
      notifyListeners();
      return;
    }
    final needsExperimentalMode =
        profile.generation != ProtocolGeneration.v2Vela;
    if (needsExperimentalMode &&
        connectionMode != ConnectionMode.classicExperimental) {
      error = '该设备使用旧版传输；请切换“经典设备（实验）”模式后连接。';
      _log(error!);
      notifyListeners();
      return;
    }
    if (!needsExperimentalMode &&
        connectionMode == ConnectionMode.classicExperimental) {
      error = '该设备属于现代 V2 型号；请切换“现代设备”模式后连接。';
      _log(error!);
      notifyListeners();
      return;
    }
    if (!hasAuthKeyForDevice(result.peripheral.uuid.toString())) {
      error = '连接被拒绝：请输入 32 位 authkey 以进行设备身份校验。';
      _log(error!);
      notifyListeners();
      return;
    }
    if (isConnectionBusy || isConnected) {
      error = isConnectionBusy ? '连接被拒绝：上一条连接或断开操作尚未完成。' : '连接被拒绝：请先断开当前设备。';
      _log(error!);
      notifyListeners();
      return;
    }
    _connectionIssues.selectTarget(result.peripheral.uuid.toString());
    _authKeyRejectedEpoch = null;
    // A new explicit attempt supersedes a previously scheduled recovery scan.
    _resumeScanningAfterConnectionEnd = false;
    // A scan result is only a candidate. Publish a connecting state before
    // opening macOS pairing so the UI never treats it as an active device.
    _clearConnectionCandidate();
    _connectionAttemptInProgress = true;
    _connectionTearingDown = false;
    _lastPeripheral = result.peripheral;
    connectedDeviceName = advertisedName;
    connectedClassicAddress = null;
    connectedProfile = profile;
    _log('设备名称校验通过：$advertisedName → ${profile.displayName}。');
    notifyListeners();
    if ((defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS) &&
        profile.generation == ProtocolGeneration.v2Vela) {
      await _connectDesktopV2(result.peripheral, profile);
      return;
    }
    await _connectPeripheral(result.peripheral);
  }

  /// Desktop V2 targets use classic Bluetooth SPP as the primary transport.
  /// macOS must not create a temporary GATT connection: CoreBluetooth UUIDs
  /// are opaque and are not the classic device identity.
  Future<void> _connectDesktopV2(
    Peripheral peripheral,
    DeviceProfile profile, {
    bool directIdentity = false,
  }) async {
    _advanceSessionEpoch();
    _hasActiveGattTransport = false;
    final connectionSession = _sessionEpoch;
    _connectionAttemptInProgress = true;
    error = null;
    sessionReady = false;
    connectedFirmwareVersion = null;
    lastTimeSyncSummary = null;
    batteryPercent = null;
    storageUsedBytes = null;
    storageTotalBytes = null;
    // Some V2 devices close the first RFCOMM socket immediately after f=27.
    // Allow one transport-only reconnect while retaining the confirmed keys.
    _postAuthReconnectAttempts = 0;
    _authenticatedAt = null;
    final platformName = defaultTargetPlatform == TargetPlatform.macOS
        ? 'macOS'
        : 'Windows';
    _log('已识别 ${profile.displayName}（V2），$platformName 使用无 GATT 的经典蓝牙 SPP 连接。');
    try {
      if (!directIdentity) {
        await _transport.stopScan();
      }
      if (connectionSession != _sessionEpoch) return;
      _isScanning = false;
      _scanResultsFlushTimer?.cancel();
      _scanResultsFlushTimer = null;
      services = const [];
      if (defaultTargetPlatform == TargetPlatform.macOS) {
        // Pairing is native and can fail before connectSpp() has a chance to
        // attach the EventChannel. Start the idempotent listener here so the
        // selector, pairing delegate, and eventual SDP events all reach the
        // diagnostic journal for this exact connection attempt.
        _transport.listenRfcommData();
        _log('已启用 macOS 经典蓝牙原生日志；等待系统配对与 SPP 建链事件。');
      }
      if (directIdentity) {
        _log('已复用已确认的 macOS 经典蓝牙身份映射；直接建立 RFCOMM。');
      } else {
        _log('先检查系统经典蓝牙配对，再建立 RFCOMM；不创建临时 GATT 链路。');
        connectedClassicAddress = await _transport.pairDevice(
          peripheral.uuid,
          advertisedName: connectedDeviceName,
        );
        if (connectionSession != _sessionEpoch) return;
      }
      // System pairing is not a successful application connection. Do not
      // publish a connected device until the pairing request has completed,
      // otherwise a cancelled macOS dialog leaves the home page showing a
      // false "connected" state.
      connectedDevice = peripheral;
      _lastPeripheral = peripheral;
      _log('经典蓝牙配对状态已确认；开始 SPP/RFCOMM 应用层鉴权。');
      await connectSpp();
    } on Object catch (exception) {
      if (connectionSession != _sessionEpoch) return;
      _finishFailedConnection('$platformName V2 快速连接失败：$exception');
      return;
    }
    notifyListeners();
  }

  /// 先建立 GATT 链路，再进入经验证的应用层 authkey 鉴权。
  Future<void> _connectPeripheral(
    Peripheral peripheral, {
    bool resetWindowsPairing = false,
  }) async {
    var ownsGattConnection = false;
    _advanceSessionEpoch();
    final connectionSession = _sessionEpoch;
    _connectionAttemptInProgress = true;
    error = null;
    sessionReady = false;
    connectedFirmwareVersion = null;
    lastTimeSyncSummary = null;
    batteryPercent = null;
    storageUsedBytes = null;
    storageTotalBytes = null;
    _postAuthReconnectAttempts = 0;
    _authenticatedAt = null;
    _log('正在连接 ${peripheral.uuid}（authkey 已就绪，等待应用层身份校验）…');
    try {
      await _transport.stopScan();
      if (connectionSession != _sessionEpoch) return;
      _isScanning = false;
      _scanResultsFlushTimer?.cancel();
      _scanResultsFlushTimer = null;
      if (resetWindowsPairing) {
        final removedOldPairing = await _transport.unpairIfPaired(
          peripheral.uuid,
        );
        if (removedOldPairing) {
          _log('检测到 Windows 旧配对，已在连接前删除设备记录。');
          _log('等待系统释放旧蓝牙链路后重新连接…');
          await Future<void>.delayed(const Duration(milliseconds: 800));
          if (connectionSession != _sessionEpoch) return;
        }
      }
      services = await _transport.connectAndDiscover(peripheral);
      ownsGattConnection = true;
      _hasActiveGattTransport = true;
      if (connectionSession != _sessionEpoch) {
        try {
          await _transport
              .disconnect(peripheral)
              .timeout(const Duration(seconds: 5));
        } on Object {
          // A newer connection lifecycle owns presentation state.
        } finally {
          _hasActiveGattTransport = false;
        }
        return;
      }
      connectedDevice = peripheral;
      _lastPeripheral = peripheral;
      _log('GATT 已连接，发现 ${services.length} 个服务：');
      for (final service in services) {
        _log('  服务 ${service.uuid}');
      }
      await _inspectMiWearService();
      await _readStandardBatteryLevel();
      if (connectionSession != _sessionEpoch) return;
      if (connectedProfile?.generation != ProtocolGeneration.v2Vela) {
        final transport = switch (connectedProfile?.generation) {
          ProtocolGeneration.v1Vela => '旧 Vela V1',
          ProtocolGeneration.huamiZepp => 'Huami/Zepp',
          _ => '尚未确认',
        };
        _log('旧设备实验连接完成：已保留 GATT 链路用于服务枚举与取证（$transport）。');
        _log('该型号的独立鉴权与安装协议尚未完成真机验证，不会发送猜测性私有帧。');
        _connectionAttemptInProgress = false;
        _connectionTearingDown = false;
        notifyListeners();
        return;
      }
      _log(
        'GATT 链路已建立。应用层 authkey 身份校验尚待真机帧验证，'
        '私有帧仍受安全门控保护，当前未宣称“设备已就绪”。',
      );
      final desktopPairing =
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.macOS;
      if (desktopPairing) {
        final platformName = defaultTargetPlatform == TargetPlatform.macOS
            ? 'macOS'
            : 'Windows';
        _log('正在检查 $platformName 系统配对状态…');
        // Native pairDevice is intentionally idempotent: an existing pairing
        // is reused, while an unpaired but connected LE device enters the one
        // real system pairing flow before any RFCOMM/auth traffic is sent.
        connectedClassicAddress = await _transport.pairDevice(
          peripheral.uuid,
          advertisedName: connectedDeviceName,
        );
        _log('系统配对状态已确认；后续直接复用，不删除设备记录。');
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      // 官方 SPP 连接是独立的经典蓝牙主通道。版本读取完成后释放并行 GATT
      // 连接，避免 Windows 同时维持 LE 与 RFCOMM 时回收串口 socket。
      try {
        await _transport
            .disconnect(peripheral)
            .timeout(const Duration(seconds: 5));
      } finally {
        ownsGattConnection = false;
        _hasActiveGattTransport = false;
      }
      _log('版本读取完成，已释放临时 GATT 链路；后续保持独立 SPP 长连接。');
      _log('开始自动建立 SPP 与 authkey 会话，无需再次点击。');
      await connectSpp();
    } catch (exception) {
      if (connectionSession != _sessionEpoch) return;
      if (ownsGattConnection) {
        try {
          await _transport
              .disconnect(peripheral)
              .timeout(const Duration(seconds: 5));
        } on Object {
          // 保留最初的连接/配对错误；这里仅释放本次建立的临时 GATT。
        }
        _hasActiveGattTransport = false;
      }
      if (defaultTargetPlatform == TargetPlatform.windows) {
        _log(
          '提示：GattCommunicationStatus=1 表示设备不可达（Unreachable）——'
          '常见于 Windows 蓝牙缓存/bonding 损坏。建议：手环亮屏并靠近电脑，'
          'Windows「设置→蓝牙」删除该设备记录后重新扫描连接，或重启 Windows 蓝牙。',
        );
      } else if (defaultTargetPlatform == TargetPlatform.macOS) {
        _log('提示：请确认已授予 Wristload 蓝牙权限，并在系统蓝牙设置中完成目标设备配对。');
      }
      _log('不会在 GATT 失败后回退发送 RFCOMM 协议帧；请先完成 HCI 验证。');
      _finishFailedConnection('连接或发现服务失败：$exception');
      return;
    }
    notifyListeners();
  }

  /// Reads the standard Bluetooth Battery Service when the temporary GATT
  /// link is available. V2 Windows fast-connect intentionally has no GATT
  /// link, so its battery value remains unknown instead of using a guessed
  /// private RFCOMM command.
  Future<void> _readStandardBatteryLevel() async {
    final device = connectedDevice;
    if (device == null) return;

    GATTCharacteristic? levelCharacteristic;
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() != BatteryGatt.serviceUuid) {
        continue;
      }
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid.toString().toLowerCase() ==
            BatteryGatt.levelUuid) {
          levelCharacteristic = characteristic;
          break;
        }
      }
      break;
    }

    if (levelCharacteristic == null) {
      _log(
        'Standard Battery Service (180F/2A19) not available; battery unknown.',
      );
      return;
    }
    try {
      final data = await _transport.readCharacteristic(
        device,
        levelCharacteristic,
      );
      final level = parseBatteryLevel(data);
      if (level == null) {
        _log(
          'Battery Level characteristic returned an invalid value; battery unknown.',
        );
        return;
      }
      batteryPercent = level;
      _log('Battery Level (2A19) = $level%');
    } catch (exception) {
      _log(
        'Battery Level characteristic read failed; battery unknown: $exception',
      );
    }
  }

  /// 检查 MI Wear 服务（0000fe95）的特征明细，并尝试读取版本特征
  /// 00000050（只读，不发送任何私有帧），用于对照逆向结论并判定 V1/V2。
  Future<void> _inspectMiWearService() async {
    const fe95 = '0000fe95-0000-1000-8000-00805f9b34fb';
    const versionUuid = '00000050-0000-1000-8000-00805f9b34fb';
    const notifyUuid = '0000005e-0000-1000-8000-00805f9b34fb';
    const writeUuid = '0000005f-0000-1000-8000-00805f9b34fb';
    GATTService? miService;
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() == fe95) {
        miService = service;
        break;
      }
    }
    if (miService == null) {
      _log('警告：未发现 MI Wear 服务 $fe95');
      return;
    }
    final chars = miService.characteristics;
    _log('MI Wear 服务 fe95 特征（${chars.length}）：');
    for (final characteristic in chars) {
      final uuid = characteristic.uuid.toString().toLowerCase();
      final role = switch (uuid) {
        versionUuid => ' ← 版本特征',
        notifyUuid => ' ← 通知特征',
        writeUuid => ' ← 写入特征',
        _ => '',
      };
      final properties = characteristic.properties
          .map((property) => property.name)
          .join('|');
      _log('    特征 $uuid$role  属性: $properties');
    }
    GATTCharacteristic? versionChar;
    for (final characteristic in chars) {
      if (characteristic.uuid.toString().toLowerCase() == versionUuid) {
        versionChar = characteristic;
        break;
      }
    }
    final device = connectedDevice;
    if (versionChar == null || device == null) {
      _log('未找到版本特征 $versionUuid（不发送任何帧）');
      return;
    }
    try {
      final data = await _transport.readCharacteristic(device, versionChar);
      final hex = data
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      if (data.length >= 3) {
        final version = '${data[0]}.${data[1]}.${data[2]}';
        connectedFirmwareVersion = version;
        final generation = data[0] == 0 ? 'V1（旧传输）' : 'V2（新传输）';
        _log('版本特征 $versionUuid = $hex → 固件 $version → $generation');
      } else {
        _log('版本特征 $versionUuid = $hex（不足 3 字节）');
      }
    } catch (exception) {
      _log('版本特征读取失败：$exception');
    }
  }

  /// SPP（经典蓝牙 RFCOMM）连接 + 鉴权握手——手环 9 系主通道。
  ///
  /// 流程（与 App/Gadgetbridge 一致）：
  /// RFCOMM 连接 → SessionConfig(START_SESSION) → 设备回 SessionConfig →
  /// 发 f=26（DATA 明文帧）→ 设备回 watchNonce → 完成 step1。
  Future<void> connectSpp({bool resumeSession = false}) async {
    if (sppConnecting) {
      _log('SPP 连接已在进行，忽略重复请求。');
      return;
    }
    if (!kSppAuthProtocolVerified) {
      _finishFailedConnection('SPP 鉴权被阻止：尚未完成真机验证。');
      return;
    }
    // SPP 主通道独立于 GATT：GATT 成功时用 connectedDevice，
    // GATT 失败回退时用 _lastPeripheral（仅需 MAC）。
    final device = connectedDevice ?? _lastPeripheral;
    if (device == null) {
      _finishFailedConnection('SPP 连接被拒绝：未找到连接目标。');
      return;
    }
    final connectionEpoch = ++_sppConnectionEpoch;
    _closingFailedSppEpoch = null;
    sessionReady = false;
    _connectionAttemptInProgress = true;
    _connectionTearingDown = false;
    sppConnecting = true;
    _authenticatedAt = null;
    _resumeAuthenticatedSession = resumeSession && _sessionCipher != null;
    notifyListeners();
    _log(
      _resumeAuthenticatedSession
          ? 'SPP（RFCOMM 串口）重连：${device.uuid}（复用已确认会话）…'
          : 'SPP（RFCOMM 串口）连接：${device.uuid}…',
    );
    _sppAcc = Accumulator();
    _sppSeq = 0;
    _sppAwaitingAuthConfirm = false;
    _pendingAuthConfirmEpoch = null;
    _pendingPhoneNonce = null;
    _pendingSessionKeys = null;
    if (!_resumeAuthenticatedSession) {
      _sessionCipher = null;
    }
    try {
      await _sppSub?.cancel();
      _sppSub = null;
      if (!_isCurrentSppConnection(connectionEpoch)) return;
      _transport.listenRfcommData();
      _sppSub = _transport.rfcommData.listen(
        (data) => _handleSppData(data, connectionEpoch),
        onError: (Object exception, StackTrace stackTrace) {
          if (!_isCurrentSppConnection(connectionEpoch)) return;
          _log('RFCOMM 数据流错误：$exception');
          _handleRfcommEof(connectionEpoch);
        },
        onDone: () => _handleRfcommEof(connectionEpoch),
      );
      _log('正在建立经典蓝牙 RFCOMM 链路，并独立检查 SPP 配对状态…');
      final platformName = switch (defaultTargetPlatform) {
        TargetPlatform.macOS => 'macOS',
        TargetPlatform.windows => 'Windows',
        TargetPlatform.android => 'Android',
        _ => '当前平台',
      };
      _log('  $platformName 的 BLE 连接不等于经典蓝牙 SPP 配对；若手环弹出请求，请在手环上确认。');
      final classicAddress = await _transport
          .connectRfcomm(device.uuid, advertisedName: connectedDeviceName)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw TimeoutException(
              'RFCOMM 2 秒内设备未响应',
              const Duration(seconds: 2),
            ),
          );
      if (!_isCurrentSppConnection(connectionEpoch)) return;
      connectedClassicAddress = classicAddress ?? connectedClassicAddress;
      _connectionIssues.connectionSucceeded();
      // These V2 targets expose their transport generation through the GATT
      // version characteristic. Repeated device tests show that they do not
      // answer the legacy BA-DC-FE SPP version query, while L1START succeeds
      // immediately. Skipping that fixed 8-second wait matches the effective
      // fallback path without changing the authenticated protocol.
      _sppAwaitingVersion = false;
      _log('RFCOMM 已连接；目标型号已识别为 V2，直接发送 L1START…');
      await _sppSendL1Start(connectionEpoch, device);
    } catch (exception) {
      if (_isCurrentSppConnection(connectionEpoch)) {
        await _cleanupFailedSppConnect(device, exception, connectionEpoch);
      }
      if (exception is TimeoutException &&
          exception.duration == const Duration(seconds: 2)) {
        _connectionIssues.recordRfcommTimeout();
        _log('SPP 超时：2 秒内设备未响应，已停止等待 RFCOMM 建链。$exception');
      } else {
        _connectionIssues.recordConnectionFailure(exception);
      }
      _log('SPP 连接失败：$exception');
      notifyListeners();
    }
  }

  StreamSubscription<Uint8List>? _sppSub;
  Accumulator _sppAcc = Accumulator();
  int _sppSeq = 0;
  bool _sppAwaitingVersion = false;
  bool _sppAwaitingAuthConfirm = false;
  Timer? _sppWatchdog;
  DateTime? _authenticatedAt;
  int _postAuthReconnectAttempts = 0;

  /// The session epoch that owns an in-flight post-auth RFCOMM recovery.
  /// A boolean is insufficient here: an older recovery's finally block can
  /// otherwise clear the marker for a newly started session.
  int? _postAuthRecoveryEpoch;
  bool get _recoveringPostAuthClose => _postAuthRecoveryEpoch != null;
  int _sppConnectionEpoch = 0;
  int? _closingFailedSppEpoch;
  int? _pendingAuthConfirmEpoch;
  bool _resumeAuthenticatedSession = false;
  SessionKeys? _pendingSessionKeys;
  SessionCipher? _sessionCipher;
  final Map<int, Completer<void>> _pendingAcks = {};
  final Set<int> _pendingMassAcks = {};
  final List<int> _pendingMassAckOrder = [];
  final Map<int, _MassProgressMarker> _pendingMassProgress = {};
  final StreamController<Zau> _businessResponses =
      StreamController<Zau>.broadcast();
  final Set<_BusinessWaiter> _completionWaiters = {};
  bool _installCancelled = false;
  bool _installInProgress = false;
  bool _timeSyncInProgress = false;
  String? lastTimeSyncSummary;
  Completer<void>? _installCancellation;
  Completer<Object>? _installTransportFailure;
  InstallRequest? _lastInstallRequest;
  DateTime? _lastSpeedSampleAt;
  int _lastSpeedSampleBytes = 0;
  double? _confirmedBytesPerSecond;
  Stopwatch? _installStopwatch;
  Stopwatch? _transferStopwatch;
  Duration? _completedTransferElapsed;
  int _transferStartConfirmedBytes = 0;

  /// Restores only a locally verifiable retry record. This deliberately does
  /// not reconnect, authenticate, or resume transmission: MassPrepare must be
  /// negotiated with the device again after the user reconnects.
  Future<void> _restoreInstallCheckpoint() async {
    final checkpoint = await _checkpointStore.load();
    if (checkpoint == null || _disposed) return;

    SecurityScopedFileLease? lease;
    try {
      lease = await SecurityScopedFileAccess.instance.acquire(
        ScopedFileRef(path: checkpoint.path, bookmark: checkpoint.bookmark),
      );
      if (_disposed) return;

      final expectedDataType = checkpoint.kind == InstallKind.watchface
          ? MassDataType.watchface
          : MassDataType.quickAppRpk;
      if (checkpoint.dataType != expectedDataType) {
        throw StateError('检查点的数据类型与安装包类型不一致');
      }

      // Re-read the complete package metadata while this single lease is held.
      // This validates size and both digests without trusting checkpoint fields
      // that may have been written by an older app version.
      final metadata = await _metadataReader.readWithLease(
        checkpoint.kind,
        lease,
      );
      if (_disposed) return;
      if (metadata.fileSize != checkpoint.fileSize ||
          metadata.md5Hex != checkpoint.md5Hex ||
          metadata.sha256Hex != checkpoint.sha256Hex) {
        throw StateError('源文件已变更，检查点不能恢复');
      }

      final source = ScopedFileRef(
        // The platform lease already returns the resolved native path.
        // Re-normalizing it with the host OS would corrupt macOS paths when
        // this state machine is exercised from a different test host.
        path: lease.file.path,
        bookmark: lease.file.bookmark,
      );
      final request = InstallRequest(
        kind: checkpoint.kind,
        path: source.path,
        metadata: metadata,
        source: source,
      );

      // Persist the resolved path and a refreshed security-scoped bookmark
      // before exposing the retry item to the UI.
      if (_disposed) return;
      await _checkpointStore.save(
        InstallCheckpoint(
          kind: checkpoint.kind,
          path: source.path,
          fileSize: metadata.fileSize,
          md5Hex: metadata.md5Hex,
          sha256Hex: metadata.sha256Hex,
          dataType: expectedDataType,
          lastAcknowledgedSegment: checkpoint.lastAcknowledgedSegment,
          phase: checkpoint.phase,
          faceId: metadata.faceId,
          packageName: metadata.packageName,
          versionCode: metadata.versionCode,
          bookmark: source.bookmark,
        ),
      );
      if (_disposed) return;

      _lastInstallRequest = request;
      installQueue.add(
        QueueEntry(request: request, stage: QueueStage.stateUnknown)
          ..message = '检测到上次未完成安装；请重新连接设备后手动重试。',
      );
      _log('已恢复上次安装记录；未自动连接或发送数据。');
    } on Object catch (exception) {
      if (!_disposed) {
        _log('未恢复安装检查点：$exception');
      }
    } finally {
      try {
        await lease?.close();
      } on Object catch (exception) {
        if (!_disposed) _log('恢复检查点后释放文件访问权限失败：$exception');
      }
    }
  }

  /// 处理 RFCOMM 收到的字节：先试 SppPacket（版本回包），再增量解析 L1 帧。
  bool _isCurrentSppConnection(int connectionEpoch) =>
      connectionEpoch == _sppConnectionEpoch &&
      _closingFailedSppEpoch != connectionEpoch;

  void _handleSppData(Uint8List data, int connectionEpoch) {
    if (!_isCurrentSppConnection(connectionEpoch)) return;
    if (data.isEmpty) {
      _handleRfcommEof(connectionEpoch);
      return;
    }
    _logWire('RX', data, phase: 'stream', generation: connectionEpoch);
    _log('RFCOMM 收到 ${data.length}B：${_hex(data)}');
    if (_sppAwaitingVersion) {
      final packet = SppProtocol.parseSppPacket(data);
      if (packet != null) {
        _sppAwaitingVersion = false;
        final (type, payload) = packet;
        _log('SppPacket 回包：type=$type payload=${_hex(payload)}');
        if (type == 106) {
          connectedFirmwareVersion = payload
              .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
              .join('.');
          _log('  ★ 设备版本：$connectedFirmwareVersion');
          _log('版本确认。发送 L1START_REQ（L1 CMD 帧）…');
          unawaited(_sendL1StartFromInboundPacket(connectionEpoch));
        } else {
          _log('  非版本回包（type=$type），仍尝试 L1START…');
          unawaited(_sendL1StartFromInboundPacket(connectionEpoch));
        }
        return;
      }
    }
    _sppAcc.buffer = [..._sppAcc.buffer, ...data];
    final packets = SppProtocol.parse(_sppAcc);
    for (final packet in packets) {
      _handleSppPacket(packet, connectionEpoch);
    }
  }

  void _handleRfcommEof(int connectionEpoch) {
    if (!_isCurrentSppConnection(connectionEpoch)) return;
    final device = connectedDevice ?? _lastPeripheral;
    if (!sessionReady && _sessionCipher == null) {
      _log('RFCOMM 已关闭（EOF）。');
      if (device == null) {
        _finishFailedConnection('RFCOMM 在设备身份验证前关闭。');
      } else {
        unawaited(
          _cleanupFailedSppConnect(
            device,
            StateError('RFCOMM 在设备身份验证前关闭'),
            connectionEpoch,
          ),
        );
      }
      return;
    }
    final authenticatedAt = _authenticatedAt;
    final isTransportTransition =
        authenticatedAt != null &&
        DateTime.now().difference(authenticatedAt) <
            const Duration(seconds: 2) &&
        _postAuthReconnectAttempts == 0 &&
        !_recoveringPostAuthClose &&
        !_installInProgress;
    final exception = StateError('RFCOMM 远端已关闭');
    final installFailure = _installTransportFailure;
    if (_installInProgress &&
        installFailure != null &&
        !installFailure.isCompleted) {
      installFailure.complete(exception);
    }
    for (final waiter in _pendingAcks.values) {
      if (!waiter.isCompleted) waiter.completeError(exception);
    }
    _pendingAcks.clear();
    _pendingMassAcks.clear();
    _pendingMassAckOrder.clear();
    _pendingMassProgress.clear();
    if (isTransportTransition) {
      _sppConnectionEpoch++;
      _advanceSessionEpoch();
      // A few V2 devices replace the first RFCOMM socket just after f=27.
      // Keep this state explicitly busy so the shell does not navigate home
      // or restart BLE scanning between the two authenticated transports.
      _connectionAttemptInProgress = true;
      sppConnecting = false;
      _clearSppHandshakeState();
      sessionReady = false;
      _authenticatedAt = null;
      _postAuthReconnectAttempts++;
      _log('检测到 f=27 后的 RFCOMM 传输切换；保留已确认会话密钥并自动重建链路。');
      unawaited(_recoverPostAuthRfcomm(_sessionEpoch));
    } else {
      _connectionIssues.recordUnexpectedDisconnect();
      _log('RFCOMM 长连接已被远端关闭；当前鉴权会话失效。');
      if (device == null) {
        _finishFailedConnection('RFCOMM 长连接已被远端关闭。');
      } else {
        unawaited(_cleanupFailedSppConnect(device, exception, connectionEpoch));
      }
      return;
    }
    notifyListeners();
  }

  Future<void> _recoverPostAuthRfcomm(int recoverySessionEpoch) async {
    final device = connectedDevice ?? _lastPeripheral;
    if (device == null ||
        _postAuthRecoveryEpoch != null ||
        recoverySessionEpoch != _sessionEpoch) {
      return;
    }
    _postAuthRecoveryEpoch = recoverySessionEpoch;
    try {
      try {
        await _transport
            .disconnectRfcomm(device.uuid)
            .timeout(const Duration(seconds: 5));
      } on Object {
        // 设备已经关闭旧 socket 时，本地清理仍可能返回错误。
      }
      if (recoverySessionEpoch != _sessionEpoch || connectedDevice == null) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (recoverySessionEpoch != _sessionEpoch || connectedDevice == null) {
        return;
      }
      _log('正在重建持久 SPP 传输；不会重复系统配对或 f=26/f=27。');
      await connectSpp(resumeSession: true);
    } on Object catch (exception) {
      if (recoverySessionEpoch == _sessionEpoch) {
        _finishFailedConnection('持久 SPP 会话重建失败：$exception');
      }
    } finally {
      if (_postAuthRecoveryEpoch == recoverySessionEpoch) {
        _postAuthRecoveryEpoch = null;
      }
    }
  }

  Future<void> _sppSendL1Start(int connectionEpoch, Peripheral device) async {
    if (!_isCurrentSppConnection(connectionEpoch)) return;
    final start = SppProtocol.buildL1StartRequest();
    _log('  L1START_REQ：${_hex(start)}');
    try {
      await _transport.rfcommWrite(device.uuid, start);
      if (!_isCurrentSppConnection(connectionEpoch)) return;
      _log('已发送 L1START_REQ，等待设备 L1START_RSP…');
      _sppWatchdog?.cancel();
      _sppWatchdog = Timer(const Duration(seconds: 15), () {
        if (!_isCurrentSppConnection(connectionEpoch)) return;
        unawaited(
          _cleanupFailedSppConnect(
            device,
            TimeoutException('15 秒内无 L1START_RSP'),
            connectionEpoch,
          ),
        );
      });
    } catch (exception) {
      _log('L1START 发送失败：$exception');
      rethrow;
    }
  }

  Future<void> _sendL1StartFromInboundPacket(int connectionEpoch) async {
    if (!_isCurrentSppConnection(connectionEpoch)) return;
    final device = connectedDevice ?? _lastPeripheral;
    if (device == null) return;
    try {
      await _sppSendL1Start(connectionEpoch, device);
    } on Object catch (exception) {
      if (_isCurrentSppConnection(connectionEpoch) &&
          _closingFailedSppEpoch != connectionEpoch) {
        await _cleanupFailedSppConnect(device, exception, connectionEpoch);
      }
    }
  }

  Future<void> _cleanupFailedSppConnect(
    Peripheral device,
    Object exception,
    int connectionEpoch,
  ) async {
    if (!_isCurrentSppConnection(connectionEpoch) ||
        _closingFailedSppEpoch == connectionEpoch) {
      return;
    }
    _closingFailedSppEpoch = connectionEpoch;
    // Invalidate the attempt before awaiting native cleanup.  Native streams
    // can deliver late data/onDone after disconnect; those callbacks must not
    // be able to restart a handshake or re-publish a candidate device.
    final subscription = _sppSub;
    _sppSub = null;
    final invalidatedEpoch = ++_sppConnectionEpoch;
    _connectionTearingDown = true;
    sessionReady = false;
    _sppAwaitingVersion = false;
    _clearPendingAuthConfirm();
    connectedClassicAddress = null;
    _sppWatchdog?.cancel();
    _sppWatchdog = null;
    if (_resumeAuthenticatedSession) {
      _log('会话恢复失败；已丢弃旧会话密钥，下次连接将重新鉴权。');
    }
    _resumeAuthenticatedSession = false;
    _sessionCipher = null;
    final failureMessage = 'SPP 连接失败：$exception';
    _log(failureMessage);
    try {
      if (subscription != null) {
        try {
          await subscription.cancel();
        } on Object catch (cancelError) {
          _log('RFCOMM 数据流取消失败：$cancelError');
        }
      }
      await _transport
          .disconnectRfcomm(device.uuid)
          .timeout(const Duration(seconds: 5));
      _log('失败的 RFCOMM 链路已关闭，可以重新连接。');
    } on Object catch (cleanupError) {
      _log('RFCOMM 失败清理未完成：$cleanupError');
    } finally {
      if (_closingFailedSppEpoch == connectionEpoch) {
        _closingFailedSppEpoch = null;
      }
      if (_sppConnectionEpoch == invalidatedEpoch) {
        _finishFailedConnection(failureMessage);
      }
    }
  }

  Future<void> _handleAuthKeyRejected(
    Peripheral device,
    int connectionEpoch,
    String reason,
  ) async {
    if (_authKeyRejectedEpoch == connectionEpoch) return;
    _authKeyRejectedEpoch = connectionEpoch;
    final id = device.uuid.toString();
    final name = (connectedDeviceName ?? connectedProfile?.displayName)?.trim();
    _log('设备拒绝 authkey；清除该设备凭据并要求重新输入（reason=$reason）。');
    final published = _connectionIssues.recordAuthKeyMismatch(
      targetId: id,
      targetName: name,
    );
    if (published) notifyListeners();
    await forgetAuthKeyForDevice(id, clearActiveKey: true);
    await _cleanupFailedSppConnect(
      device,
      StateError('设备拒绝 authkey 身份验证：$reason'),
      connectionEpoch,
    );
  }

  void _clearSppHandshakeState() {
    _sppWatchdog?.cancel();
    _sppWatchdog = null;
    _sppAwaitingVersion = false;
    _clearPendingAuthConfirm();
  }

  void _clearPendingAuthConfirm() {
    _sppAwaitingAuthConfirm = false;
    _pendingAuthConfirmEpoch = null;
    _pendingPhoneNonce = null;
    _pendingSessionKeys = null;
  }

  void _handleSppPacket(SppPacket packet, int connectionEpoch) {
    if (!_isCurrentSppConnection(connectionEpoch)) return;
    switch (packet.type) {
      case SppProtocol.typeCmd:
        final cmd = packet.payload.isEmpty ? -1 : packet.payload[0];
        _log(
          'SPP CMD 帧：cmd=$cmd（1=L1START_REQ 2=L1START_RSP），'
          'payload=${_hex(packet.payload)}',
        );
        if (cmd == SppProtocol.cmdL1StartRsp) {
          if (_resumeAuthenticatedSession && _sessionCipher != null) {
            _resumeAuthenticatedSession = false;
            sessionReady = true;
            sppConnecting = false;
            _connectionAttemptInProgress = false;
            _connectionTearingDown = false;
            _sppWatchdog?.cancel();
            _sppWatchdog = null;
            _log('L1START_RSP 收到——传输层已恢复；复用已确认的会话密钥，不重复 f=26/f=27。');
            unawaited(_refreshAuthenticatedDeviceStatus());
            notifyListeners();
          } else {
            _log('L1START_RSP 收到——L1 会话建立！发送官方鉴权 f=26（DATA 明文帧）…');
            unawaited(_sppSendAuthStep1(connectionEpoch));
          }
        }
        break;
      case SppProtocol.typeData:
        _log('SPP DATA 帧（seq=${packet.seq}）：payload=${_hex(packet.payload)}');
        // 回 ACK
        unawaited(_sppSendAck(packet.seq, connectionEpoch));
        _handleSppDataPacket(packet, connectionEpoch);
        break;
      case SppProtocol.typeAck:
        final massIndex = _pendingMassAckOrder.indexOf(packet.seq);
        if (massIndex >= 0) {
          // L1 uses cumulative ACKs for a receive window. ACK N confirms every
          // queued Mass frame through N, not only the frame whose seq equals N.
          final confirmed = _pendingMassAckOrder
              .sublist(0, massIndex + 1)
              .toList();
          _pendingMassAckOrder.removeRange(0, massIndex + 1);
          _MassProgressMarker? latestProgress;
          for (final sequence in confirmed) {
            _pendingMassAcks.remove(sequence);
            latestProgress =
                _pendingMassProgress.remove(sequence) ?? latestProgress;
            final waiter = _pendingAcks.remove(sequence);
            if (waiter != null && !waiter.isCompleted) waiter.complete();
          }
          _log('Mass 累计 ACK（seq=${packet.seq}，确认 ${confirmed.length} 片）');
          if (latestProgress != null) {
            _updateTransferSpeed(latestProgress.confirmedBytes);
            _publishTask(
              latestProgress.request,
              InstallStage.transferring,
              '设备已确认第 ${latestProgress.segmentIndex}/'
              '${latestProgress.totalSegments} 片。',
              currentSegment: latestProgress.segmentIndex,
              totalSegments: latestProgress.totalSegments,
              confirmedBytes: latestProgress.confirmedBytes,
              queuedSegment: latestProgress.queuedSegment,
              queuedBytes: latestProgress.queuedBytes,
              totalBytes: latestProgress.totalBytes,
              bytesPerSecond: _confirmedBytesPerSecond,
            );
          }
        } else {
          final waiter = _pendingAcks.remove(packet.seq);
          if (waiter != null && !waiter.isCompleted) waiter.complete();
          _log('SPP ACK（seq=${packet.seq}）');
        }
        break;
      default:
        _log('SPP 未知帧 type=${packet.type}：${_hex(packet.payload)}');
    }
  }

  /// DATA 帧：channel + opCode + data。解析 Command protobuf。
  void _handleSppDataPacket(SppPacket packet, int connectionEpoch) {
    if (!_isCurrentSppConnection(connectionEpoch)) return;
    if (packet.payload.length < 2) {
      _log('SPP DATA 帧过短');
      return;
    }
    final channel = packet.payload[0] & 0x0f;
    final opCode = packet.payload[1];
    final data = packet.payload.sublist(2);
    _log('  DATA channel=$channel opCode=$opCode data=${_hex(data)}');
    final isPlainPbWrite =
        channel == SppProtocol.channelPb && opCode == SppProtocol.opCodeWrite;
    if (channel == SppProtocol.channelPb &&
        opCode == SppProtocol.opCodeWriteEnc) {
      _inspectEncryptedBusinessFrame(data);
      return;
    }
    final parsed = XiaomiAuth.parse(data);
    if (parsed != null) {
      _log(
        '  Command：type=${parsed.type} subtype=${parsed.subtype} '
        'watchNonce=${parsed.watchNonce != null}',
      );
      if (isPlainPbWrite &&
          parsed.type == XiaomiAuth.commandType &&
          parsed.subtype == XiaomiAuth.cmdNonce &&
          parsed.watchNonce != null &&
          _pendingPhoneNonce != null &&
          !_sppAwaitingAuthConfirm &&
          sppConnecting &&
          !sessionReady) {
        _sppAwaitingAuthConfirm = true;
        _log('  收到设备随机数与签名，开始本地验签后自动发送 f=27 sendAppConfirm…');
        unawaited(
          _sppSendAuthConfirm(
            connectionEpoch: connectionEpoch,
            phoneNonce: _pendingPhoneNonce!,
            watchNonce: parsed.watchNonce!,
            watchHmac: parsed.watchHmac ?? const [],
          ),
        );
      } else if (parsed.subtype == XiaomiAuth.cmdAuth) {
        final belongsToCurrentHandshake =
            isPlainPbWrite &&
            parsed.type == XiaomiAuth.commandType &&
            _pendingAuthConfirmEpoch == connectionEpoch &&
            _sppAwaitingAuthConfirm &&
            _pendingPhoneNonce != null &&
            _pendingSessionKeys != null &&
            parsed.authStatus != null &&
            sppConnecting &&
            !sessionReady;
        if (!belongsToCurrentHandshake) {
          _log('  忽略不属于当前鉴权握手的 f=27 响应。');
          return;
        }

        // f=27 响应：设备确认（kc0{success, capability}）→ device ready。
        final keys = _pendingSessionKeys!;
        final confirmed = parsed.authStatus == 1;
        _sppAwaitingAuthConfirm = false;
        _pendingAuthConfirmEpoch = null;
        _pendingPhoneNonce = null;
        _pendingSessionKeys = null;
        _sppWatchdog?.cancel();
        _sppWatchdog = null;
        if (confirmed) {
          _sessionCipher = SessionCipher(keys);
          _log('  已启用 WRITE_ENC 业务通道与只读解密诊断。');
          _authenticatedAt = DateTime.now();
          sessionReady = true;
          sppConnecting = false;
          _connectionAttemptInProgress = false;
          _connectionTearingDown = false;
          final authenticatedDevice = connectedDevice ?? _lastPeripheral;
          final authenticatedName =
              (connectedDeviceName ?? connectedProfile?.displayName ?? '已验证设备')
                  .trim();
          if (authenticatedDevice != null) {
            // Saving the post-auth identity and key is deliberately queued
            // with deletion. If the user removes this saved device before
            // either native write completes, the deletion is guaranteed to
            // run last and cannot be undone by this asynchronous callback.
            unawaited(
              _persistAuthenticatedDevice(
                device: authenticatedDevice,
                advertisedName: authenticatedName,
                key: authKey,
              ),
            );
          }
          _connectionIssues.authenticated();
          // f=27 confirms the authenticated session. Do not send a speculative
          // encrypted "keepalive" here: the reference installer proceeds with
          // the requested business command, and this device does not ACK the
          // previously tested 4/0 probe. A missing response to an optional
          // probe must never invalidate an otherwise healthy RFCOMM session.
        } else {
          _sessionCipher = null;
        }
        _log('  f=27 设备响应（confirmed=$confirmed，status=${parsed.status}）');
        _log(
          confirmed
              ? '  ★ 鉴权完成（device ready）——会话密钥已建立；可使用已验证的安装流程'
              : '  ✕ 设备未确认鉴权，未将连接标记为就绪',
        );
        if (confirmed && _sessionCipher != null) {
          unawaited(_refreshAuthenticatedDeviceStatus());
        } else {
          final device = connectedDevice ?? _lastPeripheral;
          if (device == null) {
            _finishFailedConnection('设备拒绝 authkey 身份验证。');
          } else {
            unawaited(
              _handleAuthKeyRejected(
                device,
                connectionEpoch,
                'f=27 status=${parsed.authStatus}',
              ),
            );
          }
        }
      }
    } else {
      _log('  无法按 Xiaomi Command 解析');
    }
  }

  Future<void> _confirmMacOSRfcommIdentity(
    Peripheral device,
    String advertisedName,
  ) async {
    try {
      await _transport.confirmRfcommIdentity(
        device.uuid,
        advertisedName: advertisedName,
      );
      _log('已在 authkey 鉴权成功后保存 macOS 经典蓝牙设备关联。');
    } on Object catch (exception) {
      _log('macOS 经典蓝牙设备关联未持久化：$exception');
    }
  }

  /// 只分析设备入站加密帧，不会向设备发送任何探测数据。
  void _inspectEncryptedBusinessFrame(List<int> ciphertext) {
    final cipher = _sessionCipher;
    if (cipher == null) {
      _log('  WRITE_ENC 已收到，但本次会话尚无可用密钥（只记录）。');
      return;
    }
    final plaintext = cipher.decryptInbound(ciphertext);
    final business = Zau.tryParse(plaintext);
    if (business != null && business.command != XiaomiAuth.commandType) {
      _log('  WRITE_ENC 业务响应：command=${business.command}/${business.sub}');
      _businessResponses.add(business);
      return;
    }
    final parsed = XiaomiAuth.parse(plaintext);
    if (parsed?.type != null && parsed?.subtype != null) {
      _log(
        '  WRITE_ENC 解密命中：type=${parsed!.type} '
        'subtype=${parsed.subtype} plain=${_hex(plaintext)}',
      );
      return;
    }
    _log('  WRITE_ENC 未解析为已知 Command；不改变会话或发送状态。');
  }

  Future<void> _sppSendAuthConfirm({
    required int connectionEpoch,
    required List<int> phoneNonce,
    required List<int> watchNonce,
    required List<int> watchHmac,
  }) async {
    if (!_isCurrentSppConnection(connectionEpoch)) return;
    final device = connectedDevice;
    if (device == null) {
      _clearPendingAuthConfirm();
      _finishFailedConnection('f=27 身份验证失败：连接目标已丢失。');
      return;
    }
    final secretKey = XiaomiAuth.secretKeyFromHex(authKey ?? '');
    if (secretKey == null) {
      _clearPendingAuthConfirm();
      _log('f=27 被拒绝：authkey 无效');
      await _handleAuthKeyRejected(device, connectionEpoch, '本地 authkey 格式无效');
      return;
    }
    final cmd = XiaomiAuth.buildAuthStep3Command(
      secretKey: secretKey,
      phoneNonce: phoneNonce,
      watchNonce: watchNonce,
      watchHmac: watchHmac,
      phoneModel: _companionDeviceName(),
    );
    if (cmd == null) {
      _clearPendingAuthConfirm();
      _log('  ✗ 设备签名校验失败（HMAC 不匹配——authkey 与设备不匹配？）');
      await _handleAuthKeyRejected(
        device,
        connectionEpoch,
        'watch nonce HMAC 不匹配',
      );
      return;
    }
    _pendingSessionKeys = SessionKeys.fromHkdf(
      XiaomiAuth.computeStep3Hmac(secretKey, phoneNonce, watchNonce),
    );
    _pendingAuthConfirmEpoch = connectionEpoch;
    final frame = SppProtocol.buildDataFrame(_sppSeq++, cmd);
    _logWire(
      'TX',
      frame,
      phase: 'AUTH_F27',
      sequence: _sppSeq - 1,
      generation: connectionEpoch,
    );
    _log('发送 f=27（seq=${_sppSeq - 1}，${frame.length}B）：${_hex(frame)}');
    try {
      await _transport.rfcommWrite(device.uuid, frame);
      if (!_isCurrentSppConnection(connectionEpoch)) return;
      if (!_sppAwaitingAuthConfirm) {
        _log('f=27 已在写入完成前收到设备确认。');
        return;
      }
      _log('f=27 已写入，等待设备确认（device ready）…');
      _sppWatchdog?.cancel();
      _sppWatchdog = Timer(const Duration(seconds: 15), () {
        if (_isCurrentSppConnection(connectionEpoch) &&
            _sppAwaitingAuthConfirm &&
            _pendingAuthConfirmEpoch == connectionEpoch) {
          _clearPendingAuthConfirm();
          unawaited(
            _cleanupFailedSppConnect(
              device,
              TimeoutException('15 秒内无 f=27 响应'),
              connectionEpoch,
            ),
          );
        }
      });
    } catch (exception) {
      if (!_isCurrentSppConnection(connectionEpoch)) return;
      _clearPendingAuthConfirm();
      _log('f=27 发送失败：$exception');
      await _cleanupFailedSppConnect(device, exception, connectionEpoch);
    }
  }

  String _companionDeviceName() {
    try {
      final hostname = Platform.localHostname.trim();
      if (hostname.isNotEmpty) {
        return hostname.length <= 64 ? hostname : hostname.substring(0, 64);
      }
    } on Object {
      // 主机名不可用时使用不含用户信息的通用平台名。
    }
    return switch (defaultTargetPlatform) {
      TargetPlatform.macOS => 'macOS',
      TargetPlatform.android => 'Android',
      TargetPlatform.windows => 'Windows',
      TargetPlatform.linux => 'Linux',
      _ => 'Wristload',
    };
  }

  Future<void> _sppSendAuthStep1(int connectionEpoch) async {
    if (!_isCurrentSppConnection(connectionEpoch)) return;
    final device = connectedDevice;
    if (device == null) {
      _finishFailedConnection('f=26 身份验证失败：连接目标已丢失。');
      return;
    }
    final nonce = List<int>.generate(16, (_) => _random.nextInt(256));
    _pendingPhoneNonce = nonce;
    final command = XiaomiAuth.buildNonceCommand(nonce);
    final frame = SppProtocol.buildDataFrame(_sppSeq++, command);
    _logWire(
      'TX',
      frame,
      phase: 'AUTH_F26',
      sequence: _sppSeq - 1,
      generation: connectionEpoch,
    );
    _log('发送 f=26（seq=${_sppSeq - 1}，${frame.length}B）：${_hex(frame)}');
    try {
      await _transport.rfcommWrite(device.uuid, frame);
      if (!_isCurrentSppConnection(connectionEpoch)) return;
      _log('f=26 已写入，等待设备 watchNonce…');
      _sppWatchdog?.cancel();
      _sppWatchdog = Timer(const Duration(seconds: 15), () {
        if (!_isCurrentSppConnection(connectionEpoch)) return;
        unawaited(
          _cleanupFailedSppConnect(
            device,
            TimeoutException('15 秒内无 watchNonce'),
            connectionEpoch,
          ),
        );
      });
    } catch (exception) {
      if (!_isCurrentSppConnection(connectionEpoch)) return;
      _log('f=26 发送失败：$exception');
      await _cleanupFailedSppConnect(device, exception, connectionEpoch);
    }
  }

  Future<void> _sppSendAck(int seq, int connectionEpoch) async {
    if (!_isCurrentSppConnection(connectionEpoch)) return;
    final device = connectedDevice;
    if (device == null) return;
    try {
      final frame = SppProtocol.buildAck(seq);
      _logWire(
        'TX',
        frame,
        phase: 'ACK',
        sequence: seq,
        generation: connectionEpoch,
      );
      await _transport.rfcommWrite(device.uuid, frame);
      _log('  ACK 已发送（seq=$seq）');
    } catch (exception) {
      _log('ACK 发送失败：$exception');
    }
  }

  List<int>? _pendingPhoneNonce;
  final _random = Random();

  String _hex(List<int> bytes) {
    // Protocol frames can contain auth material, nonces and session-encrypted
    // payloads. Keep forensic correlation without persisting recoverable
    // bytes in the diagnostic journal.
    final digest = sha256.convert(bytes).toString().substring(0, 16);
    return '<redacted bytes=${bytes.length} sha256=$digest>';
  }

  String _wireHex(List<int> bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');

  Future<void> disconnect() async {
    if (_connectionTearingDown) {
      _log('断开请求已在进行，忽略重复操作。');
      return;
    }
    _advanceSessionEpoch();
    _sppConnectionEpoch++;
    _closingFailedSppEpoch = null;
    _clearSppHandshakeState();
    final sppSubscription = _sppSub;
    _sppSub = null;
    // The selected scan result may still be waiting on the macOS pairing
    // sheet, in which case only _lastPeripheral is populated. Capture it
    // before clearing presentation state so an explicit cancel can still
    // release every native transport that was opened for the candidate.
    final device = _connectionTarget;
    final hadGattTransport = _hasActiveGattTransport;
    final deviceLabel = connectedDeviceName ?? device?.uuid.toString();
    // A deliberate cancel/disconnect is the one transition that should return
    // to discovery automatically. Initial connection failures never set this.
    _resumeScanningAfterConnectionEnd =
        device != null || _connectionAttemptInProgress || sppConnecting;
    // Clear presentation/session state before waiting on native Bluetooth.
    // Otherwise the UI remains in the connected card while macOS tears down
    // RFCOMM/GATT, and a late connection callback can make it appear connected.
    _connectionTearingDown = device != null;
    _clearConnectionCandidate();
    _scanResultsFlushTimer?.cancel();
    _scanResultsFlushTimer = null;
    _isScanning = false;
    _connectionIssues.reset();
    notifyListeners();
    try {
      if (sppSubscription != null) {
        try {
          await sppSubscription.cancel();
        } on Object catch (exception) {
          _log('断开时取消 RFCOMM 数据流失败：$exception');
        }
      }
      if (_installInProgress) {
        await cancelInstall();
        _log('RFCOMM/GATT 正在断开：安装已停止，设备可能保留部分数据。');
      }
      if (device != null) {
        try {
          await _transport
              .disconnectRfcomm(device.uuid)
              .timeout(const Duration(seconds: 5));
        } on Object {
          // RFCOMM may already have been closed by the remote device; GATT
          // cleanup and the user-visible state transition must still finish.
        }
        if (hadGattTransport) {
          try {
            await _transport
                .disconnect(device)
                .timeout(const Duration(seconds: 5));
          } on Object {
            // Native GATT teardown is best-effort; state reset must not wait
            // indefinitely for a completion callback.
          }
        }
        _log('已断开 ${deviceLabel ?? device.uuid}');
      }
    } finally {
      _connectionTearingDown = false;
      _hasActiveGattTransport = false;
      _connectionAttemptInProgress = false;
      sppConnecting = false;
      notifyListeners();
    }
  }

  /// Rebuilds the device connection and performs a fresh authentication.
  /// The selected device is retained so callers do not need to scan again.
  Future<void> reconnect() async {
    if (isConnectionBusy) return;
    final device = connectedDevice ?? _lastPeripheral;
    if (device == null) {
      error = '没有可重新连接的设备，请先扫描并选择设备。';
      _log(error!);
      notifyListeners();
      return;
    }
    _advanceSessionEpoch();
    _resumeScanningAfterConnectionEnd = false;
    final reconnectSession = _sessionEpoch;
    _sppConnectionEpoch++;
    error = null;
    _connectionAttemptInProgress = true;
    _connectionTearingDown = true;
    sessionReady = false;
    _authenticatedAt = null;
    _resumeAuthenticatedSession = false;
    _sppAwaitingAuthConfirm = false;
    _pendingSessionKeys = null;
    _sessionCipher = null;
    _sppWatchdog?.cancel();
    _sppWatchdog = null;
    notifyListeners();
    _log('正在重新建立设备连接并重新验证身份…');
    var handedOffToSpp = false;
    try {
      try {
        await _transport
            .disconnectRfcomm(device.uuid)
            .timeout(const Duration(seconds: 5));
      } on Object catch (exception) {
        _log('清理旧 RFCOMM 链路时返回：$exception');
      }
      if (reconnectSession != _sessionEpoch || device != _connectionTarget) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (reconnectSession != _sessionEpoch || device != _connectionTarget) {
        return;
      }
      _connectionTearingDown = false;
      // connectSpp now owns the busy state, including its failure cleanup.
      // Mark that transfer of ownership before awaiting it so this method's
      // finally block cannot clear a newly-created attempt.
      handedOffToSpp = true;
      await connectSpp();
    } finally {
      if (!handedOffToSpp && reconnectSession == _sessionEpoch) {
        _connectionAttemptInProgress = false;
        _connectionTearingDown = false;
        sppConnecting = false;
        notifyListeners();
      }
    }
  }

  Future<void> startInstall(InstallRequest request) async {
    if (_timeSyncInProgress) {
      _log('安装被拒绝：系统时间同步正在进行，请等待同步完成。');
      return;
    }
    if (statusRefreshInProgress) {
      _log('安装被拒绝：正在读取设备状态，请等待完成。');
      return;
    }
    if (_installInProgress) {
      _log('安装被拒绝：已有任务正在运行。');
      return;
    }
    error = null;
    try {
      const VerificationGate().ensureCanSend();
    } on StateError catch (exception) {
      _publishTask(request, InstallStage.waitingForProtocol, exception.message);
      return;
    }
    if (!sessionReady ||
        _sessionCipher == null ||
        (connectedDevice ?? _lastPeripheral) == null) {
      error = '安装被拒绝：请先完成 authkey 会话认证。';
      _log(error!);
      notifyListeners();
      return;
    }
    _installInProgress = true;
    _lastInstallRequest = request;
    _installCancelled = false;
    _installStopwatch = Stopwatch()..start();
    _transferStopwatch = null;
    _completedTransferElapsed = null;
    _transferStartConfirmedBytes = 0;
    _installCancellation = Completer<void>();
    _installTransportFailure = Completer<Object>();
    try {
      await _runInstall(request);
    } on _InstallCancelled {
      _publishTask(request, InstallStage.cancelled, '已取消，设备可能保留部分数据。');
    } on FormatException catch (exception) {
      _publishTask(request, InstallStage.failed, exception.message);
    } on _DeviceInstallFailed catch (exception) {
      await _clearCheckpointBestEffort();
      _publishTask(request, InstallStage.failed, exception.message);
    } on TimeoutException catch (exception) {
      sessionReady = false;
      _sessionCipher = null;
      _connectionIssues.recordUnexpectedDisconnect();
      _publishTask(
        request,
        InstallStage.stateUnknown,
        '设备未在规定时间响应；已停止发送，设备状态未知。${exception.message ?? ''}',
      );
    } on _InvalidDeviceResponse catch (exception) {
      sessionReady = false;
      _sessionCipher = null;
      _connectionIssues.recordUnexpectedDisconnect();
      _publishTask(
        request,
        InstallStage.stateUnknown,
        '设备响应无法验证；已停止发送，设备状态未知：${exception.message}',
      );
    } on Object catch (exception) {
      sessionReady = false;
      _sessionCipher = null;
      _connectionIssues.recordUnexpectedDisconnect();
      _publishTask(
        request,
        InstallStage.stateUnknown,
        '传输已停止，设备状态未知：$exception',
      );
    } finally {
      for (final waiter in _completionWaiters.toList()) {
        await waiter.cancel();
      }
      _completionWaiters.clear();
      _pendingAcks.clear();
      _pendingMassAcks.clear();
      _pendingMassAckOrder.clear();
      _pendingMassProgress.clear();
      _resetTransferSpeed();
      _installStopwatch?.stop();
      _transferStopwatch?.stop();
      _installStopwatch = null;
      _transferStopwatch = null;
      _completedTransferElapsed = null;
      _transferStartConfirmedBytes = 0;
      _installCancellation = null;
      _installTransportFailure = null;
      _installInProgress = false;
      notifyListeners();
    }
  }

  Future<void> cancelInstall() async {
    if (!_installInProgress) return;
    _installCancelled = true;
    for (final waiter in _pendingAcks.values) {
      if (!waiter.isCompleted) waiter.completeError(const _InstallCancelled());
    }
    _pendingAcks.clear();
    _pendingMassAcks.clear();
    _pendingMassAckOrder.clear();
    _pendingMassProgress.clear();
    final cancellation = _installCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    _log('已停止本地安装队列；未发送未验证的设备取消命令。');
  }

  bool _debugInstallInProgress = false;
  bool debugCleanupPolling = false;
  DebugCleanupReport? debugCleanupReport;
  String? debugError;
  Future<void>? _debugCleanupFuture;

  bool get debugInstallInProgress => _debugInstallInProgress;

  Future<void> startDebugInstall(InstallRequest request) async {
    if (_debugInstallInProgress) return;
    _debugInstallInProgress = true;
    debugError = null;
    debugCleanupReport = null;
    debugCleanupPolling = false;
    notifyListeners();
    try {
      await startInstall(request);
    } on Object catch (exception) {
      debugError = exception.toString();
    } finally {
      _debugInstallInProgress = false;
      notifyListeners();
    }
  }

  Future<void> cancelDebugInstall() async {
    await cancelInstall();
    // startInstall publishes the cancelled task and releases its cancellation
    // completer in finally. Wait for that boundary before issuing a new
    // business request, otherwise the cleanup query would be cancelled too.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_installInProgress && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (_debugCleanupFuture != null) return;
    _debugCleanupFuture = _pollDebugCleanup();
    try {
      await _debugCleanupFuture;
    } finally {
      _debugCleanupFuture = null;
    }
  }

  Future<void> _pollDebugCleanup() async {
    final startedAt = DateTime.now();
    var pollCount = 0;
    int? finalStatus;
    debugCleanupPolling = true;
    debugCleanupReport = null;
    debugError = null;
    notifyListeners();
    try {
      while (true) {
        if (pollCount > 0) {
          await Future<void>.delayed(const Duration(seconds: 8));
        }
        if (_disposed) return;
        if (!sessionReady || _sessionCipher == null) {
          throw StateError('设备鉴权会话已失效，无法查询清理状态');
        }
        final response = await _requestBusiness(
          Zau(
            command: ZauCommand.debugTransfer,
            sub: ZauCommand.debugTransferStatusSub,
          ),
          ZauCommand.debugTransfer,
          ZauCommand.debugTransferStatusSub,
        );
        finalStatus = DebugCleanupStatusPayload.parse(response.payload);
        pollCount++;
        if (finalStatus == null) {
          throw const FormatException('设备清理状态响应缺少状态码');
        }
        _log('调试清理状态查询：status=$finalStatus（第 $pollCount 次）');
        if (finalStatus != 1) break;
      }
      debugCleanupReport = DebugCleanupReport(
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        pollCount: pollCount,
        finalStatus: finalStatus,
      );
    } on Object catch (exception) {
      debugError = '设备清理状态查询失败：$exception';
      _log(debugError!);
      debugCleanupReport = DebugCleanupReport(
        startedAt: startedAt,
        finishedAt: DateTime.now(),
        pollCount: pollCount,
        finalStatus: finalStatus,
        error: exception.toString(),
      );
    } finally {
      debugCleanupPolling = false;
      notifyListeners();
    }
  }

  /// Reads the installed quick-app list from the authenticated device.
  Future<List<WatchAppItem>> refreshInstalledWatchApps() async {
    if (watchAppsLoading) {
      _logQuickAppRead(
        '快应用列表读取已在进行，复用当前请求。',
        level: DiagnosticLogLevel.trace,
        event: 'quick_app_list_deduplicated',
      );
      return installedWatchApps;
    }
    if (!sessionReady || _sessionCipher == null) {
      watchAppsError = '请先完成设备鉴权';
      _logQuickAppRead(
        '快应用列表读取被拒绝：设备鉴权会话未就绪。',
        level: DiagnosticLogLevel.warning,
        event: 'quick_app_list_rejected',
        fields: <String, Object?>{
          'sessionReady': sessionReady,
          'sessionCipherReady': _sessionCipher != null,
        },
      );
      notifyListeners();
      return installedWatchApps;
    }
    final sessionEpoch = _sessionEpoch;
    final sessionCipher = _sessionCipher;
    if (sessionCipher == null) {
      // This can only happen when a connection callback changes the session
      // between the guard above and this synchronous point. Keep the visible
      // result deterministic rather than force-unwrapping a stale cipher.
      watchAppsError = '请先完成设备鉴权';
      notifyListeners();
      return installedWatchApps;
    }
    final requestGeneration = ++_quickAppReadGeneration;

    bool isCurrentRequest() =>
        requestGeneration == _quickAppReadGeneration &&
        sessionEpoch == _sessionEpoch &&
        sessionReady &&
        identical(_sessionCipher, sessionCipher);

    watchAppsLoading = true;
    watchAppsError = null;
    _logQuickAppRead(
      '读取设备快应用列表。',
      event: 'quick_app_list_request',
      fields: <String, Object?>{
        'command': ZauCommand.appList,
        'sub': ZauCommand.appListSub,
        'sessionEpoch': sessionEpoch,
        'requestGeneration': requestGeneration,
      },
    );
    notifyListeners();
    try {
      final response = await _requestBusiness(
        Zau(command: ZauCommand.appList, sub: ZauCommand.appListSub),
        ZauCommand.appList,
        ZauCommand.appListSub,
      );
      final payload = response.payload;
      _logQuickAppRead(
        '收到设备快应用列表响应。',
        level: DiagnosticLogLevel.trace,
        event: 'quick_app_list_response',
        fields: <String, Object?>{
          'responseCommand': response.command,
          'responseSub': response.sub,
          'payloadField': payload?.$1,
          'payloadBytes': payload?.$2.length,
          'sessionEpoch': sessionEpoch,
          'requestGeneration': requestGeneration,
        },
      );
      if (!isCurrentRequest()) {
        _logQuickAppRead(
          '已忽略过期会话的快应用列表响应。',
          level: DiagnosticLogLevel.trace,
          event: 'quick_app_list_stale',
          fields: <String, Object?>{
            'requestSessionEpoch': sessionEpoch,
            'currentSessionEpoch': _sessionEpoch,
            'requestGeneration': requestGeneration,
            'currentGeneration': _quickAppReadGeneration,
          },
        );
        return installedWatchApps;
      }
      if (payload == null || payload.$1 != 22) {
        throw const FormatException('设备快应用列表缺少 v8s 载荷');
      }
      final parsed = V8s.parseInstalledApps(payload.$2);
      installedWatchApps = List<WatchAppItem>.unmodifiable(parsed);
      _quickAppsLoadedSessionEpoch = sessionEpoch;
      _logQuickAppRead(
        '设备快应用列表读取完成。',
        event: 'quick_app_list_parsed',
        fields: <String, Object?>{
          'appCount': parsed.length,
          'removableCount': parsed.where((app) => app.canRemove).length,
        },
      );
      return installedWatchApps;
    } on Object catch (exception) {
      if (!isCurrentRequest()) {
        _logQuickAppRead(
          '已忽略过期会话的快应用列表读取失败。',
          level: DiagnosticLogLevel.trace,
          event: 'quick_app_list_stale',
          fields: <String, Object?>{
            'requestSessionEpoch': sessionEpoch,
            'currentSessionEpoch': _sessionEpoch,
            'requestGeneration': requestGeneration,
            'currentGeneration': _quickAppReadGeneration,
            'errorType': exception.runtimeType.toString(),
          },
        );
        return installedWatchApps;
      }
      watchAppsError = '读取快应用列表失败：$exception';
      _logQuickAppRead(
        '读取设备快应用列表失败。',
        level: DiagnosticLogLevel.error,
        event: 'quick_app_list_failed',
        fields: <String, Object?>{
          'errorType': exception.runtimeType.toString(),
          'exception': exception.toString(),
        },
      );
      return installedWatchApps;
    } finally {
      // A later request owns the loading flag. Never let an old timeout or
      // delayed response make a new read appear finished.
      if (requestGeneration == _quickAppReadGeneration) {
        watchAppsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<bool> uninstallWatchApp(WatchAppItem app) async {
    if (!app.canRemove || watchAppsLoading) return false;
    final sessionCipher = _sessionCipher;
    if (!sessionReady || sessionCipher == null) {
      watchAppsError = '请先完成设备鉴权';
      notifyListeners();
      return false;
    }

    final sessionEpoch = _sessionEpoch;
    final operationGeneration = ++_quickAppOperationGeneration;
    // An old app-list response may already be on its way when an uninstall is
    // confirmed. It must not put the removed item back into the local list.
    _quickAppReadGeneration++;

    bool isCurrentOperation() =>
        operationGeneration == _quickAppOperationGeneration &&
        sessionEpoch == _sessionEpoch &&
        sessionReady &&
        identical(_sessionCipher, sessionCipher);

    watchAppsLoading = true;
    watchAppsError = null;
    _logQuickAppRead(
      '发送设备快应用卸载命令。',
      event: 'quick_app_uninstall_request',
      fields: <String, Object?>{
        'command': ZauCommand.appList,
        'sub': ZauCommand.uninstallAppSub,
        'packageName': app.packageName,
        'sessionEpoch': sessionEpoch,
        'operationGeneration': operationGeneration,
      },
    );
    notifyListeners();
    try {
      // Xiaomi's uninstall API is a fire-and-ack operation.  The reference
      // client completes its callback from the transport/contact success
      // path; V2 devices commonly do not emit a second encrypted 20/3
      // business response.  Waiting for that optional response turns an
      // already accepted uninstall into a 12-second false timeout.
      await _sendBusinessNoResponse(
        Zau(
          command: ZauCommand.appList,
          sub: ZauCommand.uninstallAppSub,
          payload: V8s.uninstallRequest(
            packageName: app.packageName,
            fingerprint: app.fingerprint,
          ),
        ),
      );
      if (!isCurrentOperation()) {
        _logQuickAppRead(
          '已忽略过期会话的快应用卸载 ACK。',
          level: DiagnosticLogLevel.trace,
          event: 'quick_app_uninstall_stale',
          fields: <String, Object?>{
            'result': 'ack',
            'packageName': app.packageName,
            'operationSessionEpoch': sessionEpoch,
            'currentSessionEpoch': _sessionEpoch,
            'operationGeneration': operationGeneration,
            'currentOperationGeneration': _quickAppOperationGeneration,
          },
        );
        return false;
      }

      // The RFCOMM ACK is the completion boundary for this command.  Update
      // the visible list immediately and leave a later explicit refresh to
      // reconcile with the device; a refresh timeout must never turn this
      // acknowledged uninstall back into a failure.
      final previousCount = installedWatchApps.length;
      installedWatchApps = List<WatchAppItem>.unmodifiable(
        installedWatchApps.where(
          (installed) => installed.packageName != app.packageName,
        ),
      );
      _quickAppsLoadedSessionEpoch = sessionEpoch;
      _logQuickAppRead(
        '卸载命令已收到 SPP ACK；本地列表已更新。',
        event: 'quick_app_uninstall_ack',
        fields: <String, Object?>{
          'command': ZauCommand.appList,
          'sub': ZauCommand.uninstallAppSub,
          'packageName': app.packageName,
          'removedLocal': previousCount != installedWatchApps.length,
          'remainingCount': installedWatchApps.length,
          'sessionEpoch': sessionEpoch,
          'operationGeneration': operationGeneration,
        },
      );
      return true;
    } on Object catch (exception) {
      if (!isCurrentOperation()) {
        _logQuickAppRead(
          '已忽略过期会话的快应用卸载失败。',
          level: DiagnosticLogLevel.trace,
          event: 'quick_app_uninstall_stale',
          fields: <String, Object?>{
            'result': 'error',
            'packageName': app.packageName,
            'operationSessionEpoch': sessionEpoch,
            'currentSessionEpoch': _sessionEpoch,
            'operationGeneration': operationGeneration,
            'currentOperationGeneration': _quickAppOperationGeneration,
            'errorType': exception.runtimeType.toString(),
          },
        );
        return false;
      }
      watchAppsError = '卸载快应用失败：$exception';
      _logQuickAppRead(
        watchAppsError!,
        level: DiagnosticLogLevel.error,
        event: 'quick_app_uninstall_failed',
        fields: <String, Object?>{
          'packageName': app.packageName,
          'sessionEpoch': sessionEpoch,
          'operationGeneration': operationGeneration,
          'errorType': exception.runtimeType.toString(),
          'exception': exception.toString(),
        },
      );
      return false;
    } finally {
      // A disconnect or a new session may have begun while RFCOMM was waiting
      // for its ACK. Only the operation which still owns the visible state may
      // complete it.
      if (operationGeneration == _quickAppOperationGeneration &&
          sessionEpoch == _sessionEpoch) {
        watchAppsLoading = false;
        notifyListeners();
      }
    }
  }

  /// 只校验本地检查点和源文件；没有设备侧状态查询证据时绝不自行续传。
  Future<void> reconnectAndCheckInstall() async {
    final checkpoint = await _checkpointStore.load();
    if (checkpoint == null) {
      _log('没有待恢复的安装检查点。');
      return;
    }
    List<int> bytes;
    SecurityScopedFileLease? lease;
    try {
      lease = await SecurityScopedFileAccess.instance.acquire(
        ScopedFileRef(path: checkpoint.path, bookmark: checkpoint.bookmark),
      );
      final file = File(lease.file.path);
      if (!await file.exists()) throw StateError('源文件已不存在');
      bytes = await file.readAsBytes();
      if (bytes.length != checkpoint.fileSize ||
          md5.convert(bytes).toString() != checkpoint.md5Hex ||
          sha256.convert(bytes).toString() != checkpoint.sha256Hex) {
        _log('恢复检查失败：源文件已变更，不能使用此检查点续传。');
        return;
      }
      // Keep the path returned by the security-scope provider; it is already
      // resolved for the platform that owns the lease.
      final resolvedPath = lease.file.path;
      final resolvedBookmark = lease.file.bookmark;
      final sourceChanged =
          resolvedPath != checkpoint.path ||
          !listEquals(resolvedBookmark, checkpoint.bookmark);
      if (sourceChanged) {
        await _checkpointStore.save(
          InstallCheckpoint(
            kind: checkpoint.kind,
            path: resolvedPath,
            fileSize: checkpoint.fileSize,
            md5Hex: checkpoint.md5Hex,
            sha256Hex: checkpoint.sha256Hex,
            dataType: checkpoint.dataType,
            lastAcknowledgedSegment: checkpoint.lastAcknowledgedSegment,
            phase: checkpoint.phase,
            faceId: checkpoint.faceId,
            packageName: checkpoint.packageName,
            versionCode: checkpoint.versionCode,
            bookmark: resolvedBookmark,
          ),
        );
      }
      if (sourceChanged) {
        _refreshRetryRequestSources(
          checkpoint,
          ScopedFileRef(path: resolvedPath, bookmark: resolvedBookmark),
        );
      }
      _log(
        '检查点有效：已确认片 ${checkpoint.lastAcknowledgedSegment}，'
        '重新认证后将重新 MassPrepare，由设备决定是否给出可信断点。',
      );
    } on Object {
      _log('恢复检查失败：源文件不存在、没有访问权限或无法更新检查点，设备状态未知。');
    } finally {
      try {
        await lease?.close();
      } on Object catch (cleanupError) {
        if (!_disposed) {
          _log(
            '恢复检查点后释放文件访问权限失败（' + cleanupError.runtimeType.toString() + '）。',
          );
        }
      }
    }
  }

  void _refreshRetryRequestSources(
    InstallCheckpoint checkpoint,
    ScopedFileRef source,
  ) {
    bool matchesCheckpoint(InstallRequest request) =>
        request.kind == checkpoint.kind &&
        request.path == checkpoint.path &&
        request.metadata.fileSize == checkpoint.fileSize &&
        request.metadata.md5Hex == checkpoint.md5Hex &&
        request.metadata.sha256Hex == checkpoint.sha256Hex;

    InstallRequest withSource(InstallRequest request) => InstallRequest(
      kind: request.kind,
      path: source.path,
      metadata: request.metadata,
      source: source,
      unsupportedLuaConfirmed: request.unsupportedLuaConfirmed,
      watchfaceResolutionConfirmed: request.watchfaceResolutionConfirmed,
    );

    final lastRequest = _lastInstallRequest;
    if (lastRequest != null && matchesCheckpoint(lastRequest)) {
      _lastInstallRequest = withSource(lastRequest);
    }
    for (final entry in installQueue) {
      if (entry.stage == QueueStage.stateUnknown &&
          matchesCheckpoint(entry.request)) {
        entry.request = withSource(entry.request);
      }
    }
  }

  /// Retries the same package without discarding the device's Mass checkpoint.
  ///
  /// The local checkpoint is only an integrity record. The actual resume offset
  /// is always negotiated again through MassPrepare, so a device that retained
  /// part of the package continues from that point and one that did not safely
  /// asks for the whole package again.
  Future<void> retryInstall() async {
    final request = _lastInstallRequest;
    if (request == null) {
      _log('没有可继续传输的安装任务。');
      return;
    }
    final queuedEntry = installQueue.reversed
        .where(
          (entry) =>
              entry.canRetry &&
              entry.request.kind == request.kind &&
              entry.request.path == request.path &&
              entry.request.metadata.md5Hex == request.metadata.md5Hex,
        )
        .firstOrNull;
    if (queuedEntry != null) {
      await _retryQueueEntry(queuedEntry);
      return;
    }
    final checkpoint = await _checkpointStore.load();
    final checkpointMatches =
        checkpoint != null &&
        checkpoint.kind == request.kind &&
        checkpoint.path == request.path &&
        checkpoint.fileSize == request.metadata.fileSize &&
        checkpoint.md5Hex == request.metadata.md5Hex &&
        checkpoint.sha256Hex == request.metadata.sha256Hex;
    if (checkpointMatches) {
      _log(
        '继续传输同一文件：本地已确认片 '
        '${checkpoint.lastAcknowledgedSegment}；将由设备 MassPrepare 决定续传偏移。',
      );
    } else {
      _log('重新发送同一文件：没有可用本地检查点；将由设备 MassPrepare 决定续传偏移。');
    }
    if (!await _restoreInstallSessionForRetry()) return;
    await startInstall(request);
  }

  Future<bool> _restoreInstallSessionForRetry() async {
    if (sessionReady && _sessionCipher != null && connectedDevice != null) {
      return true;
    }
    // An explicit disconnect clears the current target. Do not silently revive
    // a stale peripheral; the user must select the intended device again.
    if (connectedDevice == null) {
      _log('无法继续传输：当前没有已连接的目标设备，请重新连接后再次尝试。');
      return false;
    }
    _log('继续传输前正在重建 SPP 鉴权会话…');
    if (!sppConnecting) await connectSpp();
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!sessionReady && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!sessionReady || _sessionCipher == null) {
      _log('SPP 鉴权会话尚未恢复，未发送安装包。');
      return false;
    }
    return true;
  }

  /// Backward-compatible API name retained for integrations compiled against
  /// older versions. Its behavior intentionally no longer clears a checkpoint.
  @Deprecated('Use retryInstall() to continue the same package.')
  Future<void> retryInstallFromStart() => retryInstall();

  Future<void> _runInstall(InstallRequest request) async {
    final metadata = request.metadata;
    _validateInstallRequest(request);
    final lease = await SecurityScopedFileAccess.instance.acquire(
      request.source ?? ScopedFileRef(path: request.path),
    );
    try {
      await _runInstallWithLease(request, metadata, lease);
    } finally {
      try {
        await lease.close();
      } on Object catch (error) {
        // Cleanup failure must not replace install success or its primary
        // failure; avoid logging sensitive paths or bookmark contents.
        _log('安装后释放文件访问权限失败（' + error.runtimeType.toString() + '）。');
      }
    }
  }

  Future<void> _runInstallWithLease(
    InstallRequest request,
    InstallMetadata metadata,
    SecurityScopedFileLease lease,
  ) async {
    final file = File(lease.file.path);
    if (!await file.exists()) throw StateError('源文件已不存在');
    final bytes = await file.readAsBytes();
    if (bytes.length != metadata.fileSize ||
        md5.convert(bytes).toString() != metadata.md5Hex ||
        sha256.convert(bytes).toString() != metadata.sha256Hex) {
      throw StateError('源文件已变化，拒绝使用旧元数据发送');
    }
    final dataType = request.kind == InstallKind.watchface
        ? MassDataType.watchface
        : MassDataType.quickAppRpk;
    _publishTask(request, InstallStage.validating, '元数据与文件哈希已校验。');
    // Subscribe before sending the file so an immediate completion event is
    // not lost on the broadcast stream. The result timeout starts only after
    // all Mass data is acknowledged; otherwise a large file can time out while
    // it is still being transferred.
    final watchCompletion = request.kind == InstallKind.watchface
        ? _listenBusiness(ZauCommand.setFace, 5)
        : null;
    final appCompletion = request.kind == InstallKind.quickApp
        ? _listenQuickAppInstallResult(metadata.packageName!)
        : null;
    var preinstallSliceLength = 0;
    if (request.kind == InstallKind.watchface) {
      final preinstall = await _requestBusiness(
        Zau(
          command: ZauCommand.setFace,
          sub: 4,
          payload: A9u.withFileInfo(
            faceId: metadata.faceId!,
            fileSize: bytes.length,
          ),
        ),
        ZauCommand.setFace,
        4,
      );
      final payload = preinstall.payload;
      if (payload == null) throw StateError('表盘预安装响应缺少载荷');
      final result = A9u.parse(payload.$2);
      if (result.code != 0) {
        throw _DeviceInstallFailed('设备拒绝表盘预安装，状态=${result.code}');
      }
      _log('表盘预安装通过：faceId=${metadata.faceId}');
    } else {
      final preinstall = await _requestBusiness(
        Zau(
          command: ZauCommand.prepareInstallApp,
          sub: 1,
          payload: V8s.prepareRequest(
            packageName: metadata.packageName!,
            versionCode: metadata.versionCode!,
            packageSize: bytes.length,
          ),
        ),
        ZauCommand.prepareInstallApp,
        1,
      );
      final payload = preinstall.payload;
      if (payload == null) throw StateError('RPK 预安装响应缺少载荷');
      final result = V8s.parsePrepareResponse(payload.$2);
      if (result.status != 0) {
        throw _DeviceInstallFailed('设备拒绝 RPK 预安装，状态=${result.status}');
      }
      preinstallSliceLength = result.expectedSliceLength;
      _log('RPK 预安装通过：设备建议片长=$preinstallSliceLength B');
    }
    _checkCancelled();
    final prepared = await _requestBusiness(
      Zau(
        command: ZauCommand.massTransfer,
        payload: O1h.prepareRequest(
          dataType: dataType,
          fileMd5: _hexToBytes(metadata.md5Hex),
          fileLength: bytes.length,
        ),
      ),
      ZauCommand.massTransfer,
      0,
    );
    final response = prepared.payload;
    if (response == null) throw StateError('MassPrepare 响应缺少载荷');
    final massInfo = O1h.parsePrepareResponse(response.$2);
    if (massInfo.prepareStatus != 0) {
      throw _DeviceInstallFailed(
        'MassPrepare 被设备拒绝，状态=${massInfo.prepareStatus}',
      );
    }
    // The APK names this value remainLength, but passes it directly as the
    // already-sent file offset to MassDataDispatcher. A fresh transfer returns
    // zero. Treating zero as "all bytes remaining" and subtracting it from the
    // file size incorrectly skipped the entire transfer.
    final sentLength = massInfo.remainLength;
    if (sentLength < 0 || sentLength > bytes.length) {
      throw StateError('MassPrepare 给出无效断点：已发送 $sentLength B');
    }
    final segmentLength = massInfo.expectedSliceLength > 4
        ? massInfo.expectedSliceLength
        : preinstallSliceLength > 4
        ? preinstallSliceLength
        : defaultMassSegmentLength;
    _log('MassPrepare 通过：续传偏移=$sentLength B，片长=$segmentLength B');
    final transferPlan = sentLength == bytes.length
        ? null
        : planMassFile(
            fileBytes: bytes,
            dataType: dataType,
            fileMd5: _hexToBytes(metadata.md5Hex),
            segmentLength: segmentLength,
            sentLength: sentLength,
          );
    final totalSegments = transferPlan?.totalSegments ?? 0;
    await _checkpointStore.save(
      InstallCheckpoint(
        kind: request.kind,
        path: lease.file.path,
        fileSize: metadata.fileSize,
        md5Hex: metadata.md5Hex,
        sha256Hex: metadata.sha256Hex,
        dataType: dataType,
        lastAcknowledgedSegment: 0,
        phase: 'transferring',
        faceId: metadata.faceId,
        packageName: metadata.packageName,
        versionCode: metadata.versionCode,
        bookmark: lease.file.bookmark,
      ),
    );
    // Complete L1 frames are concatenated into one RFCOMM stream write;
    // frame boundaries, sequence numbers, cumulative ACK handling, and
    // timeout behavior stay unchanged for the selected transfer window.
    final massAckWindow = massWindowSize;
    var confirmedFileBytes = sentLength;
    _beginTransferTiming(confirmedBytes: sentLength);
    _publishTask(
      request,
      InstallStage.transferring,
      '文件已进入发送队列，等待设备累计 ACK…',
      currentSegment: 0,
      totalSegments: totalSegments,
      confirmedBytes: sentLength,
      totalBytes: bytes.length,
      bytesPerSecond: _confirmedBytesPerSecond,
    );
    final iterator = transferPlan?.segments.iterator;
    while (iterator != null) {
      final batch = <MassSegment>[];
      final confirmedBytesBySegment = <int, int>{};
      var queuedFileBytes = confirmedFileBytes;
      while (batch.length < massAckWindow && iterator.moveNext()) {
        final segment = iterator.current;
        batch.add(segment);
        queuedFileBytes = min(
          bytes.length,
          queuedFileBytes + segment.fileByteCount,
        );
        confirmedBytesBySegment[segment.index] = queuedFileBytes;
      }
      if (batch.isEmpty) break;
      _checkCancelled();
      final queuedThrough = batch.last;
      _publishTask(
        request,
        InstallStage.transferring,
        '已提交第 ${batch.first.index}–${queuedThrough.index}/'
        '${queuedThrough.total} 片，等待设备累计 ACK…',
        currentSegment: batch.first.index - 1,
        totalSegments: queuedThrough.total,
        confirmedBytes: confirmedFileBytes,
        queuedSegment: queuedThrough.index,
        queuedBytes: queuedFileBytes,
        totalBytes: bytes.length,
        bytesPerSecond: _confirmedBytesPerSecond,
      );
      await _queueMassWindow(
        batch,
        request: request,
        confirmedBytesBySegment: confirmedBytesBySegment,
        totalBytes: bytes.length,
        idleTimeout: const Duration(seconds: 12),
      );
      final confirmed = batch.last;
      confirmedFileBytes = queuedFileBytes;
      await _checkpointStore.save(
        InstallCheckpoint(
          kind: request.kind,
          path: lease.file.path,
          fileSize: metadata.fileSize,
          md5Hex: metadata.md5Hex,
          sha256Hex: metadata.sha256Hex,
          dataType: dataType,
          lastAcknowledgedSegment: confirmed.index,
          phase: 'transferring',
          faceId: metadata.faceId,
          packageName: metadata.packageName,
          versionCode: metadata.versionCode,
          bookmark: lease.file.bookmark,
        ),
      );
      if (confirmed.index < totalSegments) {
        await Future<void>.delayed(Duration(milliseconds: segmentIntervalMs));
      }
    }
    _finishTransferTiming();
    _publishTask(
      request,
      InstallStage.awaitingDevice,
      '文件已确认发送，正在等待设备安装结果。',
      currentSegment: totalSegments,
      totalSegments: totalSegments,
      confirmedBytes: bytes.length,
      queuedSegment: totalSegments,
      queuedBytes: bytes.length,
      totalBytes: bytes.length,
      bytesPerSecond: _confirmedBytesPerSecond,
    );
    await _checkpointStore.save(
      InstallCheckpoint(
        kind: request.kind,
        path: lease.file.path,
        fileSize: metadata.fileSize,
        md5Hex: metadata.md5Hex,
        sha256Hex: metadata.sha256Hex,
        dataType: dataType,
        lastAcknowledgedSegment: totalSegments,
        phase: 'awaitingDevice',
        faceId: metadata.faceId,
        packageName: metadata.packageName,
        versionCode: metadata.versionCode,
        bookmark: lease.file.bookmark,
      ),
    );
    if (watchCompletion != null) {
      final result = await _withInstallCancellation(
        watchCompletion.future.timeout(const Duration(minutes: 5)),
      );
      final payload = result.payload;
      if (payload == null) throw StateError('表盘完成事件缺少载荷');
      final parsed = A9u.parse(payload.$2);
      if (parsed.kind != 'installResult' ||
          (parsed.code != 2 && parsed.code != 3)) {
        throw _DeviceInstallFailed('设备拒绝表盘安装，状态=${parsed.code}');
      }
      await _requestBusiness(
        Zau(
          command: ZauCommand.setFace,
          sub: 1,
          payload: A9u.withFaceId(metadata.faceId!),
        ),
        ZauCommand.setFace,
        1,
      );
      await _clearCheckpointBestEffort();
      _publishTask(
        request,
        InstallStage.succeeded,
        '表盘已安装并已请求切换 faceId=${metadata.faceId}',
      );
      return;
    }
    late final Zau appResultMessage;
    late final ({int code, String packageName}) appResult;
    try {
      appResultMessage = await _withInstallCancellation(
        appCompletion!.future.timeout(const Duration(seconds: 120)),
      );
      final appPayload = appResultMessage.payload;
      if (appPayload == null) {
        throw const FormatException('快应用安装结果缺少载荷');
      }
      appResult = V8s.parseInstallResult(appPayload.$2);
    } on FormatException catch (exception) {
      throw _InvalidDeviceResponse(exception.message);
    }
    if (appResult.code != 0) {
      throw _DeviceInstallFailed(
        '设备报告快应用安装失败：包名=${appResult.packageName}，状态=${appResult.code}',
      );
    }
    await _clearCheckpointBestEffort();
    _publishTask(
      request,
      InstallStage.succeeded,
      '快应用已安装：${appResult.packageName}',
    );
  }

  void _validateInstallRequest(InstallRequest request) {
    final metadata = request.metadata;
    if (request.kind == InstallKind.watchface &&
        !RegExp(r'^\d+$').hasMatch(metadata.faceId ?? '')) {
      throw const FormatException('faceId 必须为非空数值');
    }
    if (request.kind == InstallKind.watchface) {
      final compatibilityError = watchfaceCompatibilityError(metadata);
      if (compatibilityError != null && !request.watchfaceResolutionConfirmed) {
        throw FormatException(compatibilityError);
      }
      if (requiresUnsupportedLuaConfirmation(metadata) &&
          !request.unsupportedLuaConfirmed) {
        throw const FormatException('REDMI Watch 5 的 Lua 表盘安装尚未由用户确认');
      }
    }
    if (request.kind == InstallKind.quickApp &&
        (metadata.packageName == null ||
            metadata.versionCode == null ||
            metadata.versionCode! <= 0 ||
            metadata.versionCode! > maxRpkVersionCode)) {
      throw const FormatException('RPK 必须具有从清单读取的包名和有效 32 位正整数版本号');
    }
  }

  String? watchfaceCompatibilityError(InstallMetadata metadata) {
    final profile = connectedProfile;
    final expected = profile?.watchfaceResolution;
    final detected = metadata.watchfaceResolutions;
    if (profile == null || expected == null || detected.isEmpty) return null;
    if (detected.contains(expected)) return null;
    return '表盘分辨率 ${detected.join('、')} 与 ${profile.displayName} '
        '所需的 $expected 不匹配';
  }

  bool requiresUnsupportedLuaConfirmation(InstallMetadata metadata) =>
      connectedProfile?.family == DeviceFamily.redmiWatch5 &&
      metadata.containsLua;

  Future<Zau> _requestBusiness(
    Zau message,
    int command,
    int sub, {
    int? responseCommand,
    int? responseSub,
  }) async {
    final expectedCommand = responseCommand ?? command;
    final expectedSub = responseSub ?? sub;
    final waiter = _BusinessWaiter(
      _businessResponses.stream,
      (item) => item.command == expectedCommand && item.sub == expectedSub,
    );
    final plaintext = message.encode();
    final encrypted = _sessionCipher!.encryptOutbound(plaintext);
    _log('发送业务命令 $command/$sub：PB=${_hex(plaintext)}');
    try {
      await _writeL2(
        channel: SppProtocol.channelPb,
        opCode: SppProtocol.opCodeWriteEnc,
        payload: encrypted,
        timeout: const Duration(seconds: 12),
      );
      return await _withInstallCancellation(
        waiter.future.timeout(const Duration(seconds: 12)),
      );
    } finally {
      await waiter.cancel();
    }
  }

  Future<bool> syncSystemTime({bool automatic = false}) async {
    if (_timeSyncInProgress) return false;
    if (_installInProgress) {
      _log('时间同步被拒绝：安装任务正在运行。');
      return false;
    }
    final cipher = _sessionCipher;
    if (!sessionReady ||
        cipher == null ||
        (connectedDevice ?? _lastPeripheral) == null) {
      if (!automatic) {
        error = '时间同步被拒绝：请先完成 authkey 会话认证。';
        _log(error!);
      }
      return false;
    }

    _timeSyncInProgress = true;
    _installCancelled = false;
    if (!automatic) error = null;
    notifyListeners();
    try {
      final info = await const SystemTimeInfoSource().read();
      final payload = TimeSyncPayload.encode(
        localTime: info.localTime,
        standardOffsetMinutes: info.standardOffsetMinutes,
        daylightOffsetMinutes: info.daylightOffsetMinutes,
        timezoneId: info.timezoneId,
        use24Hour: info.use24Hour,
      );
      final message = Zau(
        command: ZauCommand.setSystemTime,
        sub: 3,
        payload: payload,
      );
      await _sendBusinessNoResponse(message);
      final totalOffset =
          info.standardOffsetMinutes + info.daylightOffsetMinutes;
      final offsetSign = totalOffset < 0 ? '-' : '+';
      final offsetAbsolute = totalOffset.abs();
      final offset =
          '$offsetSign${(offsetAbsolute ~/ 60).toString().padLeft(2, '0')}:'
          '${(offsetAbsolute % 60).toString().padLeft(2, '0')}';
      final local = info.localTime;
      String two(int value) => value.toString().padLeft(2, '0');
      lastTimeSyncSummary =
          '${local.year}-${two(local.month)}-${two(local.day)} '
          '${two(local.hour)}:${two(local.minute)}:${two(local.second)} · '
          '${info.timezoneId} (UTC$offset) · ${info.use24Hour ? '24 小时制' : '12 小时制'}';
      _log('${automatic ? '自动' : '手动'}时间同步已发送：$lastTimeSyncSummary');
      return true;
    } on Object catch (exception) {
      final message = '时间同步失败：$exception';
      _log(message);
      if (!automatic) error = message;
      return false;
    } finally {
      _timeSyncInProgress = false;
      notifyListeners();
    }
  }

  Future<void> _refreshAuthenticatedDeviceStatus() async {
    final session = _sessionCipher;
    final refreshEpoch = _sessionEpoch;
    if (_statusRefreshEpoch != null || !sessionReady || session == null) {
      return;
    }
    _statusRefreshEpoch = refreshEpoch;
    notifyListeners();
    try {
      await _transferSettingsReady;
      if (refreshEpoch != _sessionEpoch ||
          !sessionReady ||
          !identical(_sessionCipher, session)) {
        return;
      }
      if (autoTimeSync) {
        final synced = await syncSystemTime(automatic: true);
        if (!synced) return;
      }
      if (refreshEpoch != _sessionEpoch ||
          !sessionReady ||
          !identical(_sessionCipher, session)) {
        return;
      }
      batteryPercent = null;
      try {
        final response = await _requestBusiness(
          Zau(command: ZauCommand.basicStatus, sub: 1),
          ZauCommand.basicStatus,
          1,
        );
        if (refreshEpoch != _sessionEpoch ||
            !sessionReady ||
            !identical(_sessionCipher, session)) {
          return;
        }
        final battery = BatteryStatusPayload.parse(response.payload);
        if (battery == null) {
          _log('设备电量响应缺少有效百分比，保持未知状态');
        } else {
          batteryPercent = battery;
          _log('设备电量：$battery%');
        }
      } on Object catch (exception) {
        _log('读取设备电量失败，保持未知状态：$exception');
      }
      if (refreshEpoch != _sessionEpoch ||
          !sessionReady ||
          !identical(_sessionCipher, session)) {
        return;
      }
      storageUsedBytes = null;
      storageTotalBytes = null;
      try {
        final response = await _requestBusiness(
          Zau(command: ZauCommand.basicStatus, sub: ZauCommand.storageStatus),
          ZauCommand.basicStatus,
          ZauCommand.storageStatus,
        );
        if (refreshEpoch != _sessionEpoch ||
            !sessionReady ||
            !identical(_sessionCipher, session)) {
          return;
        }
        final storage = StorageStatusPayload.parse(response.payload);
        if (storage == null) {
          _log('设备存储响应缺少有效容量，保持未知状态');
        } else {
          storageUsedBytes = storage.usedBytes;
          storageTotalBytes = storage.totalBytes;
          _log('设备存储：已用 ${storage.usedBytes} / 总计 ${storage.totalBytes} 字节');
        }
      } on Object catch (exception) {
        _log('读取设备存储失败，保持未知状态：$exception');
      }
    } on Object catch (exception) {
      _log('设备状态刷新失败：$exception');
    } finally {
      if (_statusRefreshEpoch == refreshEpoch) {
        _statusRefreshEpoch = null;
        notifyListeners();
      }
    }
  }

  Future<void> _sendBusinessNoResponse(Zau message) async {
    final cipher = _sessionCipher;
    if (cipher == null) throw StateError('认证会话已失效');
    final plaintext = message.encode();
    final encrypted = cipher.encryptOutbound(plaintext);
    _log('发送单向业务命令 ${message.command}/${message.sub}：PB=${_hex(plaintext)}');
    await _writeL2(
      channel: SppProtocol.channelPb,
      opCode: SppProtocol.opCodeWriteEnc,
      payload: encrypted,
      timeout: const Duration(seconds: 12),
    );
  }

  _BusinessWaiter _listenBusiness(int command, int sub) =>
      _registerCompletionWaiter(
        (item) => item.command == command && item.sub == sub,
      );

  /// 官方客户端等待 command=20/sub=2 的设备安装结果，并以包名关联任务。
  /// 结果可能来自其他应用，因此不能只按命令号取第一条消息。
  _BusinessWaiter _listenQuickAppInstallResult(String packageName) =>
      _registerCompletionWaiter((item) {
        if (item.command != ZauCommand.prepareInstallApp || item.sub != 2) {
          return false;
        }
        final payload = item.payload;
        if (payload == null) return false;
        final result = V8s.parseInstallResult(payload.$2);
        if (result.packageName != packageName) {
          _log('忽略其他快应用的安装结果：${result.packageName}');
          return false;
        }
        _log('收到快应用安装结果：包名=${result.packageName}，状态=${result.code}');
        return true;
      });

  _BusinessWaiter _registerCompletionWaiter(bool Function(Zau) predicate) {
    final waiter = _BusinessWaiter(_businessResponses.stream, predicate);
    _completionWaiters.add(waiter);
    return waiter;
  }

  Future<T> _withInstallCancellation<T>(Future<T> operation) {
    final cancellation = _installCancellation;
    final transportFailure = _installTransportFailure;
    if (cancellation == null || transportFailure == null) return operation;
    return Future.any<T>([
      operation,
      cancellation.future.then<T>((_) => throw const _InstallCancelled()),
      transportFailure.future.then<T>((error) => throw error),
    ]);
  }

  Future<void> _clearCheckpointBestEffort() async {
    try {
      await _checkpointStore.clear();
    } on Object catch (exception) {
      // 安装结果由设备事件决定；本地清理失败不能把成功误报为状态未知。
      _log('检查点清理失败，可在下次启动时安全覆盖：$exception');
    }
  }

  Future<void> _writeL2({
    required int channel,
    required int opCode,
    required List<int> payload,
    required Duration timeout,
  }) async {
    final queued = await _queueL2(
      channel: channel,
      opCode: opCode,
      payload: payload,
      timeout: timeout,
    );
    await queued.acknowledged;
  }

  Future<_QueuedL2Write> _queueL2({
    required int channel,
    required int opCode,
    required List<int> payload,
    required Duration timeout,
  }) async {
    _checkCancelled();
    final device = connectedDevice ?? _lastPeripheral;
    if (device == null || !sessionReady) throw StateError('认证会话已失效');
    final sequence = _sppSeq++ & 0xff;
    final ack = Completer<void>();
    _pendingAcks[sequence] = ack;
    if (channel == SppProtocol.channelMass) {
      _pendingMassAcks.add(sequence);
      _pendingMassAckOrder.add(sequence);
    }
    try {
      final frame = SppProtocol.buildDataFrame(
        sequence,
        payload,
        channel: channel,
        opCode: opCode,
      );
      if (channel == SppProtocol.channelMass) {
        final total = payload.length >= 2 ? payload[0] | (payload[1] << 8) : 0;
        final index = payload.length >= 4 ? payload[2] | (payload[3] << 8) : 0;
        if (index == 1 || index == total || index % 25 == 0) {
          _log('  Mass TX seq=$sequence 片=$index/$total，${payload.length}B');
        }
      } else {
        _log(
          '  RFCOMM TX seq=$sequence channel=$channel opCode=$opCode '
          'frame=${_hex(frame)}',
        );
      }
      await _transport.rfcommWrite(device.uuid, frame);
      final acknowledged = ack.future.timeout(timeout).whenComplete(() {
        _pendingAcks.remove(sequence);
        _pendingMassAcks.remove(sequence);
        _pendingMassAckOrder.remove(sequence);
      });
      return _QueuedL2Write(acknowledged);
    } on Object {
      _pendingAcks.remove(sequence);
      _pendingMassAcks.remove(sequence);
      _pendingMassAckOrder.remove(sequence);
      rethrow;
    }
  }

  /// Queues one Mass receive window as a single stream write. RFCOMM is a byte
  /// stream, so concatenating complete L1 frames is protocol-equivalent to
  /// adjacent writes while avoiding repeated WinRT StoreAsync round trips.
  Future<void> _queueMassWindow(
    List<MassSegment> segments, {
    required InstallRequest request,
    required Map<int, int> confirmedBytesBySegment,
    required int totalBytes,
    required Duration idleTimeout,
  }) async {
    _checkCancelled();
    final device = connectedDevice ?? _lastPeripheral;
    if (device == null || !sessionReady) throw StateError('认证会话已失效');
    if (segments.isEmpty || segments.length > 50) {
      throw ArgumentError.value(segments.length, 'segments', '窗口必须包含 1–50 片');
    }

    final frames = <int>[];
    final queued = <(int, Completer<void>)>[];
    for (final segment in segments) {
      final sequence = _sppSeq++ & 0xff;
      final ack = Completer<void>();
      _pendingAcks[sequence] = ack;
      _pendingMassAcks.add(sequence);
      _pendingMassAckOrder.add(sequence);
      _pendingMassProgress[sequence] = _MassProgressMarker(
        request: request,
        segmentIndex: segment.index,
        totalSegments: segment.total,
        confirmedBytes: confirmedBytesBySegment[segment.index] ?? 0,
        queuedSegment: segments.last.index,
        queuedBytes: confirmedBytesBySegment[segments.last.index] ?? 0,
        totalBytes: totalBytes,
      );
      queued.add((sequence, ack));
      frames.addAll(
        SppProtocol.buildDataFrame(
          sequence,
          segment.data,
          channel: SppProtocol.channelMass,
          opCode: SppProtocol.opCodeWrite,
        ),
      );
    }

    final first = segments.first;
    final last = segments.last;
    if (first.index == 1 ||
        last.index == last.total ||
        segments.any((segment) => segment.index % 25 == 0)) {
      _log(
        '  Mass TX 窗口 ${first.index}–${last.index}/${last.total}，'
        '${frames.length}B（单次 RFCOMM 写入）',
      );
    }

    try {
      await _transport.rfcommWrite(device.uuid, frames);
    } on Object {
      for (final (sequence, _) in queued) {
        _pendingAcks.remove(sequence);
        _pendingMassAcks.remove(sequence);
        _pendingMassAckOrder.remove(sequence);
        _pendingMassProgress.remove(sequence);
      }
      rethrow;
    }

    try {
      await waitForMassAcknowledgements(
        [for (final (_, ack) in queued) ack.future],
        idleTimeout: idleTimeout,
        timeoutMessage: (acknowledged, total) =>
            'Mass ACK 空闲超时：连续 ${idleTimeout.inSeconds} 秒没有新的累计 ACK；'
            '窗口 ${first.index}–${last.index}/${last.total} 已确认 '
            '$acknowledged/$total 片，仍有 ${total - acknowledged} 片待确认。',
      );
    } finally {
      for (final (sequence, _) in queued) {
        _pendingAcks.remove(sequence);
        _pendingMassAcks.remove(sequence);
        _pendingMassAckOrder.remove(sequence);
        _pendingMassProgress.remove(sequence);
      }
    }
  }

  void _checkCancelled() {
    if (_installCancelled) throw const _InstallCancelled();
  }

  void _resetTransferSpeed({int confirmedBytes = 0}) {
    _lastSpeedSampleAt = DateTime.now();
    _lastSpeedSampleBytes = confirmedBytes;
    _confirmedBytesPerSecond = null;
  }

  void _beginTransferTiming({required int confirmedBytes}) {
    _transferStartConfirmedBytes = confirmedBytes;
    _completedTransferElapsed = null;
    _transferStopwatch = Stopwatch()..start();
    _resetTransferSpeed(confirmedBytes: confirmedBytes);
  }

  void _finishTransferTiming() {
    final stopwatch = _transferStopwatch;
    if (stopwatch == null) return;
    stopwatch.stop();
    _completedTransferElapsed = stopwatch.elapsed;
  }

  Duration? get _currentTransferElapsed =>
      _completedTransferElapsed ?? _transferStopwatch?.elapsed;

  void _updateTransferSpeed(int confirmedBytes) {
    final now = DateTime.now();
    final previousAt = _lastSpeedSampleAt;
    final elapsedMicros = previousAt == null
        ? 0
        : now.difference(previousAt).inMicroseconds;
    final byteDelta = confirmedBytes - _lastSpeedSampleBytes;
    if (elapsedMicros > 0 && byteDelta > 0) {
      final instant =
          byteDelta * Duration.microsecondsPerSecond / elapsedMicros;
      final previous = _confirmedBytesPerSecond;
      _confirmedBytesPerSecond = previous == null
          ? instant
          : previous * 0.65 + instant * 0.35;
    }
    _lastSpeedSampleAt = now;
    _lastSpeedSampleBytes = confirmedBytes;
  }

  void _publishTask(
    InstallRequest request,
    InstallStage stage,
    String message, {
    int? currentSegment,
    int? totalSegments,
    int? confirmedBytes,
    int? queuedSegment,
    int? queuedBytes,
    int? totalBytes,
    double? bytesPerSecond,
  }) {
    final previous = latestTask;
    final sameTask =
        previous != null &&
        previous.kind == request.kind &&
        previous.fileName == request.metadata.fileName &&
        previous.md5Hex == request.metadata.md5Hex;
    final keepProgress =
        sameTask &&
        stage != InstallStage.validating &&
        stage != InstallStage.waitingForProtocol;
    final resolvedCurrentSegment =
        currentSegment ?? (keepProgress ? previous.currentSegment : null);
    final resolvedTotalSegments =
        totalSegments ?? (keepProgress ? previous.totalSegments : null);
    final resolvedConfirmedBytes =
        confirmedBytes ?? (keepProgress ? previous.confirmedBytes : null);
    final resolvedQueuedSegment =
        queuedSegment ?? (keepProgress ? previous.queuedSegment : null);
    final resolvedQueuedBytes =
        queuedBytes ?? (keepProgress ? previous.queuedBytes : null);
    final resolvedTotalBytes =
        totalBytes ?? (keepProgress ? previous.totalBytes : null);
    final resolvedSpeed =
        bytesPerSecond ?? (keepProgress ? previous.bytesPerSecond : null);
    final transferElapsed = _currentTransferElapsed;
    final transferredBytes =
        (resolvedConfirmedBytes ?? 0) - _transferStartConfirmedBytes;
    final averageBytesPerSecond =
        transferElapsed != null &&
            transferElapsed.inMicroseconds > 0 &&
            transferredBytes > 0
        ? transferredBytes *
              Duration.microsecondsPerSecond /
              transferElapsed.inMicroseconds
        : null;
    latestTask = InstallTask(
      kind: request.kind,
      fileName: request.metadata.fileName,
      stage: stage,
      message: message,
      targetDeviceName: connectedDeviceName ?? connectedProfile?.displayName,
      md5Hex: request.metadata.md5Hex,
      faceId: request.metadata.faceId,
      packageName: request.metadata.packageName,
      versionCode: request.metadata.versionCode,
      currentSegment: resolvedCurrentSegment,
      totalSegments: resolvedTotalSegments,
      confirmedBytes: resolvedConfirmedBytes,
      queuedSegment: resolvedQueuedSegment,
      queuedBytes: resolvedQueuedBytes,
      totalBytes: resolvedTotalBytes,
      bytesPerSecond: resolvedSpeed,
      elapsed: _installStopwatch?.elapsed,
      transferElapsed: transferElapsed,
      averageBytesPerSecond: averageBytesPerSecond,
    );
    final shouldLog =
        stage != InstallStage.transferring ||
        currentSegment == 1 ||
        currentSegment == totalSegments ||
        (currentSegment != null && currentSegment % 25 == 0);
    if (shouldLog) {
      _log('安装任务：${stage.name} — $message');
    } else {
      notifyListeners();
    }
  }

  List<int> _hexToBytes(String hex) => [
    for (var index = 0; index < hex.length; index += 2)
      int.parse(hex.substring(index, index + 2), radix: 16),
  ];

  @override
  void dispose() {
    _disposed = true;
    _logNotifyTimer?.cancel();
    _logNotifyTimer = null;
    _logNotificationPending = false;
    _advanceSessionEpoch();
    _sppConnectionEpoch++;
    _closingFailedSppEpoch = null;
    _clearSppHandshakeState();
    unawaited(_scanSubscription?.cancel());
    unawaited(_bluetoothStateSubscription?.cancel());
    unawaited(_sppSub?.cancel());
    _sppSub = null;
    for (final waiter in _completionWaiters) {
      unawaited(waiter.cancel());
    }
    _completionWaiters.clear();
    unawaited(_businessResponses.close());
    final device = connectedDevice ?? _lastPeripheral;
    if (device != null) {
      unawaited(_transport.disconnectRfcomm(device.uuid).catchError((_) {}));
    }
    unawaited(_transport.disposeRfcommStream());
    super.dispose();
  }
}

/// Lightweight peripheral identity used only by the macOS RFCOMM bridge.
/// CoreBluetooth GATT operations still require a real scan result; this type
/// is never passed to the GATT plugin.
class _PersistedPeripheral implements Peripheral {
  const _PersistedPeripheral(this.uuid);

  @override
  final UUID uuid;
}

class _InstallCancelled implements Exception {
  const _InstallCancelled();
}

class _DeviceInstallFailed implements Exception {
  const _DeviceInstallFailed(this.message);

  final String message;
}

class _InvalidDeviceResponse implements Exception {
  const _InvalidDeviceResponse(this.message);

  final String message;
}

class _QueuedL2Write {
  const _QueuedL2Write(this.acknowledged);

  final Future<void> acknowledged;
}

/// Cancellable buffered wait for an asynchronous business event.
///
/// The listener is installed before Mass transfer begins, but no timer is
/// started here. This prevents both missing an early result and incorrectly
/// charging file-transfer time against the device-install timeout.
class _BusinessWaiter {
  _BusinessWaiter(Stream<Zau> stream, bool Function(Zau) predicate) {
    _subscription = stream.listen(
      (item) {
        if (_completer.isCompleted) return;
        try {
          if (!predicate(item)) return;
          _completer.complete(item);
          unawaited(_subscription.cancel());
        } on Object catch (error, stackTrace) {
          _completer.completeError(error, stackTrace);
          unawaited(_subscription.cancel());
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_completer.isCompleted) {
          _completer.completeError(error, stackTrace);
        }
      },
    );
  }

  final Completer<Zau> _completer = Completer<Zau>();
  late final StreamSubscription<Zau> _subscription;

  Future<Zau> get future => _completer.future;

  Future<void> cancel() => _subscription.cancel();
}

/// Maps an L1 Mass sequence number back to exact source-file progress.
/// ACK handling publishes only the newest marker in one cumulative ACK, so a
/// large RFCOMM write remains fast without rebuilding the Flutter UI per frame.
class _MassProgressMarker {
  const _MassProgressMarker({
    required this.request,
    required this.segmentIndex,
    required this.totalSegments,
    required this.confirmedBytes,
    required this.queuedSegment,
    required this.queuedBytes,
    required this.totalBytes,
  });

  final InstallRequest request;
  final int segmentIndex;
  final int totalSegments;
  final int confirmedBytes;
  final int queuedSegment;
  final int queuedBytes;
  final int totalBytes;
}
