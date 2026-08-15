/// Standalone TUI application/state layer.
///
/// This is deliberately independent from terminal widgets and Flutter. It
/// owns the merge of saved and live classic-Bluetooth devices, credential
/// persistence, auto-connect policy, and translation of backend events into a
/// single immutable application snapshot.
library;

import 'dart:async';

import '../backend_next/tui_backend_port.dart';
import '../domain/device_profile.dart';
import '../domain/queue_file_importer.dart';
import 'persistence/saved_device_repository.dart';
import 'persistence/saved_tui_device.dart';
import 'persistence/tui_credential_store.dart';
import 'persistence/tui_preference_store.dart';
import 'tui_application_snapshot.dart';

/// Application boundary for the replacement TUI.
///
/// The interface purposefully uses application DTOs rather than terminal DTOs
/// so a terminal renderer is never allowed to drive Bluetooth directly.
abstract interface class TuiApplicationPort {
  TuiApplicationSnapshot get snapshot;
  Stream<TuiApplicationSnapshot> get snapshots;

  Future<TuiApplicationActionResult> initialize();
  Future<TuiApplicationActionResult> startScan();
  Future<TuiApplicationActionResult> stopScan();
  Future<TuiApplicationActionResult> connectDevice(String macAddress);
  Future<TuiApplicationActionResult> disconnect();
  Future<TuiApplicationActionResult> saveDevice(String macAddress);
  Future<TuiApplicationActionResult> removeSavedDevice(String macAddress);
  Future<TuiApplicationActionResult> submitAuthKey(
    String macAddress,
    String authKey,
  );
  Future<TuiApplicationActionResult> installResource(
    String macAddress,
    String literalPath,
  );
  Future<TuiApplicationActionResult> cancelInstall();
  Future<TuiApplicationActionResult> setAutoConnect(bool enabled);
  Future<TuiApplicationActionResult> setThemeId(String themeId);
  Future<void> dispose();
}

/// TUI-only application service.
///
/// A saved device is always identified by a normalized classic Bluetooth MAC,
/// never a CoreBluetooth UUID or scan-list index. Authkeys are read from and
/// written to the credential store only for that MAC.
final class TuiApplication implements TuiApplicationPort {
  TuiApplication({
    required TuiBackendPort backend,
    SavedDeviceRepository? savedDeviceRepository,
    TuiCredentialStore? credentialStore,
    TuiPreferenceStore? preferenceStore,
  })  : _backend = backend,
        _savedDeviceRepository =
            savedDeviceRepository ?? JsonSavedDeviceRepository(),
        _credentialStore = credentialStore ?? MacKeychainCredentialStore(),
        _preferenceStore = preferenceStore ?? TuiPreferenceStore(),
        _backendSnapshot = backend.snapshot {
    _backendSubscription = backend.snapshots.listen(
      _onBackendSnapshot,
      onError: _onBackendError,
    );
  }

  final TuiBackendPort _backend;
  final SavedDeviceRepository _savedDeviceRepository;
  final TuiCredentialStore _credentialStore;
  final TuiPreferenceStore _preferenceStore;
  final StreamController<TuiApplicationSnapshot> _snapshotController =
      StreamController<TuiApplicationSnapshot>.broadcast(sync: true);

  late TuiBackendSnapshot _backendSnapshot;
  StreamSubscription<TuiBackendSnapshot>? _backendSubscription;
  final Map<String, SavedTuiDevice> _savedDevices = {};
  final Map<String, String> _savedAuthKeys = {};

  TuiPreferences _preferences = const TuiPreferences();
  Future<void> _actionTail = Future<void>.value();
  int _revision = 0;
  int _connectionGeneration = 0;
  bool _initialized = false;
  bool _disposed = false;
  bool _disconnecting = false;
  bool _autoConnectSuppressed = false;
  bool _autoConnectAttempted = false;
  // Backend snapshots can arrive rapidly. Track each connection generation
  // independently so a slow persistence write for an old connection cannot
  // suppress the ready transition of a newer connection.
  final Set<int> _readyPersistenceGenerations = <int>{};
  String? _activeMacAddress;
  String? _pendingAuthKey;
  String? _pendingAuthMacAddress;
  int? _pendingAuthGeneration;
  _TargetDevice? _awaitingAuthTarget;
  String? _volatileAuthenticatedKey;
  String? _volatileAuthenticatedMacAddress;
  String? _notice;
  String? _error;
  TuiApplicationAutoConnectState _autoConnectState =
      TuiApplicationAutoConnectState.idle;

