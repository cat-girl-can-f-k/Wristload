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
import 'persistence/tui_binding_material_store.dart';
import 'persistence/tui_preference_store.dart';
import 'tui_application_snapshot.dart';

/// Describes the caller's explicit identity authority for one connection
/// attempt. The default is strict; a Bluetooth address alone never upgrades
/// an attempt to [directedExactAddress].
enum TuiApplicationConnectionIntent { strict, directedExactAddress }

/// An explicitly configured, process-local Classic Bluetooth target.
///
/// This configuration is deliberately separate from saved devices: it grants
/// no durable authority and is never inferred from a scan result, BLE identity,
/// saved MAC, or authkey.
final class TuiDirectedClassicTarget {
  factory TuiDirectedClassicTarget({
    required String macAddress,
    required String displayName,
    required DeviceProfile profile,
  }) {
    final canonicalProfile = _canonicalProfile(profile.family);
    if (canonicalProfile == null) {
      throw ArgumentError.value(
        profile,
        'profile',
        'Directed Classic target profile must be recognized.',
      );
    }
    return TuiDirectedClassicTarget._(
      macAddress: SavedTuiDevice.normalizeMacAddress(macAddress),
      displayName: _requireDisplayName(displayName),
      profile: canonicalProfile,
    );
  }

  factory TuiDirectedClassicTarget.fromExplicitProfileId({
    required String macAddress,
    required String displayName,
    required String profileId,
  }) {
    final normalizedProfileId = profileId.trim();
    DeviceProfile? profile;
    for (final candidate in DeviceProfile.recognized) {
      if (candidate.family.name == normalizedProfileId) {
        profile = candidate;
        break;
      }
    }
    if (profile == null) {
      throw const FormatException(
          'Directed Classic target profile is invalid.');
    }
    return TuiDirectedClassicTarget(
      macAddress: macAddress,
      displayName: displayName,
      profile: profile,
    );
  }

  const TuiDirectedClassicTarget._({
    required this.macAddress,
    required this.displayName,
    required this.profile,
  });

  final String macAddress;
  final String displayName;
  final DeviceProfile profile;

  static final RegExp _controlCharacters = RegExp(r'[\x00-\x1F\x7F]');

  static DeviceProfile? _canonicalProfile(DeviceFamily family) {
    for (final candidate in DeviceProfile.recognized) {
      if (candidate.family == family) return candidate;
    }
    return null;
  }

