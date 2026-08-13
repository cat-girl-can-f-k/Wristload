library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../backend/backend_snapshot.dart';
import '../backend/wristload_backend.dart';
import '../domain/device_profile.dart';
import '../domain/install_checkpoint_store.dart';
import '../domain/install_models.dart';
import '../domain/install_task.dart';
import '../domain/queue_file_importer.dart';
import '../domain/protocol/spp_sequence_allocator.dart';
import '../domain/transfer_settings_store.dart';
import '../transport/json_line_mac_bluetooth_transport.dart';
import '../transport/mac_bluetooth_transport.dart';
import '../frontend/port/tui_frontend_port.dart';
import '../frontend/port/tui_action_result.dart';
import '../frontend/port/tui_snapshot.dart';

/// Production boundary consumed by the terminal UI. Backend and native helper
/// objects never escape this class.
final class TuiFacade implements TuiFrontendPort {
  factory TuiFacade.macos({
    String? helperPath,
    InstallCheckpointStore? checkpointStore,
    TransferSettingsStore? settingsStore,
  }) {
    final path = helperPath ?? 'macos_bridge/build/wearable_macos_bridge';
    final transport = JsonLineMacBluetoothTransport(executablePath: path);
    final checkpoint = checkpointStore ?? InstallCheckpointStore();
    final settings = settingsStore ?? TransferSettingsStore();
    return TuiFacade._(
      transport: transport,
      backend: WristloadBackend(
        transport: transport,
        checkpointStore: checkpoint,
        settingsStore: settings,
      ),
      checkpointStore: checkpoint,
    );
  }

  TuiFacade._({
    required MacBluetoothTransport transport,
    required WristloadBackend backend,
    required InstallCheckpointStore checkpointStore,
  })  : _transport = transport,
        _backend = backend,
        _checkpointStore = checkpointStore {
    _transportSnapshot = _transport.snapshot;
    _backendSnapshot = _backend.snapshot;
    _ingestBackendLogs(_backendSnapshot.logs);
    _emit();
    _transportSub = _transport.snapshots.listen((value) {
      _recordTransportTransition(_transportSnapshot, value);
      _transportSnapshot = value;
      if (!value.scanning) {
        _scanning = false;
        _scanEndsAt = null;
      }
      _emit();
    }, onError: (Object error, StackTrace stack) {
      _recordSafeLog('error', error);
      _emit();
    });
    _discoverySub = _transport.discoveries.listen((device) {
      _mergeDevice(device);
      _appendLog(
        TuiLogLevel.info,
        TuiLogCategory.discovery,
        '发现设备：${device.name.isEmpty ? device.address : device.name}',
        eventCode: 'discovery.device.observed',
      );
      _emit();
    }, onError: (Object error, StackTrace stack) {
      _recordSafeLog('error', error);
      _emit();
    });
    _backendSub = _backend.snapshots.listen((value) {
      _recordBackendTransition(_backendSnapshot, value);
      _backendSnapshot = value;
      _ingestBackendLogs(value.logs);
      _emit();
    }, onError: (Object error, StackTrace stack) {
      _recordSafeLog('error', error);
      _emit();
    });
    _errorSub = _transport.errors.listen((error) {
      _recordSafeLog('error', error);
      _emit();
    });
  }

  final MacBluetoothTransport _transport;
  final WristloadBackend _backend;
  final InstallCheckpointStore _checkpointStore;
  final Map<String, MacBluetoothDevice> _devices = {};
  final Map<String, Set<TuiDeviceSource>> _deviceSources = {};
  final Map<String, DeviceProfile?> _profiles = {};
  final Map<QueueEntry, String> _queueIds = {};
  final Map<String, QueueEntry> _queueById = {};
  final List<TuiLogEntry> _logs = [];
  final Map<String, TuiPendingDecision> _decisions = {};
  final Map<String, String> _decisionItemIds = {};
  final Map<String, String> _decisionTokens = {};
  final Set<String> _declinedDecisionTokens = {};
  final StreamController<TuiSnapshot> _snapshotController =
      StreamController<TuiSnapshot>.broadcast(sync: true);

  late MacBluetoothTransportSnapshot _transportSnapshot;
  late BackendSnapshot _backendSnapshot;
  StreamSubscription<MacBluetoothTransportSnapshot>? _transportSub;
  StreamSubscription<MacBluetoothDevice>? _discoverySub;
  StreamSubscription<BackendSnapshot>? _backendSub;
  StreamSubscription<Object>? _errorSub;
  TuiSnapshot? _snapshot;
  TuiRecoveryInfo _recovery =
      const TuiRecoveryInfo(state: TuiRecoveryState.unchecked);
  TuiNotice? _notice;
  int _revision = 0;
  int _operationCounter = 0;
  final List<String> _backendLogLines = [];
  int _queueIdCounter = 0;
  bool _initialized = false;
  bool _disposed = false;
  bool _scanning = false;
  DateTime? _scanEndsAt;
  Future<void>? _queueFuture;

  @override
  TuiSnapshot get snapshot => _snapshot ?? _makeSnapshot();

  @override
  Stream<TuiSnapshot> get snapshots async* {
    yield snapshot;
    yield* _snapshotController.stream;
  }