  @override
  TuiApplicationSnapshot get snapshot => _makeSnapshot();

  @override
  Stream<TuiApplicationSnapshot> get snapshots async* {
    yield snapshot;
    yield* _snapshotController.stream;
  }

  @override
  Future<TuiApplicationActionResult> initialize() => _serialize(() async {
        if (_initialized) {
          return const TuiApplicationActionResult.success('TUI 已初始化。');
        }
        try {
          _preferences = await _preferenceStore.load();
          final saved = await _savedDeviceRepository.load();
          _savedDevices
            ..clear()
            ..addEntries(
              saved.map((device) => MapEntry(device.macAddress, device)),
            );
          await _loadSavedCredentials();
          _emit();

          await _backend.initialize();
          _initialized = true;
          _notice = 'macOS 经典蓝牙后端已启动。';
          _error = null;
          await _attemptAutoConnectIfEligible();
          _emit();
          return const TuiApplicationActionResult.success('TUI 已就绪。');
        } on Object catch (error) {
          return _failure('initialize_failed', 'TUI 初始化失败：${_safe(error)}');
        }
      });

  @override
  Future<TuiApplicationActionResult> startScan() => _serialize(() async {
        final unavailable = _requireInitialized();
        if (unavailable != null) return unavailable;
        try {
          _clearError();
          await _backend.startScan();
          _notice = '正在扫描经典蓝牙设备。';
          _emit();
          return const TuiApplicationActionResult.success('扫描已启动。');
        } on Object catch (error) {
          return _failure('scan_failed', '开始扫描失败：${_safe(error)}');
        }
      });

  @override
  Future<TuiApplicationActionResult> stopScan() => _serialize(() async {
        final unavailable = _requireInitialized();
        if (unavailable != null) return unavailable;
        try {
          await _backend.stopScan();
          _notice = '扫描已停止。';
          _emit();
          return const TuiApplicationActionResult.success('扫描已停止。');
        } on Object catch (error) {
          return _failure('scan_stop_failed', '停止扫描失败：${_safe(error)}');
        }
      });

  @override
  Future<TuiApplicationActionResult> connectDevice(String macAddress) =>
      _serialize(() async {
        final unavailable = _requireInitialized();
        if (unavailable != null) return unavailable;
        return _connectDeviceNow(macAddress, fromAutoConnect: false);
      });

  Future<TuiApplicationActionResult> _connectDeviceNow(
    String macAddress, {
    required bool fromAutoConnect,
  }) async {
    final normalized = _normalizeMacOrNull(macAddress);
    if (normalized == null) {
      return _failure('invalid_input', '经典蓝牙 MAC 地址无效。');
    }
    final target = _resolveTarget(normalized);
    if (target == null) {
      return _failure('not_found', '设备不在保存历史或当前设备列表中。');
    }
    if (target.profile == null || !target.supported) {
      return _failure('unsupported_device', '该设备没有已验证的 V2 连接配置。');
    }

    _connectionGeneration++;
    final generation = _connectionGeneration;
    _activeMacAddress = normalized;
    _clearPendingAuthInput();
    _volatileAuthenticatedKey = null;
    _volatileAuthenticatedMacAddress = null;
    _clearError();

    final savedKey = _savedAuthKeys[normalized];
    if (savedKey == null) {
      // There must be no native/backend activity until the user has supplied
      // a valid key for this exact MAC. In particular, do not clear protocol
      // state here: this phase is only a TUI application state transition.
      _awaitingAuthTarget = target;
      _pendingAuthMacAddress = normalized;
      _pendingAuthGeneration = generation;
      _notice = fromAutoConnect
          ? '自动连接需要输入 authkey；尚未调用蓝牙连接。'
          : '请输入 authkey 后再建立蓝牙连接。';
      if (fromAutoConnect) {
        _autoConnectState = TuiApplicationAutoConnectState.missingAuthKey;
      }
      _emit();
      return const TuiApplicationActionResult.success('等待输入 authkey。');
    }

    _notice = fromAutoConnect ? '正在自动连接上次设备。' : '正在连接设备。';
    if (fromAutoConnect) {
      _autoConnectState = TuiApplicationAutoConnectState.connecting;
    }
    _emit();

    try {
      await _backend.provideAuthKey(savedKey);
      if (generation != _connectionGeneration || _disposed) {
        return const TuiApplicationActionResult.failure(
          'superseded',
          '连接请求已被新的操作取代。',
        );
      }
      await _backend.connectByAddress(
        address: normalized,
        name: target.name,
        profile: target.profile,
      );
      _notice = '蓝牙连接已开始，正在使用已保存 authkey 鉴权。';
      _emit();
      return const TuiApplicationActionResult.success('连接已开始。');
    } on Object catch (error) {
      if (generation == _connectionGeneration) {
        if (fromAutoConnect) {
          _autoConnectState = TuiApplicationAutoConnectState.failed;
        }
        return _failure('connect_failed', '连接失败：${_safe(error)}');
      }
      return const TuiApplicationActionResult.failure(
        'superseded',
        '连接请求已被新的操作取代。',
      );
    }
  }