  static String _requireDisplayName(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || _controlCharacters.hasMatch(normalized)) {
      throw const FormatException(
        'Directed Classic target name is invalid.',
      );
    }
    return normalized;
  }
}

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
  Future<TuiApplicationActionResult> connectDevice(
    String macAddress, {
    TuiApplicationConnectionIntent intent =
        TuiApplicationConnectionIntent.strict,
  });

  /// Connects a device row currently supplied by Classic discovery using that
  /// row's exact Classic address. Saved-only rows retain the strict path.
  Future<TuiApplicationActionResult> connectSelectedScannedDevice(
    String macAddress,
  );
  Future<TuiApplicationActionResult> connectDirectedExactAddress();
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
    TuiBindingMaterialStore? bindingMaterialStore,
    TuiPreferenceStore? preferenceStore,
    TuiDirectedClassicTarget? directedClassicTarget,
  })  : _backend = backend,
        _savedDeviceRepository =
            savedDeviceRepository ?? JsonSavedDeviceRepository(),
        _credentialStore = credentialStore ?? MacKeychainCredentialStore(),
        _bindingMaterialStore =
            bindingMaterialStore ?? MacKeychainTuiBindingMaterialStore(),
        _preferenceStore = preferenceStore ?? TuiPreferenceStore(),
        _directedClassicTarget = directedClassicTarget,
        _backendSnapshot = backend.snapshot {
    _backendSubscription = backend.snapshots.listen(
      _onBackendSnapshot,
      onError: _onBackendError,
    );
  }

  final TuiBackendPort _backend;
  final SavedDeviceRepository _savedDeviceRepository;
  final TuiCredentialStore _credentialStore;
  final TuiBindingMaterialStore _bindingMaterialStore;
  final TuiPreferenceStore _preferenceStore;
  final TuiDirectedClassicTarget? _directedClassicTarget;
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
  bool _connectionFailed = false;
  bool _autoConnectSuppressed = false;
  bool _autoConnectAttempted = false;
  // Backend snapshots can arrive rapidly. Track each connection generation
  // independently so a slow persistence write for an old connection cannot
  // suppress the ready transition of a newer connection.
  final Set<int> _readyPersistenceGenerations = <int>{};
  final Set<int> _identityConfirmationGenerations = <int>{};
  final Set<int> _bestEffortDisconnectGenerations = <int>{};
  String? _activeMacAddress;
  String? _selectedMacAddress;
  String? _pendingAuthKey;
  _TargetDevice? _awaitingAuthTarget;
  // The immutable target selected for the current connection attempt. Backend
  // snapshots are observations, not a new selection, so they must not retarget
  // an auth modal or a pending persistence operation.
  _TargetDevice? _connectionTarget;
  int? _connectIssuedGeneration;
  // Credential loading can synchronously publish an old backend snapshot.
  // Keep this application-owned generation in connecting state until the
  // native connection dispatch has started, so it cannot reopen an auth modal.
  int? _credentialSubmissionGeneration;
  // The application attempt and the physical/native connection are separate
  // identities. Once observed, this tuple is immutable for the attempt.
  int? _attemptBackendGeneration;
  String? _attemptConnectionId;
  String? _attemptIdentityCandidateId;
  int? _attemptIdentityGeneration;
  String? _confirmedConnectionId;
  int? _confirmedIdentityGeneration;
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
  Future<TuiApplicationActionResult> connectDevice(
    String macAddress, {
    TuiApplicationConnectionIntent intent =
        TuiApplicationConnectionIntent.strict,
  }) =>
      _serialize(() async {
        final unavailable = _requireInitialized();
        if (unavailable != null) return unavailable;
        if (intent == TuiApplicationConnectionIntent.directedExactAddress) {
          final target = _directedClassicTarget;
          final normalized = _normalizeMacOrNull(macAddress);
          if (target == null || normalized != target.macAddress) {
            return _failure(
              'directed_target_unavailable',
              '定向连接只允许本次启动时明确配置的 Classic 设备。',
            );
          }
          return _connectTargetNow(
            target.macAddress,
            _targetFromDirectedClassicTarget(target),
            fromAutoConnect: false,
            intent: TuiApplicationConnectionIntent.directedExactAddress,
            isTransientDirectedTarget: true,
          );
        }
        return _connectDeviceNow(
          macAddress,
          fromAutoConnect: false,
          intent: TuiApplicationConnectionIntent.strict,
        );
      });

  @override
  Future<TuiApplicationActionResult> connectSelectedScannedDevice(
    String macAddress,
  ) =>
      _serialize(() async {
        final unavailable = _requireInitialized();
        if (unavailable != null) return unavailable;
        final normalized = _normalizeMacOrNull(macAddress);
        if (normalized == null) {
          return _failure('invalid_input', '经典蓝牙 MAC 地址无效。');
        }
        final liveDevice = _liveBackendDeviceForMac(normalized);
        if (liveDevice == null) {
          // The UI can still select saved history rows. Those do not carry a
          // current discovery authority, so keep their existing strict path.
          return _connectDeviceNow(
            normalized,
            fromAutoConnect: false,
            intent: TuiApplicationConnectionIntent.strict,
          );
        }
        // This is a current Classic discovery row. Its exact address, name,
        // and recognized profile are the authority for this direct attempt;
        // a stale saved record may still provide its authkey, but must not
        // retarget or downgrade the live device identity.
        final target = _TargetDevice(
          name: liveDevice.name,
          profile: liveDevice.profile,
          supported: liveDevice.supported,
        );
        return _connectTargetNow(
          normalized,
          target,
          fromAutoConnect: false,
          intent: TuiApplicationConnectionIntent.directedExactAddress,
        );
      });

  @override
  Future<TuiApplicationActionResult> connectDirectedExactAddress() =>
      _serialize(() async {
        final unavailable = _requireInitialized();
        if (unavailable != null) return unavailable;
        final target = _directedClassicTarget;
        if (target == null) {
          return _failure(
            'directed_target_unavailable',
            '本次 TUI 未配置定向 Classic 设备。',
          );
        }
        return _connectTargetNow(
          target.macAddress,
          _targetFromDirectedClassicTarget(target),
          fromAutoConnect: false,
          intent: TuiApplicationConnectionIntent.directedExactAddress,
          isTransientDirectedTarget: true,
        );
      });

  Future<TuiApplicationActionResult> _connectDeviceNow(
    String macAddress, {
    required bool fromAutoConnect,
    TuiApplicationConnectionIntent intent =
        TuiApplicationConnectionIntent.strict,
    bool includeDirectedSessionTarget = true,
  }) async {
    final normalized = _normalizeMacOrNull(macAddress);
    if (normalized == null) {
      return _failure('invalid_input', '经典蓝牙 MAC 地址无效。');
    }
    final target = _resolveTarget(
      normalized,
      includeDirectedSessionTarget: includeDirectedSessionTarget,
    );
    if (target == null) {
      return _failure('not_found', '设备不在保存历史或当前设备列表中。');
    }
    return _connectTargetNow(
      normalized,
      target,
      fromAutoConnect: fromAutoConnect,
      intent: intent,
    );
  }

  Future<TuiApplicationActionResult> _connectTargetNow(
    String normalized,
    _TargetDevice target, {
    required bool fromAutoConnect,
    required TuiApplicationConnectionIntent intent,
    bool isTransientDirectedTarget = false,
  }) async {
    if (target.profile == null || !target.supported) {
      return _failure('unsupported_device', '该设备没有已验证的 V2 连接配置。');
    }

    _connectionGeneration++;
    final generation = _connectionGeneration;
    _activeMacAddress = normalized;
    _selectedMacAddress = normalized;
    _connectionFailed = false;
    _clearPendingAuthInput();
    _connectionTarget = target.copyWith(
      macAddress: normalized,
      generation: generation,
      directedExactAddress:
          intent == TuiApplicationConnectionIntent.directedExactAddress,
      isTransientDirectedTarget: isTransientDirectedTarget,
    );
    _connectIssuedGeneration = null;
    _clearAttemptTuple();
    _volatileAuthenticatedKey = null;
    _volatileAuthenticatedMacAddress = null;
    _clearError();

    final savedKey = _savedAuthKeys[normalized];
    if (savedKey == null) {
      // There must be no native/backend activity until the user has supplied
      // a valid key for this exact MAC. In particular, do not clear protocol
      // state here: this phase is only a TUI application state transition.
      _awaitingAuthTarget = _connectionTarget;
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

    final bindingResult = await _readBindingMaterial(normalized);
    if (generation != _connectionGeneration || _disposed) {
      return const TuiApplicationActionResult.failure(
        'superseded',
        '连接请求已被新的操作取代。',
      );
    }
    final bindingMaterial = bindingResult.material;
    if (bindingResult.message != null) {
      // WearAuthV2 binding material is optional. Its absence uses the official
      // nonce-only Classic f=26 branch and does not block this attempt.
      _notice = bindingResult.message;
    }

    try {
      await _backend.provideAuthKey(savedKey);
      if (generation != _connectionGeneration || _disposed) {
        return const TuiApplicationActionResult.failure(
          'superseded',
          '连接请求已被新的操作取代。',
        );
      }
      _connectIssuedGeneration = generation;
      await _backend.connectByAddress(
        address: normalized,
        name: target.name,
        profile: target.profile,
        requireConfirmedIdentity: fromAutoConnect,
        directedExactAddress: _connectionTarget!.directedExactAddress,
        attemptGeneration: generation,
        bindingMaterial: bindingMaterial,
      );
      _notice = bindingResult.message == null
          ? '蓝牙连接已开始，正在使用已保存 authkey 鉴权。'
          : '蓝牙连接已开始；${bindingResult.message}';
      _emit();
      return const TuiApplicationActionResult.success('连接已开始。');
    } on Object catch (error) {
      if (generation == _connectionGeneration) {
        _retireCurrentAttempt(generation);
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
        _connectionFailed = false;
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
          _connectionFailed = true;
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
          lastConnectedAt:
              normalized == _activeMacAddress && _isCurrentBackendTargetReady()
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
        // Removing the target of any current connection attempt invalidates
        // that entire attempt, not just an authkey prompt. Retire it before
        // awaiting storage so an in-flight or late ready snapshot cannot
        // recreate the device, authkey, or session ownership.
        final currentTarget = _connectionTarget;
        final removingCurrentAttempt =
            currentTarget?.macAddress == normalized &&
                currentTarget?.generation == _connectionGeneration;
        final shouldDisconnect = removingCurrentAttempt &&
            _connectIssuedGeneration == _connectionGeneration;
        if (removingCurrentAttempt) {
          _retireCurrentAttempt(_connectionGeneration);
          _selectedMacAddress = null;
          if (_autoConnectState ==
                  TuiApplicationAutoConnectState.missingAuthKey ||
              _autoConnectState == TuiApplicationAutoConnectState.connecting ||
              _autoConnectState == TuiApplicationAutoConnectState.ready) {
            _autoConnectState = TuiApplicationAutoConnectState.noSavedDevice;
          }
        }
        try {
          if (shouldDisconnect) {
            try {
              await _backend.disconnect();
            } on Object {
              // Attempt ownership is already retired. Device removal must not
              // resurrect it merely because best-effort teardown failed.
              _notice = '已退休当前连接；Bluetooth 断开将在后端继续收敛。';
            }
          }
          await _savedDeviceRepository.removeByMacAddress(normalized);
          try {
            await _credentialStore.removeAuthKey(normalized);
          } on Object {
            // The device record is already gone. Do not restore it just because
            // Keychain cleanup is unavailable; avoid exposing key diagnostics.
            _notice = '已取消保存；系统密钥清理将在下次可用时重试。';
          }
          try {
            await _bindingMaterialStore.removeBindingMaterial(normalized);
          } on Object {
            _notice = '已取消保存；系统 binding material 清理将在下次可用时重试。';
          }
          _savedDevices.remove(normalized);
          _savedAuthKeys.remove(normalized);
          if (removingCurrentAttempt) {
            _connectionFailed = false;
          }
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
        final pendingTarget = _awaitingAuthTarget;
        if (normalized == null ||
            pendingTarget == null ||
            normalized != pendingTarget.macAddress ||
            pendingTarget.generation != _connectionGeneration ||
            _connectionTarget != pendingTarget) {
          return _failure('not_waiting_for_authkey', '请先对该设备发起连接，再输入 authkey。');
        }
        String key;
        try {
          key = normalizeTuiAuthKey(authKey);
        } on FormatException {
          return _failure('invalid_input', 'authkey 必须是 32 位十六进制字符。');
        }
        final generation = _connectionGeneration;
        final target = pendingTarget;
        // This transition must precede every await. Both the binding-material
        // lookup and setAuthKey can synchronously publish a stale
        // awaiting-auth snapshot; the application has already accepted this
        // key and must remain in the connecting state for this generation.
        _awaitingAuthTarget = null;
        _credentialSubmissionGeneration = generation;
        _pendingAuthKey = key;
        _volatileAuthenticatedKey = key;
        _volatileAuthenticatedMacAddress = normalized;
        _notice = 'authkey 已提交，正在使用所选 Classic MAC 建立蓝牙连接。';
        _clearError();
        _emit();
        try {
          final bindingResult = await _readBindingMaterial(normalized);
          if (generation != _connectionGeneration || _disposed) {
            return const TuiApplicationActionResult.failure(
              'superseded',
              '连接请求已被新的操作取代。',
            );
          }
          final bindingMaterial = bindingResult.material;
          if (bindingResult.message != null) {
            // Missing binding is non-fatal at this layer: transport probing
            // must still reach Classic identity/SDP/RFCOMM.
            _notice = bindingResult.message;
          }
          await _backend.provideAuthKey(key);
          if (generation != _connectionGeneration || _disposed) {
            return const TuiApplicationActionResult.failure(
              'superseded',
              '连接请求已被新的操作取代。',
            );
          }
          _connectIssuedGeneration = generation;
          await _backend.connectByAddress(
            address: normalized,
            name: target.name,
            profile: target.profile,
            directedExactAddress: target.directedExactAddress,
            attemptGeneration: generation,
            bindingMaterial: bindingMaterial,
          );
          if (generation != _connectionGeneration || _disposed) {
            return const TuiApplicationActionResult.failure(
              'superseded',
              '连接请求已被新的操作取代。',
            );
          }
          if (_credentialSubmissionGeneration == generation) {
            _credentialSubmissionGeneration = null;
          }
          _notice = bindingResult.message == null
              ? 'authkey 已提交，正在建立蓝牙连接；认证及身份确认成功后会安全保存。'
              : 'authkey 已提交，正在建立蓝牙连接；${bindingResult.message}';
          _clearError();
          _emit();
          return const TuiApplicationActionResult.success('已提交 authkey。');
        } on Object catch (error) {
          _retireCurrentAttempt(generation);
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
        if (!_isCurrentBackendTargetReady()) {
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

  /// Loads explicit WearAuthV2 material for exactly one normalized Classic
  /// address. Missing material is non-fatal: the protocol uses Xiaomi's
  /// official nonce-only Classic f=26 branch. Values are never synthesized.
  Future<_BindingMaterialReadResult> _readBindingMaterial(
    String macAddress,
  ) async {
    try {
      final stored =
          await _bindingMaterialStore.readBindingMaterial(macAddress);
      if (stored == null) {
        return const _BindingMaterialReadResult.unavailable(
          'binding_material_missing',
          '该设备没有已保存的 Xiaomi binding material；将使用官方无材料鉴权分支。',
        );
      }
      return _BindingMaterialReadResult.success(
        TuiBackendBindingMaterial(
          appDeviceId: stored.appDeviceId,
          oob: stored.oob,
        ),
      );
    } on Object {
      // Keychain and serialization failures must not expose the stored
      // appDeviceId/OOB through a user-facing error or diagnostic message.
      return const _BindingMaterialReadResult.unavailable(
        'binding_material_read_failed',
        '读取 Xiaomi binding material 失败；将使用官方无材料鉴权分支。',
      );
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
      intent: TuiApplicationConnectionIntent.strict,
      includeDirectedSessionTarget: false,
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
    final active = _normalizeMacOrNull(value.activeDeviceAddress ?? '');
    var belongsToCurrentAttempt =
        _snapshotBelongsToCurrentAttempt(value, active);
    // f=27 can intentionally close the first RFCOMM channel and let the
    // protocol backend obtain a fresh physical tuple.  Keep that recovery
    // inside the same application attempt, but rebind all native tuple
    // fields before admitting any subsequent snapshot.  A retired tuple
    // (same id/generation) is never eligible for this path.
    if (!belongsToCurrentAttempt && _canRebindPhysicalTuple(value, active)) {
      _rebindPhysicalTuple(value);
      belongsToCurrentAttempt = true;
    }
    // Discovery snapshots are global helper observations, not ownership
    // claims for the retired RFCOMM tuple.  After a failed/removed attempt the
    // target is intentionally retained as a tombstone so late ready/data
    // events stay fenced; allow fresh scan/device updates through without
    // replacing the current connection/failure fields.
    if (!belongsToCurrentAttempt &&
        _isUnscopedDiscoverySnapshot(value, active)) {
      if (_connectionTarget == null) {
        // No retired attempt owns the connection anymore; a normal helper
        // disconnect/scan snapshot is authoritative in full.
        _backendSnapshot = value;
      } else {
        _mergeDiscoverySnapshot(value);
      }
      _emit();
      return;
    }
    // Once a connection attempt has a physical tuple, reject every late
    // snapshot from another connection even when the MAC is identical.
    if (_connectionTarget != null && !belongsToCurrentAttempt) return;
    _backendSnapshot = value;
    if (belongsToCurrentAttempt) {
      _attemptBackendGeneration ??= value.connectionGeneration;
      _attemptConnectionId ??= value.connectionId;
      _attemptIdentityCandidateId ??= value.identityCandidateId;
      _attemptIdentityGeneration ??= value.identityGeneration;
    }
    if (active != null && belongsToCurrentAttempt) {
      _activeMacAddress = active;
    }
    if (belongsToCurrentAttempt && value.failureCode != null) {
      final failedGeneration = _connectionGeneration;
      _retireCurrentAttempt(failedGeneration);
      _scheduleBestEffortDisconnect(failedGeneration);
      _error = _safe(value.message ?? 'macOS Bluetooth 后端操作失败。');
      if (_autoConnectState == TuiApplicationAutoConnectState.connecting) {
        _autoConnectState = TuiApplicationAutoConnectState.failed;
      }
      // A failure-bearing snapshot is terminal even if it also carries stale
      // ready/authenticated fields. Never fall through into confirmation or
      // persistence for the retired tuple.
      _emit();
      return;
    }
    if (belongsToCurrentAttempt &&
        value.connection == TuiBackendConnectionState.disconnected) {
      // Connection state is authoritative even when a native adapter retains
      // the previous address in a final disconnected snapshot.  A correlated
      // close is terminal: do not admit a later ready from this same tuple.
      final disconnectedGeneration = _connectionGeneration;
      _retireCurrentAttempt(disconnectedGeneration);
      _error = _safe(value.message ?? '经典蓝牙连接已断开。');
      if (_autoConnectState == TuiApplicationAutoConnectState.connecting) {
        _autoConnectState = TuiApplicationAutoConnectState.failed;
      }
      _emit();
      return;
    }
    if (belongsToCurrentAttempt &&
        value.protocolAuthenticated &&
        value.connection != TuiBackendConnectionState.ready &&
        value.connectionId != null &&
        value.identityCandidateId != null &&
        value.identityGeneration != null) {
      _scheduleIdentityConfirmation(_connectionGeneration);
    }
    if (value.connection == TuiBackendConnectionState.ready &&
        value.identityState == TuiBackendIdentityState.confirmed &&
        active != null &&
        belongsToCurrentAttempt) {
      // The adapter may already have completed identity.confirm before the
      // application observes the ready snapshot. Record the exact confirmed
      // native tuple so persistence/install cannot accept a later same-MAC
      // connection.
      _confirmedConnectionId = value.connectionId;
      _confirmedIdentityGeneration = value.identityGeneration;
      _connectionFailed = false;
      if (_autoConnectState == TuiApplicationAutoConnectState.connecting) {
        _autoConnectState = TuiApplicationAutoConnectState.ready;
      }
      _scheduleReadyPersistence(active, _connectionGeneration);
    }
    _emit();
  }

  void _scheduleIdentityConfirmation(int generation) {
    if (_disposed || !_identityConfirmationGenerations.add(generation)) return;
    final work = _actionTail.then<void>((_) async {
      try {
        if (generation != _connectionGeneration || _disposed) return;
        await _backend.confirmActiveIdentity(attemptGeneration: generation);
      } on Object catch (error) {
        if (generation == _connectionGeneration && !_disposed) {
          // A protocol-ready session without a confirmed Classic identity is
          // not usable by the application. Tear it down before exposing the
          // failure so no half-open backend session can be persisted later.
          try {
            await _backend.disconnect();
          } on Object {
            // Preserve the identity-confirmation failure as the primary
            // diagnostic; the backend owns its own disconnect error detail.
          }
          if (generation == _connectionGeneration && !_disposed) {
            _connectionGeneration++;
            _activeMacAddress = null;
            _connectIssuedGeneration = null;
            _connectionTarget = null;
            _pendingAuthKey = null;
            _volatileAuthenticatedKey = null;
            _volatileAuthenticatedMacAddress = null;
          }
          _connectionFailed = true;
          _error = '设备协议认证成功，但 Classic identity 确认失败：${_safe(error)}';
          _emit();
        }
      } finally {
        _identityConfirmationGenerations.remove(generation);
      }
    });
    _actionTail = work.catchError((Object _) {});
  }

  bool _snapshotBelongsToCurrentAttempt(
    TuiBackendSnapshot value,
    String? activeAddress,
  ) {
    final target = _connectionTarget;
    if (target == null || target.generation != _connectionGeneration) {
      return false;
    }
    final applicationGeneration = value.applicationAttemptGeneration;
    if (applicationGeneration != null &&
        applicationGeneration != _connectionGeneration) {
      return false;
    }
    // Authkey loading is intentionally performed before connectByAddress.
    // Backends may publish that operation while still carrying a retired
    // connection tuple; never let such a snapshot seed the new attempt's
    // native generation, connection id, or identity candidate. The tuple is
    // admitted only after this attempt's connect command has been issued.
    if (_connectIssuedGeneration != _connectionGeneration) return false;
    // A native close can clear its connection id/generation before the adapter
    // publishes the final disconnected snapshot. While this application
    // attempt is still live, a non-scanning disconnected observation with no
    // active address is therefore correlated to the current attempt rather
    // than treated as a global discovery update.
    if (value.connection == TuiBackendConnectionState.disconnected &&
        activeAddress == null &&
        !value.scanning &&
        !value.transportConnected &&
        value.connectionId == null &&
        value.connectionGeneration == null &&
        value.failureCode == null) {
      // connectByAddress publishes a clean disconnected snapshot before
      // identity resolution. It is preparation, not a physical close. A
      // tupleless disconnected event becomes terminal only after this
      // application attempt has observed a physical/native tuple.
      return _hasObservedPhysicalAttemptTuple;
    }
    final backendGeneration = value.connectionGeneration;
    if (_attemptBackendGeneration != null &&
        backendGeneration != _attemptBackendGeneration) {
      return false;
    }
    if (activeAddress != null && activeAddress != target.macAddress) {
      return false;
    }
    final attemptConnectionId = _attemptConnectionId;
    final attemptCandidate = _attemptIdentityCandidateId;
    final attemptIdentityGeneration = _attemptIdentityGeneration;
    if (attemptConnectionId != null &&
        value.connectionId != attemptConnectionId) return false;
    if (attemptCandidate != null &&
        value.identityCandidateId != attemptCandidate) return false;
    // identity.confirm advances the identity generation. Before confirmation
    // keep the resolved generation fixed; a confirmed ready snapshot may
    // advance it once, after which the confirmed tuple is immutable.
    if (_confirmedIdentityGeneration != null) {
      if (value.identityGeneration != _confirmedIdentityGeneration) {
        return false;
      }
    } else if (value.identityState != TuiBackendIdentityState.confirmed &&
        attemptIdentityGeneration != null &&
        value.identityGeneration != attemptIdentityGeneration) {
      return false;
    }
    if (value.connection == TuiBackendConnectionState.ready &&
        (value.connectionId == null ||
            value.identityCandidateId == null ||
            value.identityGeneration == null ||
            !value.protocolAuthenticated ||
            value.identityState != TuiBackendIdentityState.confirmed)) {
      return false;
    }
    // Before connectByAddress, null-address backend events are unrelated to
    // the pending target. Once connect has been issued, matching-address
    // connecting/authenticating/ready snapshots are all valid observations.
    if (activeAddress != null) {
      return _connectIssuedGeneration == _connectionGeneration;
    }
    return _connectIssuedGeneration == _connectionGeneration &&
        (value.failureCode != null ||
            (value.connection == TuiBackendConnectionState.disconnected &&
                _hasObservedPhysicalAttemptTuple));
  }

  bool _canRebindPhysicalTuple(
    TuiBackendSnapshot value,
    String? activeAddress,
  ) {
    final target = _connectionTarget;
    if (target == null ||
        target.generation != _connectionGeneration ||
        _connectIssuedGeneration != _connectionGeneration ||
        activeAddress != target.macAddress ||
        value.applicationAttemptGeneration != _connectionGeneration ||
        value.connectionId == null ||
        value.connectionGeneration == null ||
        value.failureCode != null ||
        value.connection == TuiBackendConnectionState.disconnected) {
      return false;
    }
    final oldConnectionId = _attemptConnectionId;
    final oldGeneration = _attemptBackendGeneration;
    final expectedCandidate = _attemptIdentityCandidateId;
    // identity.confirm can advance the generation on the first RFCOMM tuple.
    // A post-auth physical reconnect must retain that confirmed identity
    // binding; it may not silently adopt another same-MAC candidate.
    final expectedIdentityGeneration =
        _confirmedIdentityGeneration ?? _attemptIdentityGeneration;
    if (oldConnectionId == null ||
        oldGeneration == null ||
        expectedCandidate == null ||
        expectedIdentityGeneration == null ||
        value.identityCandidateId != expectedCandidate ||
        value.identityGeneration != expectedIdentityGeneration) {
      return false;
    }
    // Native generations are monotonic.  Requiring both identity fields to
    // change prevents a late event from the retired RFCOMM tuple reopening
    // the application state, even when its MAC is identical.
    return value.connectionId != oldConnectionId &&
        value.connectionGeneration! > oldGeneration;
  }

  void _rebindPhysicalTuple(TuiBackendSnapshot value) {
    _attemptBackendGeneration = value.connectionGeneration;
    _attemptConnectionId = value.connectionId;
    _attemptIdentityCandidateId = value.identityCandidateId;
    _attemptIdentityGeneration = value.identityGeneration;
    _confirmedConnectionId = null;
    _confirmedIdentityGeneration = null;
    _connectionFailed = false;
  }

  void _scheduleReadyPersistence(String macAddress, int generation) {
    if (_disposed || !_readyPersistenceGenerations.add(generation)) return;
    final work = _actionTail.then<void>(
      (_) => _persistReadyConnection(macAddress, generation),
      onError: (_) => _persistReadyConnection(macAddress, generation),
    );
    _actionTail = work.catchError((Object _) {});
  }

  bool _isUnscopedDiscoverySnapshot(
    TuiBackendSnapshot value,
    String? activeAddress,
  ) =>
      !_hasLiveConnectionAttempt &&
      activeAddress == null &&
      !value.transportConnected &&
      value.connection == TuiBackendConnectionState.disconnected &&
      value.connectionId == null &&
      value.connectionGeneration == null &&
      value.failureCode == null &&
      !value.protocolAuthenticated;

  void _mergeDiscoverySnapshot(TuiBackendSnapshot value) {
    final current = _backendSnapshot;
    _backendSnapshot = TuiBackendSnapshot(
      revision: value.revision,
      helperState: value.helperState,
      scanning: value.scanning,
      transportConnected: current.transportConnected,
      connection: current.connection,
      devices: value.devices,
      authKeyLoaded: current.authKeyLoaded,
      activeDeviceAddress: current.activeDeviceAddress,
      identityCandidateId: current.identityCandidateId,
      identityState: current.identityState,
      identityGeneration: current.identityGeneration,
      connectionId: current.connectionId,
      connectionGeneration: current.connectionGeneration,
      applicationAttemptGeneration: current.applicationAttemptGeneration,
      protocolAuthenticated: current.protocolAuthenticated,
      message: current.message,
      failureCode: current.failureCode,
      installation: current.installation,
    );
  }

  void _scheduleBestEffortDisconnect(int generation) {
    if (_disposed || !_bestEffortDisconnectGenerations.add(generation)) return;
    unawaited(() async {
      try {
        await _backend.disconnect();
      } on Object {
        // The terminal failure remains the primary visible diagnosis. Native
        // teardown errors are recorded by the standalone backend journal.
      } finally {
        _bestEffortDisconnectGenerations.remove(generation);
      }
    }());
  }

  void _onBackendError(Object error, [StackTrace? stackTrace]) {
    if (_disposed) return;
    // The stream error carries no MAC, application generation, or native
    // connection tuple.  It is therefore never safe to mutate idle, scan, or
    // selected state here.  The backend/native layer records the detailed
    // diagnostic in the shared journal; correlated failures arrive as fenced
    // snapshots and are handled by [_onBackendSnapshot].
    return;
  }

  Future<void> _persistReadyConnection(
      String macAddress, int generation) async {
    if (_disposed) {
      _readyPersistenceGenerations.remove(generation);
      return;
    }
    try {
      if (macAddress != _activeMacAddress ||
          generation != _connectionGeneration) {
        return;
      }
      final target = _connectionTarget;
      if (target?.macAddress != macAddress ||
          target?.generation != generation ||
          !_isCurrentConnection(macAddress, generation)) {
        return;
      }
      // This exact connection attempt used process-local directed authority.
      // Reaching ready must not update existing saved history or persist the
      // supplied authkey, even when a record already has the same MAC. Those
      // writes remain available only through the user's explicit save action.
      if (target?.isTransientDirectedTarget == true) {
        _pendingAuthKey = null;
        _notice = '设备已完成认证并进入就绪状态。';
        _clearError();
        return;
      }
      final now = DateTime.now().toUtc();
      final saved = _savedDevices[macAddress];
      final record = saved?.copyWith(lastConnectedAt: now) ??
          SavedTuiDevice(
            displayName: target!.name,
            macAddress: macAddress,
            isSupported: target.supported,
            profileId: target.profile?.family.name,
            lastConnectedAt: now,
          );
      await _savedDeviceRepository.save(record);
      // A user can cancel saving or begin a new connection while persistence
      // is in flight. Never resurrect removed history in the memory view.
      if (_isCurrentConnection(macAddress, generation) &&
          (saved == null || identical(_savedDevices[macAddress], saved))) {
        _savedDevices[macAddress] = record;
      }
      if (!_isCurrentConnection(macAddress, generation)) return;
      if (target?.macAddress == macAddress &&
          target?.generation == generation &&
          _pendingAuthKey != null) {
        final key = _pendingAuthKey!;
        _pendingAuthKey = null;
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
        !_isCurrentReadyTarget(macAddress)) {
      return;
    }
    final key = _volatileAuthenticatedKey!;
    await _credentialStore.saveAuthKey(macAddress, key);
    _savedAuthKeys[macAddress] = key;
  }

  bool _isCurrentReadyTarget(String macAddress) {
    final target = _connectionTarget;
    return target != null &&
        target.macAddress == macAddress &&
        target.generation == _connectionGeneration &&
        _isCurrentConnection(macAddress, _connectionGeneration);
  }

  bool _isCurrentConnection(String macAddress, int generation) =>
      !_disposed &&
      generation == _connectionGeneration &&
      macAddress == _activeMacAddress &&
      _connectionTarget?.macAddress == macAddress &&
      _connectionTarget?.generation == generation &&
      _attemptBackendGeneration != null &&
      _backendSnapshot.connectionGeneration == _attemptBackendGeneration &&
      _attemptConnectionId != null &&
      _backendSnapshot.connectionId == _attemptConnectionId &&
      _attemptIdentityCandidateId != null &&
      _backendSnapshot.identityCandidateId == _attemptIdentityCandidateId &&
      _confirmedConnectionId == _backendSnapshot.connectionId &&
      _confirmedIdentityGeneration != null &&
      _confirmedIdentityGeneration == _backendSnapshot.identityGeneration &&
      _backendSnapshot.protocolAuthenticated &&
      _backendSnapshot.identityState == TuiBackendIdentityState.confirmed &&
      _backendSnapshot.connection == TuiBackendConnectionState.ready;

  _TargetDevice? _resolveTarget(
    String macAddress, {
    bool includeDirectedSessionTarget = true,
  }) {
    final directedTarget = _directedClassicTarget;
    if (includeDirectedSessionTarget &&
        directedTarget?.macAddress == macAddress) {
      return _targetFromDirectedClassicTarget(directedTarget!);
    }
    final saved = _savedDevices[macAddress];
    final backendDevice = _liveBackendDeviceForMac(macAddress);
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

  TuiBackendDevice? _liveBackendDeviceForMac(String macAddress) {
    for (final device in _backendSnapshot.devices) {
      if (_normalizeMacOrNull(device.address) == macAddress) return device;
    }
    return null;
  }

  _TargetDevice _targetFromDirectedClassicTarget(
    TuiDirectedClassicTarget target,
  ) =>
      _TargetDevice(
        name: target.displayName,
        profile: target.profile,
        supported: target.profile.generation == ProtocolGeneration.v2Vela,
      );

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
    final directedTarget = _directedClassicTarget;
    final allAddresses = <String>{..._savedDevices.keys, ...liveByMac.keys};
    if (directedTarget != null) allAddresses.add(directedTarget.macAddress);
    // A backend snapshot is not sufficient proof of readiness: a late event
    // from another device/generation must never mark this target connected.
    final readyMac = _isCurrentBackendTargetReady() ? _activeMacAddress : null;
    final devices = allAddresses.map((macAddress) {
      final saved = _savedDevices[macAddress];
      final live = liveByMac[macAddress];
      final isDirectedSessionTarget = directedTarget?.macAddress == macAddress;
      final profile = isDirectedSessionTarget
          ? directedTarget!.profile
          : _profileFromId(saved?.profileId) ??
              live?.profile ??
              DeviceProfile.matchAdvertisementName(saved?.displayName ?? '');
      final support = isDirectedSessionTarget
          ? (profile!.generation == ProtocolGeneration.v2Vela
              ? TuiApplicationDeviceSupport.supported
              : TuiApplicationDeviceSupport.unsupported)
          : saved != null
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
        name: isDirectedSessionTarget
            ? directedTarget!.displayName
            : saved?.displayName ?? live?.name ?? macAddress,
        macAddress: macAddress,
        support: support,
        saved: saved != null,
        savedAuthKey: saved == null ? null : _savedAuthKeys[macAddress],
        profileId: profile?.family.name,
        profileName: profile?.displayName,
        paired: live?.paired ?? false,
        rssi: live?.rssi,
        connected: readyMac == macAddress,
        isDirectedSessionTarget: isDirectedSessionTarget,
      );
    }).toList()
      ..sort((left, right) {
        if (left.isDirectedSessionTarget != right.isDirectedSessionTarget) {
          return left.isDirectedSessionTarget ? -1 : 1;
        }
        if (left.saved != right.saved) return left.saved ? -1 : 1;
        final byName =
            left.name.toLowerCase().compareTo(right.name.toLowerCase());
        return byName != 0
            ? byName
            : left.macAddress.compareTo(right.macAddress);
      });
    final installation = _installationStatus(_backendSnapshot.installation);
    return TuiApplicationSnapshot(
      revision: _revision,
      devices: devices,
      connection: _connectionState(),
      activeDeviceId: _activeMacAddress,
      selectedDeviceId: _selectedMacAddress,
      pendingAuthDeviceId: _awaitingAuthTarget?.macAddress,
      connectionGeneration: _connectionGeneration,
      scanning: _backendSnapshot.scanning,
      autoConnectEnabled: _preferences.autoConnectLastDevice,
      autoConnectState: _autoConnectState,
      themeId: _preferences.themeId,
      installation: installation,
      notice: _safeNullable(_notice),
      error: _safeNullable(_error),
    );
  }

  TuiApplicationConnectionState _connectionState() {
    if (_disconnecting) return TuiApplicationConnectionState.disconnecting;
    if (_credentialSubmissionGeneration == _connectionGeneration) {
      return TuiApplicationConnectionState.connecting;
    }
    if (_awaitingAuthTarget != null &&
        _awaitingAuthTarget?.macAddress == _activeMacAddress &&
        _awaitingAuthTarget?.generation == _connectionGeneration) {
      return TuiApplicationConnectionState.waitingAuthkey;
    }
    if (_connectionFailed) {
      return TuiApplicationConnectionState.failed;
    }
    final target = _connectionTarget;
    if (target != null && target.generation != _connectionGeneration) {
      return _selectedMacAddress != null
          ? TuiApplicationConnectionState.selected
          : _backendSnapshot.scanning
              ? TuiApplicationConnectionState.scanning
              : TuiApplicationConnectionState.idle;
    }
    if (_isCurrentBackendTargetReady() &&
        _isInstalling(_backendSnapshot.installation)) {
      return TuiApplicationConnectionState.installing;
    }
    final active =
        _normalizeMacOrNull(_backendSnapshot.activeDeviceAddress ?? '');
    if (target != null &&
        target.generation == _connectionGeneration &&
        active != null &&
        active != target.macAddress) {
      // The native stream delivered an event for a different device. Keep the
      // current attempt visible as in-flight instead of exposing stale ready.
      return TuiApplicationConnectionState.connecting;
    }
    return switch (_backendSnapshot.connection) {
      TuiBackendConnectionState.disconnected =>
        _backendSnapshot.transportConnected
            ? TuiApplicationConnectionState.connected
            : _backendSnapshot.scanning
                ? TuiApplicationConnectionState.scanning
                : _selectedMacAddress != null
                    ? TuiApplicationConnectionState.selected
                    : TuiApplicationConnectionState.idle,
      TuiBackendConnectionState.connecting =>
        _backendSnapshot.transportConnected
            ? TuiApplicationConnectionState.connected
            : TuiApplicationConnectionState.connecting,
      TuiBackendConnectionState.awaitingAuthKey =>
        _connectIssuedGeneration == _connectionGeneration
            ? TuiApplicationConnectionState.connecting
            : TuiApplicationConnectionState.waitingAuthkey,
      TuiBackendConnectionState.authenticating =>
        TuiApplicationConnectionState.authenticating,
      TuiBackendConnectionState.ready => _isCurrentBackendTargetReady()
          ? TuiApplicationConnectionState.ready
          : TuiApplicationConnectionState.authenticating,
    };
  }

  bool _isCurrentBackendTargetReady() {
    final target = _connectionTarget;
    final active =
        _normalizeMacOrNull(_backendSnapshot.activeDeviceAddress ?? '');
    return target != null &&
        target.generation == _connectionGeneration &&
        active == target.macAddress &&
        _attemptBackendGeneration != null &&
        _backendSnapshot.connectionGeneration == _attemptBackendGeneration &&
        _attemptConnectionId != null &&
        _backendSnapshot.connectionId == _attemptConnectionId &&
        _attemptIdentityCandidateId != null &&
        _backendSnapshot.identityCandidateId == _attemptIdentityCandidateId &&
        _confirmedConnectionId == _backendSnapshot.connectionId &&
        _confirmedIdentityGeneration != null &&
        _confirmedIdentityGeneration == _backendSnapshot.identityGeneration &&
        _backendSnapshot.identityState == TuiBackendIdentityState.confirmed &&
        _backendSnapshot.protocolAuthenticated &&
        _backendSnapshot.connection == TuiBackendConnectionState.ready;
  }

  bool _isInstalling(TuiBackendInstallation? installation) =>
      installation != null &&
      switch (installation.state) {
        TuiBackendInstallState.validating ||
        TuiBackendInstallState.waitingForProtocol ||
        TuiBackendInstallState.transferring ||
        TuiBackendInstallState.awaitingDevice =>
          true,
        TuiBackendInstallState.idle ||
        TuiBackendInstallState.succeeded ||
        TuiBackendInstallState.cancelled ||
        TuiBackendInstallState.stateUnknown ||
        TuiBackendInstallState.failed =>
          false,
      };

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
    _awaitingAuthTarget = null;
    _connectionTarget = null;
    _connectIssuedGeneration = null;
    _credentialSubmissionGeneration = null;
    _clearAttemptTuple();
  }

  /// Retires a failed attempt before its backend can publish another state.
  ///
  /// Keep the old immutable target in place while advancing the application
  /// generation.  That makes subsequent snapshots from the failed tuple fail
  /// the target-generation ownership test, rather than treating them as a
  /// targetless backend observation.
  void _retireCurrentAttempt(int generation) {
    final target = _connectionTarget;
    if (generation != _connectionGeneration ||
        target == null ||
        target.generation != generation) {
      return;
    }
    _connectionGeneration++;
    _connectionFailed = true;
    _activeMacAddress = null;
    _awaitingAuthTarget = null;
    _pendingAuthKey = null;
    _volatileAuthenticatedKey = null;
    _volatileAuthenticatedMacAddress = null;
    _connectIssuedGeneration = null;
    _credentialSubmissionGeneration = null;
    _clearAttemptTuple();
  }

  bool get _hasLiveConnectionAttempt {
    final target = _connectionTarget;
    return target != null &&
        target.generation == _connectionGeneration &&
        _connectIssuedGeneration == _connectionGeneration;
  }

  bool get _hasObservedPhysicalAttemptTuple =>
      _attemptBackendGeneration != null ||
      _attemptConnectionId != null ||
      _attemptIdentityCandidateId != null ||
      _attemptIdentityGeneration != null;

  void _clearAttemptTuple() {
    _attemptBackendGeneration = null;
    _attemptConnectionId = null;
    _attemptIdentityCandidateId = null;
    _attemptIdentityGeneration = null;
    _confirmedConnectionId = null;
    _confirmedIdentityGeneration = null;
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
    this.macAddress,
    this.generation,
    this.directedExactAddress = false,
    this.isTransientDirectedTarget = false,
  });

  final String name;
  final DeviceProfile? profile;
  final bool supported;
  final String? macAddress;
  final int? generation;
  final bool directedExactAddress;
  final bool isTransientDirectedTarget;

  _TargetDevice copyWith({
    String? macAddress,
    int? generation,
    bool? directedExactAddress,
    bool? isTransientDirectedTarget,
  }) =>
      _TargetDevice(
        name: name,
        profile: profile,
        supported: supported,
        macAddress: macAddress ?? this.macAddress,
        generation: generation ?? this.generation,
        directedExactAddress: directedExactAddress ?? this.directedExactAddress,
        isTransientDirectedTarget:
            isTransientDirectedTarget ?? this.isTransientDirectedTarget,
      );
}

final class _BindingMaterialReadResult {
  const _BindingMaterialReadResult.success(this.material)
      : code = null,
        message = null;

  const _BindingMaterialReadResult.unavailable(this.code, this.message)
      : material = null;

  final TuiBackendBindingMaterial? material;
  final String? code;
  final String? message;
}