  @override
  Future<TuiActionResult> initialize() async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    if (!Platform.isMacOS) {
      _initialized = true;
      _emit();
      return _failure('unsupported_platform', '仅支持在 macOS 上运行。');
    }
    try {
      _appendLog(TuiLogLevel.info, TuiLogCategory.helper, '启动 macOS Bluetooth helper。', eventCode: 'helper.start');
      await _transport.start();
      _initialized = true;
      final paired = await refreshPairedDevices();
      if (paired.accepted) return _success('macOS Bluetooth helper 已就绪。');
      return TuiActionResult(
        accepted: true,
        code: 'partial',
        message: 'macOS Bluetooth helper 已就绪，但配对设备刷新失败。',
        operationId: _nextOperation(),
      );
    } on Object catch (error) {
      _recordSafeLog('error', error);
      _emit();
      return _failure(_errorCode(error), 'macOS Bluetooth helper 启动失败。');
    }
  }

  @override
  Future<TuiActionResult> refreshPairedDevices() async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    if (!Platform.isMacOS)
      return _failure('unsupported_platform', '仅支持 macOS。');
    try {
      _appendLog(TuiLogLevel.info, TuiLogCategory.discovery, '刷新已配对设备。', eventCode: 'discovery.paired.refresh');
      final devices = await _transport.listPairedDevices();
      for (final device in devices) _mergeDevice(device);
      _emit();
      return _success('已刷新配对设备（${devices.length} 个）。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      _emit();
      return _failure(_errorCode(error), '刷新配对设备失败。');
    }
  }

  @override
  Future<TuiActionResult> startScan(
      {Duration duration = const Duration(seconds: 10)}) async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    if (duration < const Duration(seconds: 1) ||
        duration > const Duration(seconds: 255)) {
      return _failure('invalid_input', '扫描时长必须在 1 到 255 秒之间。');
    }
    try {
      _appendLog(TuiLogLevel.info, TuiLogCategory.discovery, '开始设备扫描。', eventCode: 'discovery.scan.start');
      _scanning = true;
      _scanEndsAt = DateTime.now().add(duration);
      _emit();
      await _transport.startScan(duration: duration);
      return _success('已开始扫描。');
    } on Object catch (error) {
      _scanning = false;
      _scanEndsAt = null;
      _recordSafeLog('error', error);
      _emit();
      return _failure(_errorCode(error), '开始扫描失败。');
    }
  }

  @override
  Future<TuiActionResult> stopScan() async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    try {
      _appendLog(TuiLogLevel.info, TuiLogCategory.discovery, '停止设备扫描。', eventCode: 'discovery.scan.stop');
      await _transport.stopScan();
      _scanning = false;
      _scanEndsAt = null;
      _emit();
      return _success('扫描已停止。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      return _failure(_errorCode(error), '停止扫描失败。');
    }
  }

  @override
  Future<TuiActionResult> addManualDevice({
    required String address,
    required String modelId,
    String? displayName,
  }) async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    final profile = _profileForModel(modelId);
    if (profile == null || profile.generation != ProtocolGeneration.v2Vela) {
      return _failure('unsupported_device', '请选择已支持的 V2 型号。');
    }
    try {
      final device = MacBluetoothDevice(
        address: address,
        name: displayName?.trim().isNotEmpty == true
            ? displayName!.trim()
            : profile.displayName,
        source: MacBluetoothDeviceSource.manual,
      );
      _mergeDevice(device, profile: profile);
      _appendLog(TuiLogLevel.info, TuiLogCategory.discovery, '已添加手动设备。', eventCode: 'discovery.manual.added');
      _emit();
      return _success('已添加手动设备（型号来源为用户选择，未由设备验证）。');
    } on FormatException {
      return _failure('invalid_input', '经典蓝牙地址格式无效。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      return _failure('invalid_input', '手动设备地址无效。');
    }
  }

  @override
  Future<TuiActionResult> connectDevice(String deviceId) async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    final key = deviceId.startsWith('mac:') ? deviceId.substring(4) : '';
    final device = _devices[key];
    if (device == null) return _failure('not_found', '设备不存在或已离开列表。');
    final profile = _profiles[device.addressKey] ??
        DeviceProfile.matchAdvertisementName(device.name);
    if (profile == null || profile.generation != ProtocolGeneration.v2Vela) {
      return _failure('unsupported_device', '该设备不是已验证的 V2 Vela 型号。');
    }
    try {
      _appendLog(TuiLogLevel.info, TuiLogCategory.connection, '请求连接设备。', eventCode: 'connection.connect.started');
      await _backend.connect(device, profile: profile);
      _emit();
      return _success('已连接设备，等待 authkey 鉴权。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      _emit();
      return _failure(_errorCode(error), _safeFailureMessage(error));
    }
  }

  @override
  Future<TuiActionResult> disconnect() async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    try {
      _appendLog(TuiLogLevel.info, TuiLogCategory.connection, '请求断开设备。', eventCode: 'connection.disconnect.started');
      await _backend.disconnect();
      _emit();
      return _success('已断开设备。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      return _failure(_errorCode(error), '断开设备失败。');
    }
  }

  @override
  Future<TuiActionResult> submitAuthKey(String value) async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    if (_backendSnapshot.connection !=
        BackendConnectionState.awaitingAuthKey) {
      return _failure('action_blocked', '当前连接状态不接受 authkey。');
    }
    if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(value)) {
      return _failure('invalid_input', 'authkey 必须为 32 位十六进制字符。');
    }
    try {
      _backend.setAuthKey(value);
      _appendLog(TuiLogLevel.info, TuiLogCategory.authentication, '已接收 authkey 输入。', eventCode: 'authentication.key.accepted');
      _emit();
      return _success('authkey 已提交，仅保留在内存中。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      return _failure('authentication_failure', 'authkey 无效或鉴权启动失败。');
    }
  }

  @override
  Future<TuiActionResult> clearAuthKey() async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    try {
      await _backend.clearAuthKey();
      _appendLog(TuiLogLevel.info, TuiLogCategory.authentication, '已清除 authkey 和会话材料。', eventCode: 'authentication.key.cleared');
      _emit();
      return _success('authkey 与会话材料已清除。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      return _failure(_errorCode(error), '清除 authkey 失败。');
    }
  }

  @override
  Future<TuiActionResult> importFiles(List<String> literalPaths) async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    if (literalPaths.isEmpty) return _failure('invalid_input', '至少选择一个安装文件。');
    try {
      _appendLog(TuiLogLevel.info, TuiLogCategory.filesystem, '开始导入 ${literalPaths.length} 个文件。', eventCode: 'filesystem.import.started');
      final result = await _backend.importFiles(literalPaths);
      _syncQueueIds();
      _rebuildDecisions();
      _appendLog(TuiLogLevel.info, TuiLogCategory.filesystem, '文件导入完成：${result.addedCount} 个已加入队列。', eventCode: 'filesystem.import.completed');
      _emit();
      final suffix =
          result.failures.isEmpty ? '' : '，${result.failures.length} 个文件被拒绝';
      return TuiActionResult(
        accepted: result.addedCount > 0,
        code: result.failures.isEmpty ? 'ok' : 'partial',
        message: '已加入 ${result.addedCount} 个文件$suffix。',
        operationId: _nextOperation(),
      );
    } on Object catch (error) {
      _recordSafeLog('error', error);
      _emit();
      return _failure('file_import_failure', '文件导入失败。');
    }
  }

  @override
  Future<TuiActionResult> resolveDecision(
    String decisionId, {
    required bool accepted,
    Map<String, String> values = const {},
  }) async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    final decision = _decisions[decisionId];
    if (decision == null) return _failure('not_found', '确认项已失效。');
    final itemId = _decisionItemIds[decisionId];
    final token = _decisionTokens[decisionId];
    final item = itemId == null ? null : _queueById[itemId];
    if (item == null ||
        token == null ||
        token != _decisionToken(itemId!, decision.kind, item)) {
      _decisions.remove(decisionId);
      _decisionItemIds.remove(decisionId);
      _decisionTokens.remove(decisionId);
      return _failure('not_found', '确认项已失效，请按当前队列状态重新确认。');
    }
    if (accepted && _declinedDecisionTokens.contains(token)) {
      return _failure('action_blocked', '该确认项已被拒绝；请移除条目或修正文件后再试。');
    }
    if (!accepted) {
      if (!_declinedDecisionTokens.add(token)) {
        return _failure('action_blocked', '该确认项已被拒绝；请移除条目或修正文件后再试。');
      }
      item.message = '用户拒绝确认；请移除条目或修正文件。';
      _emit();
      return _success('已拒绝该确认项，条目仍被安全阻止。');
    }
    try {
      final request = item.request;
      var metadata = request.metadata;
      if (decision.kind == TuiDecisionKind.missingFaceId) {
        final faceId = values['faceId']?.trim();
        if (faceId == null || !RegExp(r'^\d+$').hasMatch(faceId))
          return _failure('invalid_input', 'faceId 必须为数字。');
        metadata = metadata.copyWith(faceId: faceId);
      } else if (decision.kind == TuiDecisionKind.invalidRpkVersionCode) {
        final raw = int.tryParse(values['versionCode'] ?? '');
        if (raw == null || raw <= 0 || raw > maxRpkVersionCode)
          return _failure('invalid_input', 'versionCode 超出允许范围。');
        metadata = metadata.copyWith(versionCode: raw);
      }
      final confirmation = InstallRequest(
        kind: request.kind,
        path: request.path,
        metadata: metadata,
        unsupportedLuaConfirmed: request.unsupportedLuaConfirmed ||
            decision.kind == TuiDecisionKind.redmiWatch5LuaUnsupported,
        watchfaceResolutionConfirmed: request.watchfaceResolutionConfirmed ||
            decision.kind == TuiDecisionKind.watchfaceResolutionMismatch,
      );
      item.request = confirmation;
      _declinedDecisionTokens.remove(token);
      _decisions.remove(decisionId);
      _decisionItemIds.remove(decisionId);
      _decisionTokens.remove(decisionId);
      _rebuildDecisions();
      _emit();
      return _success('已保存确认信息。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      return _failure('invalid_input', '确认信息无效。');
    }
  }

  @override
  Future<TuiActionResult> removeQueueItem(String itemId) async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    final index = _queueIndex(itemId);
    if (index < 0) return _failure('not_found', '队列条目不存在。');
    final ok = _backend.removeQueueEntry(index);
    if (!ok) return _failure('action_blocked', '安装中的条目不能移除。');
    _syncQueueIds();
    _rebuildDecisions();
    _emit();
    return _success('已移除队列条目。');
  }

  @override
  Future<TuiActionResult> moveQueueItem(String itemId, int newIndex) async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    final index = _queueIndex(itemId);
    if (index < 0) return _failure('not_found', '队列条目不存在。');
    if (!_backend.reorderQueue(index, newIndex))
      return _failure('action_blocked', '当前状态不能调整队列。');
    _emit();
    return _success('已调整队列顺序。');
  }

  @override
  Future<TuiActionResult> clearCompletedQueue() async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    _backend.clearCompletedQueue();
    _syncQueueIds();
    _emit();
    return _success('已清理完成条目。');
  }

  @override
  Future<TuiActionResult> startQueue() async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    final blocked = _queueStartBlock();
    if (blocked != null) return _failure('action_blocked', blocked);
    _rebuildDecisions();
    if (_decisions.isNotEmpty)
      return _failure('confirmation_required', '请先处理所有待确认项。');
    final future = _backend.runQueue();
    _appendLog(TuiLogLevel.info, TuiLogCategory.install, '安装队列已启动。', eventCode: 'install.queue.started');
    _queueFuture = future;
    unawaited(future.whenComplete(() {
      if (identical(_queueFuture, future)) _queueFuture = null;
      _emit();
    }));
    _emit();
    return _success('已开始安装队列。');
  }

  @override
  Future<TuiActionResult> retryQueueItem(String itemId) async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    final entry = _queueById[itemId];
    if (entry == null) return _failure('not_found', '队列条目不存在。');
    if (!entry.canRetry) return _failure('action_blocked', '该条目当前不可重试。');
    if (!_backend.sessionReady)
      return _failure('action_blocked', '请先重新连接目标设备。');
    try {
      final future = _backend.retry(entry);
      _queueFuture = future;
      unawaited(future.whenComplete(() {
        if (identical(_queueFuture, future)) _queueFuture = null;
        _emit();
      }));
      _emit();
      return _success('已开始重试。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      return _failure(_errorCode(error), '重试失败。');
    }
  }

  @override
  Future<TuiActionResult> cancelActiveInstall() async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    await _backend.cancelInstall();
    _appendLog(TuiLogLevel.info, TuiLogCategory.install, '已请求取消当前安装。', eventCode: 'install.cancel.requested');
    _emit();
    return _success('已请求取消当前安装。');
  }

  @override
  Future<TuiActionResult> inspectRecovery() async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    _recovery = const TuiRecoveryInfo(state: TuiRecoveryState.checking);
    _appendLog(TuiLogLevel.info, TuiLogCategory.recovery, '检查本地恢复检查点。', eventCode: 'recovery.inspect.started');
    _emit();
    final checkpoint = await _checkpointStore.load();
    if (checkpoint == null) {
      _recovery = const TuiRecoveryInfo(
          state: TuiRecoveryState.none, message: '没有可恢复的安装。');
      _appendLog(
        TuiLogLevel.info,
        TuiLogCategory.recovery,
        '没有可恢复的安装。',
        eventCode: 'recovery.inspect.none',
      );
      _emit();
      return _success('没有可恢复的安装。');
    }
    final file = File(checkpoint.path);
    try {
      if (!await file.exists()) throw const FormatException('文件不存在');
      final bytes = await file.readAsBytes();
      final valid = bytes.length == checkpoint.fileSize &&
          md5.convert(bytes).toString() == checkpoint.md5Hex &&
          sha256.convert(bytes).toString() == checkpoint.sha256Hex;
      _recovery = TuiRecoveryInfo(
        state: valid ? TuiRecoveryState.available : TuiRecoveryState.invalid,
        fileName: checkpoint.path.split(RegExp(r'[/\\]')).last,
        literalPath: checkpoint.path,
        fileSize: checkpoint.fileSize,
        md5Hex: checkpoint.md5Hex,
        sha256Hex: checkpoint.sha256Hex,
        lastAcknowledgedSegment: checkpoint.lastAcknowledgedSegment,
        phase: checkpoint.phase,
        message: valid ? '文件校验通过；偏移由设备协商。' : '文件内容已变化，不能恢复。',
      );
      _appendLog(
        TuiLogLevel.info,
        TuiLogCategory.recovery,
        valid ? '恢复检查点可用。' : '恢复检查点文件已变化。',
        eventCode: valid ? 'recovery.inspect.available' : 'recovery.inspect.invalid',
      );
      _emit();
      return valid
          ? _success('检查点可恢复。')
          : _failure('recovery_unavailable', '检查点文件已变化。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      _recovery = const TuiRecoveryInfo(
          state: TuiRecoveryState.failed, message: '检查恢复文件失败。');
      _emit();
      return _failure('recovery_unavailable', '检查恢复文件失败。');
    }
  }

  @override
  Future<TuiActionResult> resumeRecovery() async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    if (!_backend.sessionReady) return _failure('action_blocked', '请先连接并完成鉴权。');
    if (_backendSnapshot.installRunning || _queueFuture != null)
      return _failure('action_blocked', '当前已有安装在运行。');
    final checkpoint = await _checkpointStore.load();
    if (checkpoint == null)
      return _failure('recovery_unavailable', '没有可恢复的安装。');
    final file = File(checkpoint.path);
    if (!await file.exists())
      return _failure('recovery_unavailable', '恢复文件不存在。');
    final bytes = await file.readAsBytes();
    if (bytes.length != checkpoint.fileSize ||
        md5.convert(bytes).toString() != checkpoint.md5Hex ||
        sha256.convert(bytes).toString() != checkpoint.sha256Hex) {
      return _failure('recovery_unavailable', '恢复文件已变化。');
    }
    try {
      _appendLog(TuiLogLevel.info, TuiLogCategory.recovery, '开始重建恢复任务。', eventCode: 'recovery.resume.started');
      final result = await QueueFileImporter().prepare(
        [checkpoint.path],
        existingPaths: const [],
      );
      if (result.requests.length != 1 ||
          !_requestMatchesCheckpoint(result.requests.single, checkpoint)) {
        return _failure('recovery_unavailable', '恢复文件与检查点不匹配。');
      }
      final request = result.requests.single;
      final matches = _backend.queue
          .where((entry) =>
              QueueFileImporter.normalizePath(entry.request.path) ==
                  QueueFileImporter.normalizePath(checkpoint.path) &&
              _requestMatchesCheckpoint(entry.request, checkpoint))
          .toList();
      if (matches.length > 1) {
        return _failure('recovery_unavailable', '恢复文件在队列中存在多个匹配项。');
      }
      final entry =
          matches.isEmpty ? QueueEntry(request: request) : matches.single;
      if (matches.isEmpty) _backend.enqueue(entry.request);
      entry
        ..stage = QueueStage.waiting
        ..message = '已重建恢复任务，等待设备协商续传偏移。'
        ..failureAttempts = 0;
      final metadata = entry.request.metadata.copyWith(
        faceId: checkpoint.faceId,
        versionCode: checkpoint.versionCode,
      );
      entry.request = InstallRequest(
        kind: checkpoint.kind,
        path: entry.request.path,
        metadata: metadata,
        unsupportedLuaConfirmed: entry.request.unsupportedLuaConfirmed,
        watchfaceResolutionConfirmed:
            entry.request.watchfaceResolutionConfirmed,
      );
      _syncQueueIds();
      _rebuildDecisions();
      _recovery = TuiRecoveryInfo(
          state: TuiRecoveryState.available,
          fileName: checkpoint.path.split(RegExp(r'[/\\]')).last,
          literalPath: checkpoint.path,
          fileSize: checkpoint.fileSize,
          md5Hex: checkpoint.md5Hex,
          sha256Hex: checkpoint.sha256Hex,
          lastAcknowledgedSegment: checkpoint.lastAcknowledgedSegment,
          phase: checkpoint.phase,
          message: '已重新加入队列，设备将协商续传偏移。');
      _emit();
      return _success('恢复任务已加入队列。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      return _failure('recovery_unavailable', '恢复任务重建失败。');
    }
  }

  @override
  Future<TuiActionResult> discardRecovery() async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    if (_backendSnapshot.installRunning || _queueFuture != null)
      return _failure('action_blocked', '安装运行中不能丢弃检查点。');
    await _checkpointStore.clear();
    _appendLog(TuiLogLevel.info, TuiLogCategory.recovery, '已清除本地恢复检查点。', eventCode: 'recovery.discarded');
    _recovery = const TuiRecoveryInfo(
        state: TuiRecoveryState.none, message: '本地检查点已清除；设备端状态不变。');
    _emit();
    return _success('已清除本地检查点。');
  }

  @override
  Future<TuiActionResult> updateTransferSettings(
      {required int segmentIntervalMs, required int massWindowSize}) async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    if (segmentIntervalMs < 1 ||
        segmentIntervalMs > 20 ||
        massWindowSize < 1 ||
        massWindowSize > 50) return _failure('invalid_input', '传输设置超出允许范围。');
    try {
      await _backend.setTransferSettings(
          segmentIntervalMs: segmentIntervalMs, massWindowSize: massWindowSize);
      _appendLog(TuiLogLevel.info, TuiLogCategory.transfer, '传输设置已更新。', eventCode: 'transfer.settings.updated');
      _emit();
      return _success('传输设置已保存。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      return _failure('internal_error', '保存传输设置失败。');
    }
  }

  @override
  Future<TuiActionResult> exportSafeLogs(String literalDestinationPath) async {
    if (!_ensureLive()) return _failure('disposed', 'TUI 已释放。');
    final path = File(literalDestinationPath).absolute;
    if (await path.exists()) {
      return _failure('action_blocked', '目标文件已存在；为避免覆盖，未导出日志。');
    }
    try {
      await path.writeAsString(
          jsonEncode([
            for (final log in _safeLogs())
              {
                'timestamp': log.timestamp.toIso8601String(),
                'level': log.level.name,
                'category': log.category.name,
                if (log.eventCode != null) 'eventCode': log.eventCode,
                'message': log.message
              },
          ]),
          flush: true);
      return _success('安全日志已导出到 ${path.path}。');
    } on Object catch (error) {
      _recordSafeLog('error', error);
      return _failure('internal_error', '安全日志导出失败。');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _appendLog(TuiLogLevel.info, TuiLogCategory.application, 'TUI facade 已释放。', eventCode: 'application.dispose');
    await _transportSub?.cancel();
    await _discoverySub?.cancel();
    await _backendSub?.cancel();
    await _errorSub?.cancel();
    await _backend.dispose();
    await _snapshotController.close();
  }

  bool _ensureLive() => !_disposed;

  String _nextOperation() => 'op${++_operationCounter}';

  TuiActionResult _success(String message) => TuiActionResult(
      accepted: true,
      code: 'ok',
      message: message,
      operationId: _nextOperation());
  TuiActionResult _failure(String code, String message) => TuiActionResult(
      accepted: false,
      code: code,
      message: message,
      operationId: _nextOperation());

  void _mergeDevice(MacBluetoothDevice device, {DeviceProfile? profile}) {
    final key = device.addressKey;
    final old = _devices[key];
    _devices[key] = old == null ? device : old.merge(device);
    final source = switch (device.source) {
      MacBluetoothDeviceSource.paired => TuiDeviceSource.paired,
      MacBluetoothDeviceSource.inquiry => TuiDeviceSource.inquiry,
      MacBluetoothDeviceSource.manual => TuiDeviceSource.manual,
    };
    (_deviceSources[key] ??= <TuiDeviceSource>{}).add(source);
    if (profile != null) _profiles[key] = profile;
    _profiles[key] ??= DeviceProfile.matchAdvertisementName(device.name);
  }

  DeviceProfile? _profileForModel(String modelId) {
    for (final profile in DeviceProfile.recognized) {
      if (profile.generation == ProtocolGeneration.v2Vela &&
          profile.modelHints.contains(modelId)) return profile;
    }
    return null;
  }

  int _queueIndex(String itemId) {
    final entry = _queueById[itemId];
    return entry == null ? -1 : _backend.queue.indexOf(entry);
  }

  void _syncQueueIds() {
    final active = _backend.queue.toSet();
    _queueIds.removeWhere((entry, id) => !active.contains(entry));
    _queueById.clear();
    for (final entry in _backend.queue) {
      final id =
          _queueIds.putIfAbsent(entry, () => 'queue${++_queueIdCounter}');
      _queueById[id] = entry;
    }
  }

  void _rebuildDecisions() {
    _decisions.clear();
    _decisionItemIds.clear();
    _decisionTokens.clear();
    final profile = _backendSnapshot.profile;
    for (final entry in _backend.queue) {
      final id = _queueIds[entry];
      if (id == null || entry.stage != QueueStage.waiting) continue;
      final request = entry.request;
      final metadata = request.metadata;
      TuiPendingDecision? decision;
      if (request.kind == InstallKind.watchface && metadata.faceId == null) {
        decision = TuiPendingDecision(
            decisionId: '$id:face',
            kind: TuiDecisionKind.missingFaceId,
            severity: TuiDecisionSeverity.error,
            title: '需要 faceId',
            message: '文件未读取到设备侧 faceId。',
            inputFields: const [
              TuiDecisionInputField(
                  fieldId: 'faceId',
                  label: 'faceId',
                  format: 'digits',
                  required: true)
            ]);
      } else if (request.kind == InstallKind.quickApp &&
          metadata.versionCode == null) {
        decision = TuiPendingDecision(
            decisionId: '$id:version',
            kind: TuiDecisionKind.invalidRpkVersionCode,
            severity: TuiDecisionSeverity.error,
            title: '需要 versionCode',
            message: 'RPK 清单缺少有效 versionCode。',
            inputFields: const [
              TuiDecisionInputField(
                  fieldId: 'versionCode',
                  label: 'versionCode',
                  format: 'integer',
                  required: true,
                  min: 1,
                  max: maxRpkVersionCode)
            ]);
      } else if (request.kind == InstallKind.watchface &&
          profile?.watchfaceResolution != null &&
          metadata.watchfaceResolutions.isNotEmpty &&
          !metadata.watchfaceResolutions
              .contains(profile!.watchfaceResolution) &&
          !request.watchfaceResolutionConfirmed) {
        decision = TuiPendingDecision(
            decisionId: '$id:resolution',
            kind: TuiDecisionKind.watchfaceResolutionMismatch,
            severity: TuiDecisionSeverity.warning,
            title: '表盘分辨率不匹配',
            message: '文件分辨率与当前设备不一致。',
            facts: [
              '文件: ${metadata.watchfaceResolutions.join(', ')}',
              '设备: ${profile.watchfaceResolution}'
            ]);
      } else if (request.kind == InstallKind.watchface &&
          profile?.family == DeviceFamily.redmiWatch5 &&
          metadata.containsLua &&
          !request.unsupportedLuaConfirmed) {
        decision = TuiPendingDecision(
            decisionId: '$id:lua',
            kind: TuiDecisionKind.redmiWatch5LuaUnsupported,
            severity: TuiDecisionSeverity.warning,
            title: 'REDMI Watch 5 Lua',
            message: '该设备不支持此表盘中的 Lua 内容。');
      }
      if (decision != null) {
        final token = _decisionToken(id, decision.kind, entry);
        final decisionId = '$id:${decision.kind.name}:$token';
        final bound = TuiPendingDecision(
          decisionId: decisionId,
          kind: decision.kind,
          severity: decision.severity,
          title: decision.title,
          message: decision.message,
          facts: decision.facts,
          confirmLabel: decision.confirmLabel,
          cancelLabel: decision.cancelLabel,
          inputFields: decision.inputFields,
          token: token,
          revision: _revision + 1,
        );
        _decisions[decisionId] = bound;
        _decisionItemIds[decisionId] = id;
        _decisionTokens[decisionId] = token;
      }
    }
    _declinedDecisionTokens.removeWhere(
        (token) => !_decisionTokens.values.any((current) => current == token));
  }

  String _decisionToken(
    String itemId,
    TuiDecisionKind kind,
    QueueEntry entry,
  ) {
    final metadata = entry.request.metadata;
    final profile = _backendSnapshot.profile;
    final summary = [
      itemId,
      kind.name,
      entry.request.kind.name,
      entry.request.path,
      metadata.fileSize,
      metadata.md5Hex,
      metadata.sha256Hex,
      metadata.faceId,
      metadata.packageName,
      metadata.versionCode,
      metadata.watchfaceResolutions.join(','),
      metadata.containsLua,
      profile?.modelHints.join(','),
      profile?.watchfaceResolution,
    ].join('|');
    return sha256.convert(utf8.encode(summary)).toString().substring(0, 24);
  }

  bool _requestMatchesCheckpoint(
    InstallRequest request,
    InstallCheckpoint checkpoint,
  ) {
    final metadata = request.metadata;
    return request.kind == checkpoint.kind &&
        metadata.fileSize == checkpoint.fileSize &&
        metadata.md5Hex == checkpoint.md5Hex &&
        metadata.sha256Hex == checkpoint.sha256Hex;
  }

  String? _queueStartBlock() {
    if (!Platform.isMacOS) return '仅支持在 macOS 上运行。';
    if (!_transportSnapshot.connected || !_backend.sessionReady)
      return '请先连接并完成 authkey 鉴权。';
    if (_queueFuture != null ||
        _backendSnapshot.installRunning ||
        _backendSnapshot.queueRunning) return '已有队列操作正在运行。';
    if (!_backend.queue.any((entry) => entry.stage == QueueStage.waiting))
      return '没有等待中的队列条目。';
    if (_backend.queue.any((entry) => entry.isFailure))
      return '队列包含失败或状态未知条目，请先处理。';
    return null;
  }

  TuiSnapshot _makeSnapshot() {
    _syncQueueIds();
    final backend = _backendSnapshot;
    final devices = [for (final d in _devices.values) _deviceView(d)];
    return TuiSnapshot(
      revision: ++_revision,
      platform: TuiPlatformInfo(
          macosOnly: true,
          currentSupported: Platform.isMacOS,
          systemName: Platform.operatingSystem),
      helper: _helperView(),
      scan: TuiScanInfo(
          state: _scanning || _transportSnapshot.scanning
              ? TuiScanState.running
              : TuiScanState.idle,
          endsAt: _scanEndsAt,
          remaining: _scanEndsAt == null
              ? null
              : _scanEndsAt!.difference(DateTime.now()),
          failureMessage: _transportSnapshot.message),
      supportedModels: _models(),
      devices: devices,
      connection: _connectionView(backend),
      authKeyLoaded: backend.authKeyLoaded,
      pendingDecisions: List.unmodifiable(_decisions.values),
      queue: [for (final entry in backend.queue) _queueView(entry)],
      activeTask:
          backend.latestTask == null ? null : _taskView(backend.latestTask!),
      recovery: _recoveryView(),
      transferSettings: TuiTransferSettings(
          segmentIntervalMs: backend.segmentIntervalMs,
          massWindowSize: backend.massWindowSize,
          segmentIntervalMsRange: (1, 20),
          massWindowSizeRange: (1, 50)),
      logs: _safeLogs(),
      notice: _notice,
      allowedActions: _allowedActions(),
      blockedReasons: _blockedReasons(),
      busyOperations: _busyOperations(),
    );
  }

  TuiSnapshot _emit() {
    if (_disposed) return snapshot;
    final next = _makeSnapshot();
    _snapshot = next;
    if (!_snapshotController.isClosed) _snapshotController.add(next);
    return next;
  }

  TuiHelperInfo _helperView() {
    final state = switch (_transportSnapshot.helperState) {
      MacBluetoothHelperState.stopped => TuiHelperState.stopped,
      MacBluetoothHelperState.starting => TuiHelperState.starting,
      MacBluetoothHelperState.ready => TuiHelperState.ready,
      MacBluetoothHelperState.failed => TuiHelperState.failed,
      MacBluetoothHelperState.disposed => TuiHelperState.disposed,
    };
    return TuiHelperInfo(
        state: state, message: _safeMessage(_transportSnapshot.message));
  }

  TuiDevice _deviceView(MacBluetoothDevice d) {
    final profile = _profiles[d.addressKey];
    final supported = profile?.generation == ProtocolGeneration.v2Vela;
    final sources = _deviceSources[d.addressKey] ?? const <TuiDeviceSource>{};
    final modelId = profile == null || profile.modelHints.isEmpty
        ? null
        : profile.modelHints.first;
    return TuiDevice(
        deviceId: 'mac:${d.addressKey}',
        address: d.address,
        addressKey: d.addressKey,
        name: d.name.isEmpty ? null : d.name,
        paired: d.paired,
        sources: sources,
        rssi: d.rssi,
        matchedModelId: modelId,
        matchedModelName: profile?.displayName,
        protocolGeneration: _protocol(profile?.generation),
        supportState: supported
            ? TuiSupportState.supported
            : profile == null
                ? TuiSupportState.unknown
                : TuiSupportState.unsupported,
        blockedReason: supported
            ? null
            : profile == null
                ? '未识别型号'
                : '仅支持 V2 Vela',
        allowedActions: supported ? {'connectDevice'} : const {});
  }

  List<TuiSupportedModel> _models() => [
        for (final profile in DeviceProfile.recognized)
          for (final model in profile.modelHints)
            TuiSupportedModel(
                modelId: model,
                displayName: profile.displayName,
                generation: profile.generation.name,
                supported: profile.generation == ProtocolGeneration.v2Vela)
      ];

  TuiConnectionInfo _connectionView(BackendSnapshot backend) {
    final d = backend.device;
    final state = switch (backend.connection) {
      BackendConnectionState.disconnected => TuiConnectionState.disconnected,
      BackendConnectionState.connecting => TuiConnectionState.connecting,
      BackendConnectionState.awaitingAuthKey =>
        TuiConnectionState.awaitingAuthKey,
      BackendConnectionState.authenticating =>
        TuiConnectionState.authenticating,
      BackendConnectionState.ready => TuiConnectionState.ready,
    };
    return TuiConnectionInfo(
        state: state,
        targetDeviceId: d == null ? null : 'mac:${d.addressKey}',
        targetDeviceName: d?.name,
        targetAddress: d?.address,
        failureMessage: _safeMessage(backend.message),
        failureCode: backend.failureCode);
  }

  TuiQueueItem _queueView(QueueEntry e) {
    final m = e.request.metadata;
    final id = _queueIds[e]!;
    final decisions = _decisions.entries
        .where((entry) => _decisionItemIds[entry.key] == id)
        .toList(growable: false);
    final blockedByDecision = decisions.isNotEmpty;
    final declined = decisions.any(
      (entry) => _declinedDecisionTokens.contains(_decisionTokens[entry.key]),
    );
    final actions = <String>{};
    if (e.stage != QueueStage.installing) actions.add('removeQueueItem');
    if (e.stage == QueueStage.waiting &&
        !blockedByDecision &&
        !_backendSnapshot.queueRunning) {
      actions.add('moveQueueItem');
    }
    if (e.canRetry && _backend.sessionReady && _queueFuture == null) {
      actions.add('retryQueueItem');
    }
    return TuiQueueItem(
        itemId: id,
        kind: e.request.kind == InstallKind.watchface
            ? TuiQueueItemKind.watchface
            : TuiQueueItemKind.quickApp,
        fileName: m.fileName,
        literalPath: e.request.path,
        fileSize: m.fileSize,
        md5Hex: m.md5Hex,
        sha256Hex: m.sha256Hex,
        stage: _queueStage(e.stage),
        faceId: m.faceId,
        watchfaceResolution: m.watchfaceResolutions.isEmpty
            ? null
            : m.watchfaceResolutions.join(', '),
        containsLua: m.containsLua,
        packageName: m.packageName,
        versionCode: m.versionCode,
        message: _safeMessage(e.message),
        failureAttempts: e.failureAttempts,
        canRetry: e.canRetry,
        allowedActions: actions,
        blockedReason:
            !blockedByDecision ? null : (declined ? '用户已拒绝确认' : '等待确认'));
  }

  TuiActiveTask _taskView(InstallTask t) => TuiActiveTask(
      kind: t.kind == InstallKind.watchface
          ? TuiQueueItemKind.watchface
          : TuiQueueItemKind.quickApp,
      fileName: t.fileName,
      stage: _taskStage(t.stage),
      message: _safeMessage(t.message) ?? '处理中',
      targetDeviceName: t.targetDeviceName,
      currentSegment: t.currentSegment,
      totalSegments: t.totalSegments,
      confirmedBytes: t.confirmedBytes,
      queuedBytes: t.queuedBytes,
      totalBytes: t.totalBytes,
      queuedSegment: t.queuedSegment,
      bytesPerSecond: t.bytesPerSecond,
      elapsed: t.elapsed,
      transferElapsed: t.transferElapsed,
      averageBytesPerSecond: t.averageBytesPerSecond,
      successVerifiedByDeviceBusinessEvent:
          t.successVerifiedByDeviceBusinessEvent);

  TuiQueueItemStage _queueStage(QueueStage stage) => switch (stage) {
        QueueStage.waiting => TuiQueueItemStage.waiting,
        QueueStage.installing => TuiQueueItemStage.installing,
        QueueStage.done => TuiQueueItemStage.done,
        QueueStage.failed => TuiQueueItemStage.failed,
        QueueStage.cancelled => TuiQueueItemStage.cancelled,
        QueueStage.stateUnknown => TuiQueueItemStage.stateUnknown
      };
  TuiTaskStage _taskStage(InstallStage stage) => switch (stage) {
        InstallStage.idle => TuiTaskStage.waitingForProtocol,
        InstallStage.validating => TuiTaskStage.validating,
        InstallStage.waitingForProtocol => TuiTaskStage.waitingForProtocol,
        InstallStage.transferring => TuiTaskStage.transferring,
        InstallStage.awaitingDevice => TuiTaskStage.awaitingDevice,
        InstallStage.succeeded => TuiTaskStage.succeeded,
        InstallStage.failed => TuiTaskStage.failed,
        InstallStage.cancelled => TuiTaskStage.cancelled,
        InstallStage.stateUnknown => TuiTaskStage.stateUnknown
      };
  TuiProtocolGeneration _protocol(ProtocolGeneration? generation) =>
      switch (generation) {
        ProtocolGeneration.v1Vela => TuiProtocolGeneration.v1Vela,
        ProtocolGeneration.v2Vela => TuiProtocolGeneration.v2Vela,
        ProtocolGeneration.huamiZepp => TuiProtocolGeneration.huamiZepp,
        _ => TuiProtocolGeneration.unknown
      };

  Set<String> _allowedActions() {
    final out = <String>{'exportSafeLogs'};
    if (!_initialized) return {...out, 'initialize'};
    final helperReady =
        _transportSnapshot.helperState == MacBluetoothHelperState.ready;
    final busy = _queueFuture != null ||
        _backendSnapshot.installRunning ||
        _backendSnapshot.queueRunning;
    if (helperReady) {
      out.add('refreshPairedDevices');
      out.add(_scanning ? 'stopScan' : 'startScan');
      if (!busy) {
        out.addAll(<String>{
          'addManualDevice',
          'importFiles',
          'inspectRecovery',
          'updateTransferSettings',
        });
      }
    }
    if (_backend.device != null &&
        _backendSnapshot.connection != BackendConnectionState.disconnected) {
      out.add('disconnect');
    }
    if (_backendSnapshot.connection == BackendConnectionState.awaitingAuthKey) {
      out.add('submitAuthKey');
    }
    if (_backendSnapshot.authKeyLoaded && !_backendSnapshot.installRunning) {
      out.add('clearAuthKey');
    }
    if (!busy && _backend.queue.any((entry) => entry.stage == QueueStage.done)) {
      out.add('clearCompletedQueue');
    }
    if (!busy && _decisions.isEmpty && _queueStartBlock() == null) {
      out.add('startQueue');
    }
    if (_backendSnapshot.installRunning) out.add('cancelActiveInstall');
    return out;
  }

  Map<String, String> _blockedReasons() {
    final allowed = _allowedActions();
    final out = <String, String>{};
    void add(String action, String reason) {
      if (!allowed.contains(action)) out[action] = reason;
    }

    final helperReady =
        _transportSnapshot.helperState == MacBluetoothHelperState.ready;
    add('refreshPairedDevices',
        helperReady ? '操作正在进行。' : 'Bluetooth helper 未就绪。');
    add('startScan', _scanning ? '扫描已在运行。' : 'Bluetooth helper 未就绪。');
    add('stopScan', _scanning ? '扫描状态正在同步。' : '当前未扫描。');
    add(
        'connectDevice',
        _backendSnapshot.connection == BackendConnectionState.disconnected
            ? '请选择已支持的设备。'
            : '已有连接正在使用。');
    add(
        'startQueue',
        _queueStartBlock() ??
            (_decisions.isNotEmpty ? '请先处理待确认项。' : '队列状态不允许启动。'));
    add('resumeRecovery',
        _backend.sessionReady ? '没有已验证的可恢复检查点。' : '请先连接并完成鉴权。');
    return out;
  }

  Set<TuiBusyOperation> _busyOperations() {
    final out = <TuiBusyOperation>{};
    if (_transportSnapshot.helperState == MacBluetoothHelperState.starting)
      out.add(TuiBusyOperation.initialize);
    if (_scanning) out.add(TuiBusyOperation.scan);
    if (_backendSnapshot.connection == BackendConnectionState.connecting)
      out.add(TuiBusyOperation.connect);
    if (_backendSnapshot.connection == BackendConnectionState.authenticating)
      out.add(TuiBusyOperation.auth);
    if (_backendSnapshot.installRunning || _queueFuture != null)
      out.add(TuiBusyOperation.cleanup);
    return out;
  }

  void _recordSafeLog(String level, Object error) {
    if (error is SppSequenceSpaceExhausted) {
      _appendLog(
        TuiLogLevel.error,
        TuiLogCategory.protocol,
        error.userMessage,
        eventCode: sppSequenceSpaceExhaustedEventCode,
      );
      return;
    }
    _appendLog(
      level == 'error' ? TuiLogLevel.error : TuiLogLevel.info,
      TuiLogCategory.system,
      _safeMessage(error) ?? '未知错误',
      eventCode: 'system.error',
    );
  }

  void _ingestBackendLogs(List<String> rawLogs) {
    var common = 0;
    while (common < _backendLogLines.length &&
        common < rawLogs.length &&
        _backendLogLines[common] == rawLogs[common]) {
      common++;
    }
    if (common != _backendLogLines.length) {
      _backendLogLines
        ..clear()
        ..addAll(rawLogs.take(common));
    }
    for (final raw in rawLogs.skip(common)) {
      _backendLogLines.add(raw);
      final safe = _safeMessage(raw) ?? '后台事件';
      _appendLog(
        _levelForBackendMessage(safe),
        _categoryForBackendMessage(safe),
        safe,
        eventCode: 'backend.event',
      );
    }
  }

  void _appendLog(
    TuiLogLevel level,
    TuiLogCategory category,
    Object? message, {
    String? eventCode,
  }) {
    final safe = _safeMessage(message) ?? '未提供诊断信息';
    _logs.add(TuiLogEntry(
      timestamp: DateTime.now(),
      level: level,
      category: category,
      eventCode: eventCode,
      message: safe,
    ));
    if (_logs.length > 500) _logs.removeRange(0, _logs.length - 500);
  }

  List<TuiLogEntry> _safeLogs() => List.unmodifiable(_logs);

  void _recordTransportTransition(
    MacBluetoothTransportSnapshot previous,
    MacBluetoothTransportSnapshot next,
  ) {
    if (previous.helperState != next.helperState) {
      _appendLog(
        next.helperState == MacBluetoothHelperState.failed ? TuiLogLevel.error : TuiLogLevel.info,
        TuiLogCategory.helper,
        'Bluetooth helper 状态变为 ${next.helperState.name}。',
        eventCode: 'helper.state.${next.helperState.name}',
      );
    }
    if (previous.scanning != next.scanning) {
      _appendLog(TuiLogLevel.info, TuiLogCategory.discovery, next.scanning ? '扫描已开始。' : '扫描已结束。', eventCode: next.scanning ? 'discovery.scan.running' : 'discovery.scan.ended');
    }
    if (previous.connected != next.connected) {
      _appendLog(TuiLogLevel.info, TuiLogCategory.connection, next.connected ? '传输已连接。' : '传输已断开。', eventCode: next.connected ? 'connection.transport.connected' : 'connection.transport.disconnected');
    }
  }

  void _recordBackendTransition(BackendSnapshot previous, BackendSnapshot next) {
    if (previous.connection != next.connection) {
      final category = switch (next.connection) {
        BackendConnectionState.awaitingAuthKey || BackendConnectionState.authenticating => TuiLogCategory.authentication,
        _ => TuiLogCategory.connection,
      };
      _appendLog(TuiLogLevel.info, category, '后端连接状态变为 ${next.connection.name}。', eventCode: 'connection.state.${next.connection.name}');
    }
    if (previous.installRunning != next.installRunning) {
      _appendLog(TuiLogLevel.info, TuiLogCategory.install, next.installRunning ? '安装任务已开始。' : '安装任务已结束。', eventCode: next.installRunning ? 'install.running' : 'install.finished');
    }
    if (previous.failureCode != next.failureCode &&
        next.failureCode == sppSequenceSpaceExhaustedFailureCode) {
      const message = 'SPP 序号空间已耗尽，必须重建 RFCOMM 会话后重试。';
      _appendLog(
        TuiLogLevel.error,
        TuiLogCategory.protocol,
        message,
        eventCode: sppSequenceSpaceExhaustedEventCode,
      );
      _notice = TuiNotice(
        id: sppSequenceSpaceExhaustedFailureCode,
        message: message,
        severity: TuiDecisionSeverity.error,
        createdAt: DateTime.now(),
      );
    } else if (previous.failureCode == sppSequenceSpaceExhaustedFailureCode &&
        next.failureCode == null &&
        _notice?.id == sppSequenceSpaceExhaustedFailureCode) {
      _notice = null;
    }
  }

  TuiLogCategory _categoryForBackendMessage(String text) {
    final lower = text.toLowerCase();
    bool has(String value) => lower.contains(value);
    if (has('auth') || has('鉴权') || has('f=26') || has('f=27')) return TuiLogCategory.authentication;
    if (has('l1') || has('l2') || has('ack') || has('crc') || has('protobuf') || has('协议') || has('帧')) return TuiLogCategory.protocol;
    if (has('mass') || has('分片') || has('传输') || has('segment')) return TuiLogCategory.transfer;
    if (has('预安装') || has('安装') || has('表盘') || has('rpk')) return TuiLogCategory.install;
    if (has('检查点') || has('恢复') || has('续传')) return TuiLogCategory.recovery;
    if (has('文件') || has('路径') || has('metadata') || has('hash')) return TuiLogCategory.filesystem;
    if (has('permission') || has('授权')) return TuiLogCategory.permission;
    if (has('helper') || has('bridge') || has('iobluetooth')) return TuiLogCategory.helper;
    if (has('scan') || has('扫描') || has('discovery') || has('paired')) return TuiLogCategory.discovery;
    if (has('connect') || has('disconnect') || has('连接') || has('断开') || has('rfcomm')) return TuiLogCategory.connection;
    if (has('security') || has('gate') || has('敏感') || has('拒绝')) return TuiLogCategory.security;
    return TuiLogCategory.application;
  }

  TuiLogLevel _levelForBackendMessage(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('error') || lower.contains('exception') || lower.contains('失败') || lower.contains('超时')) return TuiLogLevel.error;
    if (lower.contains('warning') || lower.contains('拒绝') || lower.contains('未知')) return TuiLogLevel.warning;
    if (lower.contains('debug') || lower.contains('trace')) return TuiLogLevel.debug;
    return TuiLogLevel.info;
  }

  TuiRecoveryInfo _recoveryView() {
    final actions = <String>{'inspectRecovery'};
    final busy = _backendSnapshot.installRunning || _queueFuture != null;
    if (_recovery.state == TuiRecoveryState.available &&
        _backend.sessionReady &&
        !busy) {
      actions.add('resumeRecovery');
    }
    if (_recovery.state != TuiRecoveryState.unchecked && !busy) {
      actions.add('discardRecovery');
    }
    return TuiRecoveryInfo(
      state: _recovery.state,
      fileName: _recovery.fileName,
      literalPath: _recovery.literalPath,
      fileSize: _recovery.fileSize,
      md5Hex: _recovery.md5Hex,
      sha256Hex: _recovery.sha256Hex,
      lastAcknowledgedSegment: _recovery.lastAcknowledgedSegment,
      phase: _recovery.phase,
      message: _recovery.message,
      allowedActions: actions,
    );
  }

  String? _safeMessage(Object? value) {
    if (value == null) return null;
    var text = value is String ? value : _errorCode(value);
    text = text.split('；stderr:').first;
    if (text.length > 512) text = text.substring(0, 512);
    // Do this before a message enters the log buffer. Backend diagnostics can
    // include protocol material, but it must never become UI or export data.
    text = text.replaceAll(
      RegExp(
        r"""(?:auth(?:key|entication)?|nonce|hmac|session(?:[_ -]?key)?|secret|derived[_ -]?key|base64)\s*[:=：]\s*(?:["']?)[^\s,，。;；"']+""",
        caseSensitive: false,
      ),
      '[已隐藏敏感字段]',
    );
    text = text.replaceAll(
      RegExp(r'(?<![0-9A-Fa-f])[0-9A-Fa-f]{32}(?![0-9A-Fa-f])'),
      '[已隐藏认证材料]',
    );
    text = text.replaceAll(
      RegExp(r'(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/_-]{48,}={0,2}(?![A-Za-z0-9+/=_-])'),
      '[已隐藏编码载荷]',
    );
    return text;
  }

  String _errorCode(Object error) {
    if (error is SppSequenceSpaceExhausted) {
      return sppSequenceSpaceExhaustedFailureCode;
    }
    if (error is MacBluetoothNativeException) return 'transport_failure';
    if (error is TimeoutException) return 'timeout';
    if (error is UnsupportedError) return 'unsupported_platform';
    if (error is FormatException) return 'invalid_input';
    return 'transport_failure';
  }

  String _safeFailureMessage(Object error) {
    if (error is SppSequenceSpaceExhausted) return error.userMessage;
    if (error is UnsupportedError) return '当前平台不受支持。';
    if (error is TimeoutException) return '操作超时。';
    if (error is StateError) return '设备或协议状态不允许此操作。';
    return '连接设备失败。';
  }
}