  @override
  Future<TuiApplicationActionResult> disconnect() => _serialize(() async {
        final unavailable = _requireInitialized();
        if (unavailable != null) return unavailable;
        _autoConnectSuppressed = true;
        _autoConnectState =
            TuiApplicationAutoConnectState.suppressedAfterDisconnect;
        _connectionGeneration++;
        _clearPendingAuthInput();
        if (_backendSnapshot.connection ==
            TuiBackendConnectionState.disconnected) {
          _activeMacAddress = null;
          _disconnecting = false;
          _notice = '已取消等待 authkey。';
          _clearError();
          _emit();
          return const TuiApplicationActionResult.success('已取消等待 authkey。');
        }
        _disconnecting = true;
        _notice = '正在断开连接。';
        _clearError();
        _emit();
        try {
          await _backend.disconnect();
          _activeMacAddress = null;
          _volatileAuthenticatedKey = null;
          _volatileAuthenticatedMacAddress = null;
          _notice = '已断开连接。';
          _emit();
          return const TuiApplicationActionResult.success('已断开连接。');
        } on Object catch (error) {
          return _failure('disconnect_failed', '断开失败：${_safe(error)}');
        } finally {
          _disconnecting = false;
          _emit();
        }
      });

  @override
  Future<TuiApplicationActionResult> saveDevice(String macAddress) =>
      _serialize(() async {
        final unavailable = _requireInitialized();
        if (unavailable != null) return unavailable;
        final normalized = _normalizeMacOrNull(macAddress);
        if (normalized == null) {
          return _failure('invalid_input', '经典蓝牙 MAC 地址无效。');
        }
        final target = _resolveTarget(normalized);
        if (target == null) {
          return _failure('not_found', '没有可保存的设备。');
        }
        final record = SavedTuiDevice(
          displayName: target.name,
          macAddress: normalized,
          isSupported: target.supported,
          profileId: target.profile?.family.name,
          // Saving a device after it has already reached ready must still make
          // it the candidate for a subsequent process-start auto-connect.
          lastConnectedAt: normalized == _activeMacAddress &&
                  _backendSnapshot.connection == TuiBackendConnectionState.ready
              ? DateTime.now().toUtc()
              : _savedDevices[normalized]?.lastConnectedAt,
        );
        try {
          await _savedDeviceRepository.save(record);
          _savedDevices[normalized] = record;
          await _persistVolatileKeyIfEligible(normalized);
          _notice = '已保存设备。';
          _clearError();
          _emit();
          return const TuiApplicationActionResult.success('已保存设备。');
        } on Object catch (error) {
          return _failure('save_failed', '保存设备失败：${_safe(error)}');
        }
      });

  @override
  Future<TuiApplicationActionResult> removeSavedDevice(String macAddress) =>
      _serialize(() async {
        final normalized = _normalizeMacOrNull(macAddress);
        if (normalized == null) {
          return _failure('invalid_input', '经典蓝牙 MAC 地址无效。');
        }
        if (!_savedDevices.containsKey(normalized)) {
          return _failure('not_saved', '该设备未保存。');
        }
        try {
          await _savedDeviceRepository.removeByMacAddress(normalized);
          try {
            await _credentialStore.removeAuthKey(normalized);
          } on Object {
            // The device record is already gone. Do not restore it just because
            // Keychain cleanup is unavailable; avoid exposing key diagnostics.
            _notice = '已取消保存；系统密钥清理将在下次可用时重试。';
          }
          _savedDevices.remove(normalized);
          _savedAuthKeys.remove(normalized);
          if (_pendingAuthMacAddress == normalized) _clearPendingAuthInput();
          _clearError();
          _notice ??= '已取消保存设备。';
          _emit();
          return const TuiApplicationActionResult.success('已取消保存设备。');
        } on Object catch (error) {
          return _failure('remove_saved_failed', '取消保存失败：${_safe(error)}');
        }
      });

  @override
  Future<TuiApplicationActionResult> submitAuthKey(
    String macAddress,
    String authKey,
  ) =>
      _serialize(() async {
        final unavailable = _requireInitialized();
        if (unavailable != null) return unavailable;
        final normalized = _normalizeMacOrNull(macAddress);
        if (normalized == null ||
            normalized != _activeMacAddress ||
            normalized != _pendingAuthMacAddress ||
            _awaitingAuthTarget == null ||
            _pendingAuthGeneration != _connectionGeneration) {
          return _failure('not_waiting_for_authkey', '请先对该设备发起连接，再输入 authkey。');
        }
        String key;
        try {
          key = normalizeTuiAuthKey(authKey);
        } on FormatException {
          return _failure('invalid_input', 'authkey 必须是 32 位十六进制字符。');
        }
        try {
          final target = _awaitingAuthTarget!;
          final generation = _connectionGeneration;
          _pendingAuthKey = key;
          _volatileAuthenticatedKey = key;
          _volatileAuthenticatedMacAddress = normalized;
          await _backend.provideAuthKey(key);
          if (generation != _connectionGeneration || _disposed) {
            return const TuiApplicationActionResult.failure(
              'superseded',
              '连接请求已被新的操作取代。',
            );
          }
          _awaitingAuthTarget = null;
          // Keep the normalized MAC and generation until the ready transition
          // has persisted this exact key. Only the pre-connect target is no
          // longer needed once the backend operation has begun.
          _pendingAuthGeneration = generation;
          await _backend.connectByAddress(
            address: normalized,
            name: target.name,
            profile: target.profile,
          );
          _notice = _savedDevices.containsKey(normalized)
              ? 'authkey 已提交，正在建立蓝牙连接；认证成功后会安全保存。'
              : 'authkey 已提交，正在建立蓝牙连接；设备未保存时不会持久化该密钥。';
          _clearError();
          _emit();
          return const TuiApplicationActionResult.success('已提交 authkey。');
        } on Object catch (error) {
          _clearPendingAuthInput();
          _volatileAuthenticatedKey = null;
          _volatileAuthenticatedMacAddress = null;
          return _failure('auth_failed', '提交 authkey 失败：${_safe(error)}');
        }
      });

  @override
  Future<TuiApplicationActionResult> installResource(
    String macAddress,
    String literalPath,
  ) =>
      _serialize(() async {
        final unavailable = _requireInitialized();
        if (unavailable != null) return unavailable;
        final normalized = _normalizeMacOrNull(macAddress);
        if (normalized == null || normalized != _activeMacAddress) {
          return _failure('not_active', '资源必须安装到当前连接的设备。');
        }
        if (_backendSnapshot.connection != TuiBackendConnectionState.ready) {
          return _failure('not_ready', '请先完成设备鉴权。');
        }
        try {
          final imported = await QueueFileImporter().prepare([literalPath]);
          if (imported.requests.isEmpty) {
            return _failure(
              'file_invalid',
              imported.unsupportedCount > 0
                  ? '只支持 .bin、.face 或 .rpk 资源。'
                  : '资源文件无法读取或元数据无效。',
            );
          }
          final request = imported.requests.single;
          _notice = '正在准备安装 ${request.metadata.fileName}。';
          _clearError();
          _emit();
          await _backend.install(request);
          return const TuiApplicationActionResult.success('安装任务已结束。');
        } on Object catch (error) {
          return _failure('install_failed', '安装未完成：${_safe(error)}');
        }
      });

  @override
  Future<TuiApplicationActionResult> cancelInstall() async {
    final unavailable = _requireInitialized();
    if (unavailable != null) return unavailable;
    try {
      // Cancellation must not wait behind the long-running installation action
      // in [_actionTail]. The backend owns the transport-safe interruption.
      await _backend.cancelInstall();
      _notice = '已请求取消安装。';
      _clearError();
      _emit();
      return const TuiApplicationActionResult.success('已请求取消安装。');
    } on Object catch (error) {
      return _failure('install_cancel_failed', '取消安装失败：${_safe(error)}');
    }
  }

  @override
  Future<TuiApplicationActionResult> setAutoConnect(bool enabled) =>
      _serialize(() async {
        try {
          await _preferenceStore.setAutoConnectLastDevice(enabled);
          _preferences = _preferences.copyWith(autoConnectLastDevice: enabled);
          if (!enabled) {
            _autoConnectState = TuiApplicationAutoConnectState.disabled;
          } else if (_autoConnectSuppressed) {
            _autoConnectState =
                TuiApplicationAutoConnectState.suppressedAfterDisconnect;
          } else {
            _autoConnectState = TuiApplicationAutoConnectState.idle;
            if (_initialized && !_autoConnectAttempted) {
              await _attemptAutoConnectIfEligible();
            }
          }
          _notice = enabled ? '已开启自动连接。' : '已关闭自动连接。';
          _clearError();
          _emit();
          return TuiApplicationActionResult.success(_notice!);
        } on Object catch (error) {
          return _failure('preference_failed', '保存设置失败：${_safe(error)}');
        }
      });

  @override
  Future<TuiApplicationActionResult> setThemeId(String themeId) =>
      _serialize(() async {
        final normalized = themeId.trim();
        if (normalized.isEmpty) {
          return _failure('invalid_input', '主题标识不能为空。');
        }
        try {
          await _preferenceStore.setThemeId(normalized);
          _preferences = _preferences.copyWith(themeId: normalized);
          _notice = '主题设置已保存。';
          _clearError();
          _emit();
          return const TuiApplicationActionResult.success('主题设置已保存。');
        } on Object catch (error) {
          return _failure('preference_failed', '保存主题失败：${_safe(error)}');
        }
      });

  Future<void> _loadSavedCredentials() async {
    _savedAuthKeys.clear();
    for (final device in _savedDevices.values) {
      try {
        final key = await _credentialStore.readAuthKey(device.macAddress);
        if (key != null) {
          _savedAuthKeys[device.macAddress] = normalizeTuiAuthKey(key);
        }
      } on Object {
        // A transient Keychain failure must not prevent device history from
        // being displayed. The key is simply shown as not saved this run.
      }
    }
  }

  Future<void> _attemptAutoConnectIfEligible() async {
    if (_autoConnectAttempted) return;
    _autoConnectAttempted = true;
    if (!_preferences.autoConnectLastDevice) {
      _autoConnectState = TuiApplicationAutoConnectState.disabled;
      return;
    }
    if (_autoConnectSuppressed) {
      _autoConnectState =
          TuiApplicationAutoConnectState.suppressedAfterDisconnect;
      return;
    }
    final candidate = _lastConnectedSavedDevice();
    if (candidate == null) {
      _autoConnectState = TuiApplicationAutoConnectState.noSavedDevice;
      return;
    }
    final result = await _connectDeviceNow(
      candidate.macAddress,
      fromAutoConnect: true,
    );
    if (!result.accepted) {
      _autoConnectState = TuiApplicationAutoConnectState.failed;
    }
  }

  SavedTuiDevice? _lastConnectedSavedDevice() {
    SavedTuiDevice? result;
    for (final device in _savedDevices.values) {
      if (device.lastConnectedAt == null) continue;
      if (result == null ||
          device.lastConnectedAt!.isAfter(result.lastConnectedAt!)) {
        result = device;
      }
    }
    return result;
  }

  void _onBackendSnapshot(TuiBackendSnapshot value) {
    if (_disposed) return;
    _backendSnapshot = value;
    final active = _normalizeMacOrNull(value.activeDeviceAddress ?? '');
    if (active != null) _activeMacAddress = active;
    if (value.connection == TuiBackendConnectionState.disconnected) {
      // Connection state is authoritative even when a native adapter retains
      // the previous address in a final disconnected snapshot.
      _activeMacAddress = null;
    }
    if (value.failureCode != null) {
      _error = _safe(value.message ?? 'macOS Bluetooth 后端操作失败。');
      if (_autoConnectState == TuiApplicationAutoConnectState.connecting) {
        _autoConnectState = TuiApplicationAutoConnectState.failed;
      }
    }
    if (value.connection == TuiBackendConnectionState.ready && active != null) {
      if (_autoConnectState == TuiApplicationAutoConnectState.connecting) {
        _autoConnectState = TuiApplicationAutoConnectState.ready;
      }
      unawaited(_persistReadyConnection(active, _connectionGeneration));
    }
    _emit();
  }

  void _onBackendError(Object error, [StackTrace? stackTrace]) {
    if (_disposed) return;
    _error = 'macOS Bluetooth 后端异常：${_safe(error)}';
    if (_autoConnectState == TuiApplicationAutoConnectState.connecting) {
      _autoConnectState = TuiApplicationAutoConnectState.failed;
    }
    _emit();
  }

  Future<void> _persistReadyConnection(
      String macAddress, int generation) async {
    if (_disposed || !_readyPersistenceGenerations.add(generation)) return;
    try {
      if (macAddress != _activeMacAddress ||
          generation != _connectionGeneration) {
        return;
      }
      final saved = _savedDevices[macAddress];
      if (saved != null) {
        final updated = saved.copyWith(lastConnectedAt: DateTime.now().toUtc());
        await _savedDeviceRepository.save(updated);
        // A user can cancel saving or begin a new connection while persistence
        // is in flight. Never resurrect removed history in the memory view.
        if (_isCurrentConnection(macAddress, generation) &&
            identical(_savedDevices[macAddress], saved)) {
          _savedDevices[macAddress] = updated;
        }
      }
      if (!_isCurrentConnection(macAddress, generation)) return;
      if (_pendingAuthMacAddress == macAddress &&
          _pendingAuthGeneration == generation &&
          _pendingAuthKey != null) {
        final key = _pendingAuthKey!;
        _pendingAuthKey = null;
        _pendingAuthMacAddress = null;
        _pendingAuthGeneration = null;
        _volatileAuthenticatedKey = key;
        _volatileAuthenticatedMacAddress = macAddress;
        await _persistVolatileKeyIfEligible(macAddress);
      }
      _notice = '设备已完成认证并进入就绪状态。';
      _clearError();
    } on Object {
      // Keychain/history persistence is auxiliary to an already-established
      // session. Keep the session usable while reporting a safe error.
      _error = '设备已连接，但无法保存本次连接历史或 authkey。';
    } finally {
      _readyPersistenceGenerations.remove(generation);
      if (!_disposed) _emit();
    }
  }

  Future<void> _persistVolatileKeyIfEligible(String macAddress) async {
    if (!_savedDevices.containsKey(macAddress) ||
        _volatileAuthenticatedMacAddress != macAddress ||
        _volatileAuthenticatedKey == null ||
        _backendSnapshot.connection != TuiBackendConnectionState.ready) {
      return;
    }
    final key = _volatileAuthenticatedKey!;
    await _credentialStore.saveAuthKey(macAddress, key);
    _savedAuthKeys[macAddress] = key;
  }

  bool _isCurrentConnection(String macAddress, int generation) =>
      !_disposed &&
      generation == _connectionGeneration &&
      macAddress == _activeMacAddress &&
      _backendSnapshot.connection == TuiBackendConnectionState.ready;

  _TargetDevice? _resolveTarget(String macAddress) {
    final saved = _savedDevices[macAddress];
    TuiBackendDevice? backendDevice;
    for (final device in _backendSnapshot.devices) {
      if (_normalizeMacOrNull(device.address) == macAddress) {
        backendDevice = device;
        break;
      }
    }
    if (saved == null && backendDevice == null) return null;
    final profile = _profileFromId(saved?.profileId) ??
        backendDevice?.profile ??
        DeviceProfile.matchAdvertisementName(saved?.displayName ?? '');
    final name = saved?.displayName ?? backendDevice?.name ?? macAddress;
    return _TargetDevice(
      name: name,
      profile: profile,
      supported: saved?.isSupported ?? backendDevice?.supported ?? false,
    );
  }

  DeviceProfile? _profileFromId(String? id) {
    if (id == null) return null;
    for (final profile in DeviceProfile.recognized) {
      if (profile.family.name == id) return profile;
    }
    return null;
  }

  TuiApplicationSnapshot _makeSnapshot() {
    final liveByMac = <String, TuiBackendDevice>{};
    for (final device in _backendSnapshot.devices) {
      final mac = _normalizeMacOrNull(device.address);
      if (mac != null) liveByMac[mac] = device;
    }
    final allAddresses = <String>{..._savedDevices.keys, ...liveByMac.keys};
    final readyMac =
        _backendSnapshot.connection == TuiBackendConnectionState.ready
            ? _normalizeMacOrNull(_backendSnapshot.activeDeviceAddress ?? '')
            : null;
    final devices = allAddresses.map((macAddress) {
      final saved = _savedDevices[macAddress];
      final live = liveByMac[macAddress];
      final profile = _profileFromId(saved?.profileId) ??
          live?.profile ??
          DeviceProfile.matchAdvertisementName(saved?.displayName ?? '');
      final support = saved != null
          ? (saved.isSupported
              ? TuiApplicationDeviceSupport.supported
              : TuiApplicationDeviceSupport.unsupported)
          : live == null
              ? TuiApplicationDeviceSupport.unknown
              : live.supported
                  ? TuiApplicationDeviceSupport.supported
                  : profile == null
                      ? TuiApplicationDeviceSupport.unknown
                      : TuiApplicationDeviceSupport.unsupported;
      return TuiApplicationDevice(
        name: saved?.displayName ?? live?.name ?? macAddress,
        macAddress: macAddress,
        support: support,
        saved: saved != null,
        savedAuthKey: saved == null ? null : _savedAuthKeys[macAddress],
        profileId: profile?.family.name,
        profileName: profile?.displayName,
        paired: live?.paired ?? false,
        rssi: live?.rssi,
        connected: readyMac == macAddress,
      );
    }).toList()
      ..sort((left, right) {
        if (left.saved != right.saved) return left.saved ? -1 : 1;
        final byName =
            left.name.toLowerCase().compareTo(right.name.toLowerCase());
        return byName != 0
            ? byName
            : left.macAddress.compareTo(right.macAddress);
      });
    return TuiApplicationSnapshot(
      revision: _revision,
      devices: devices,
      connection: _connectionState(),
      activeDeviceId: _activeMacAddress,
      scanning: _backendSnapshot.scanning,
      autoConnectEnabled: _preferences.autoConnectLastDevice,
      autoConnectState: _autoConnectState,
      themeId: _preferences.themeId,
      installation: _installationStatus(_backendSnapshot.installation),
      notice: _safeNullable(_notice),
      error: _safeNullable(_error),
    );
  }

  TuiApplicationConnectionState _connectionState() {
    if (_disconnecting) return TuiApplicationConnectionState.disconnecting;
    if (_awaitingAuthTarget != null &&
        _pendingAuthMacAddress == _activeMacAddress) {
      return TuiApplicationConnectionState.awaitingAuthKey;
    }
    if (_backendSnapshot.failureCode != null &&
        _backendSnapshot.connection == TuiBackendConnectionState.disconnected) {
      return TuiApplicationConnectionState.failed;
    }
    return switch (_backendSnapshot.connection) {
      TuiBackendConnectionState.disconnected =>
        TuiApplicationConnectionState.disconnected,
      TuiBackendConnectionState.connecting =>
        TuiApplicationConnectionState.connecting,
      TuiBackendConnectionState.awaitingAuthKey =>
        TuiApplicationConnectionState.awaitingAuthKey,
      TuiBackendConnectionState.authenticating =>
        TuiApplicationConnectionState.authenticating,
      TuiBackendConnectionState.ready => TuiApplicationConnectionState.ready,
    };
  }

  TuiApplicationInstallStatus _installationStatus(
    TuiBackendInstallation? installation,
  ) {
    if (installation == null) return const TuiApplicationInstallStatus();
    return TuiApplicationInstallStatus(
      phase: switch (installation.state) {
        TuiBackendInstallState.idle => TuiApplicationInstallPhase.idle,
        TuiBackendInstallState.validating ||
        TuiBackendInstallState.waitingForProtocol =>
          TuiApplicationInstallPhase.preparing,
        TuiBackendInstallState.transferring =>
          TuiApplicationInstallPhase.transferring,
        TuiBackendInstallState.awaitingDevice =>
          TuiApplicationInstallPhase.awaitingDevice,
        TuiBackendInstallState.succeeded =>
          TuiApplicationInstallPhase.succeeded,
        TuiBackendInstallState.cancelled ||
        TuiBackendInstallState.failed =>
          TuiApplicationInstallPhase.failed,
        TuiBackendInstallState.stateUnknown =>
          TuiApplicationInstallPhase.unknown,
      },
      fileName: installation.fileName,
      confirmedBytes: installation.confirmedBytes ?? 0,
      totalBytes: installation.totalBytes ?? 0,
      message: _safeNullable(installation.message),
      successVerifiedByDeviceBusinessEvent:
          installation.successVerifiedByDeviceBusinessEvent,
    );
  }

  TuiApplicationActionResult? _requireInitialized() {
    if (_disposed) {
      return const TuiApplicationActionResult.failure('disposed', 'TUI 已释放。');
    }
    if (!_initialized) {
      return const TuiApplicationActionResult.failure(
        'not_initialized',
        'TUI 尚未初始化。',
      );
    }
    return null;
  }

  Future<TuiApplicationActionResult> _serialize(
    Future<TuiApplicationActionResult> Function() action,
  ) {
    if (_disposed) {
      return Future.value(
        const TuiApplicationActionResult.failure('disposed', 'TUI 已释放。'),
      );
    }
    final next = _actionTail.then<TuiApplicationActionResult>(
      (_) => action(),
      onError: (_) => action(),
    );
    _actionTail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  TuiApplicationActionResult _failure(String code, String message) {
    _error = _safe(message);
    _notice = null;
    _emit();
    return TuiApplicationActionResult.failure(code, _error!);
  }

  void _clearError() => _error = null;

  void _clearPendingAuthInput() {
    _pendingAuthKey = null;
    _pendingAuthMacAddress = null;
    _pendingAuthGeneration = null;
    _awaitingAuthTarget = null;
  }

  void _emit() {
    if (_disposed || _snapshotController.isClosed) return;
    _revision++;
    _snapshotController.add(_makeSnapshot());
  }

  String? _normalizeMacOrNull(String value) {
    try {
      return SavedTuiDevice.normalizeMacAddress(value);
    } on FormatException {
      return null;
    }
  }

  String _safe(Object value) {
    var text = value.toString();
    final secrets = <String>[..._savedAuthKeys.values];
    if (_pendingAuthKey != null) secrets.add(_pendingAuthKey!);
    if (_volatileAuthenticatedKey != null) {
      secrets.add(_volatileAuthenticatedKey!);
    }
    for (final key in secrets) {
      if (key.isNotEmpty) text = text.replaceAll(key, '<redacted>');
    }
    return text;
  }

  String? _safeNullable(String? value) => value == null ? null : _safe(value);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _backendSubscription?.cancel();
    await _backend.dispose();
    await _snapshotController.close();
  }
}

final class _TargetDevice {
  const _TargetDevice({
    required this.name,
    required this.profile,
    required this.supported,
  });

  final String name;
  final DeviceProfile? profile;
  final bool supported;
}
