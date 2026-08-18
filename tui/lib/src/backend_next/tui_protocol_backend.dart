library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/device_profile.dart';
import '../domain/install_checkpoint_store.dart';
import '../domain/install_models.dart';
import '../domain/install_task.dart';
import '../domain/mass_ack_idle_timeout.dart';
import '../domain/protocol/auth_handshake.dart';
import '../domain/protocol/mass_transfer.dart';
import '../domain/protocol/session_cipher.dart';
import '../domain/protocol/spp_protocol.dart';
import '../domain/protocol/spp_sequence_allocator.dart';
import '../domain/protocol/zau.dart';
import '../domain/queue_file_importer.dart';
import '../domain/transfer_settings_store.dart';
import '../domain/verification_gate.dart';
import '../diagnostics/diagnostic_journal.dart';
import 'tui_mac_bluetooth_transport.dart';
import 'tui_protocol_snapshot.dart';
import 'tui_backend_port.dart';

/// Reconnects the physical RFCOMM link after a successful f=27 transition.
///
/// Production adapters inject this callback so native connection-attempt
/// ownership remains outside the protocol core. The protocol backend remains
/// usable standalone; when omitted it falls back to its own transport.
typedef TuiPostAuthReconnect = Future<void> Function(TuiTransportDevice device);

/// The device's f=26 response reached this process, but its signature did not
/// verify with the selected authkey/optional binding material.  No f=27 bytes
/// may be emitted for this condition.
const String deviceSignatureMismatchFailureCode = 'device_signature_mismatch';

/// Pure-Dart V2 installer backend for macOS classic Bluetooth/RFCOMM.
/// No Flutter, BLE UUID conversion, or platform channels are used here.
class TuiProtocolBackend {
  TuiProtocolBackend({
    required TuiMacBluetoothTransport transport,
    InstallCheckpointStore? checkpointStore,
    TransferSettingsStore? settingsStore,
    Random? random,
    Duration ackTimeout = const Duration(seconds: 12),
    Duration handshakeTimeout = const Duration(seconds: 15),
    Duration? ackQuarantineDuration,
    DateTime Function()? clock,
    TuiPostAuthReconnect? postAuthReconnect,
    DiagnosticJournal? diagnosticJournal,
  })  : _transport = transport,
        _checkpointStore = checkpointStore ?? InstallCheckpointStore(),
        _settingsStore = settingsStore ?? TransferSettingsStore(),
        _random = random ?? Random.secure(),
        _ackTimeout = ackTimeout,
        _handshakeTimeout = handshakeTimeout,
        _postAuthReconnect = postAuthReconnect,
        _diagnosticJournal = diagnosticJournal,
        _sequenceAllocator = SppSequenceAllocator(
          quarantineDuration: ackQuarantineDuration ??
              (ackTimeout.inMicroseconds * 2 >=
                      const Duration(seconds: 30).inMicroseconds
                  ? Duration(microseconds: ackTimeout.inMicroseconds * 2)
                  : const Duration(seconds: 30)),
          clock: clock,
        ) {
    if (ackTimeout <= Duration.zero) {
      throw ArgumentError.value(ackTimeout, 'ackTimeout', '必须大于零');
    }
    if (handshakeTimeout <= Duration.zero) {
      throw ArgumentError.value(handshakeTimeout, 'handshakeTimeout', '必须大于零');
    }
    _inputSubscription = _transport.input.listen(_onInput,
        onError: _onTransportError, onDone: _onTransportClosed);
    _errorSubscription = _transport.errors.listen(_onTransportError);
    unawaited(_restoreSettings());
  }

  final TuiMacBluetoothTransport _transport;

  /// WearAuthV2 material locked to the active connection attempt. It is never
  /// derived from a Bluetooth address or authkey and is cleared on invalidation.
  TuiBackendBindingMaterial? _sessionBinding;
  final InstallCheckpointStore _checkpointStore;
  final TransferSettingsStore _settingsStore;
  final Random _random;
  final Duration _ackTimeout;
  final Duration _handshakeTimeout;
  final DiagnosticJournal? _diagnosticJournal;
  TuiPostAuthReconnect? _postAuthReconnect;
  // Sequence numbers belong to the physical RFCOMM generation, not merely
  // to a logical auth/session epoch. It is replaced only after connect.done.
  SppSequenceAllocator _sequenceAllocator;
  final StreamController<TuiProtocolSnapshot> _snapshots =
      StreamController<TuiProtocolSnapshot>.broadcast();
  final StreamController<Zau> _business = StreamController<Zau>.broadcast();
  final List<QueueEntry> _queue = [];
  final List<String> _logs = [];
  final Map<int, _PendingAck> _acks = {};
  final List<_PendingAck> _massAckOrder = [];
  final Map<_PendingAck, _Progress> _massProgress = {};
  final Set<_BusinessWaiter> _completionWaiters = {};

  StreamSubscription<Uint8List>? _inputSubscription;
  StreamSubscription<Object>? _errorSubscription;
  TuiTransportDevice? _device;
  DeviceProfile? _profile;
  TuiProtocolConnectionState _connection =
      TuiProtocolConnectionState.disconnected;
  InstallTask? _latestTask;
  String? _message;
  String? _failureCode;
  String? _authKey;
  SessionCipher? _cipher;
  SessionKeys? _pendingKeys;
  List<int>? _phoneNonce;
  Accumulator _accumulator = Accumulator();
  Timer? _watchdog;
  Timer? _postAuthTransitionTimer;
  bool _installing = false;
  bool _cancelled = false;
  Completer<void>? _cancelSignal;
  Completer<Object>? _transportFailure;
  InstallRequest? _lastRequest;
  int _segmentIntervalMs = 5;
  int _massWindowSize = 3;
  double? _bytesPerSecond;
  DateTime? _lastSpeedTime;
  int _lastSpeedBytes = 0;
  // ignore: unused_field
  DateTime? _authenticatedAt;
  DateTime? _postAuthTransitionDeadline;
  bool _recoveringPostAuthClose = false;
  bool _resumeAuthenticatedSession = false;
  bool _explicitDisconnect = false;
  bool _queueRunning = false;
  bool _disposed = false;
  int _postAuthReconnectAttempts = 0;
  int _sessionEpoch = 0;
  int _transportGeneration = 0;
  _HandshakePhase _handshake = _HandshakePhase.none;
  int _handshakePhaseToken = 0;
  Future<void> _orderedWrite = Future<void>.value();
  Future<void> _orderedPacketHandling = Future<void>.value();
  Future<void> _journalTail = Future<void>.value();

  Stream<TuiProtocolSnapshot> get snapshots => _snapshots.stream;
  TuiProtocolSnapshot get snapshot => _makeSnapshot();
  List<QueueEntry> get queue => List.unmodifiable(_queue);
  bool get sessionReady => _connection == TuiProtocolConnectionState.ready;
  TuiTransportDevice? get device => _device;
  bool get authKeyLoaded => _authKey != null;
  bool get queueRunning => _queueRunning;

  /// Installs the adapter-owned physical reconnect boundary. This callback
  /// must complete only after the native helper has admitted the new RFCOMM
  /// tuple; it must not invoke [TuiProtocolBackend.connect] recursively.
  void setPostAuthReconnectHandler(TuiPostAuthReconnect? handler) {
    if (_disposed) throw StateError('TUI protocol backend 已释放。');
    _postAuthReconnect = handler;
  }

  void setAuthKey(String value) {
    if (XiaomiAuth.secretKeyFromHex(value) == null) {
      throw const FormatException('authkey 必须为 32 位十六进制字符');
    }
    _authKey = value.toLowerCase();
    _emit('authkey 已装载，仅保留于内存。');
    if (_connection == TuiProtocolConnectionState.awaitingAuthKey) {
      _connection = TuiProtocolConnectionState.authenticating;
      _setHandshakePhase(_HandshakePhase.f26Sent);
      _emit('开始 authkey 会话鉴权。');
      _runHandshakeStep(
        (epoch, token) =>
            _sendAuthStep1(expectedEpoch: epoch, expectedPhaseToken: token),
        '发送 f=26',
      );
    }
  }

  /// Clears the in-memory auth key and all derived session material.
  Future<void> clearAuthKey() async {
    if (_installing) await cancelInstall();
    ++_sessionEpoch;
    _setHandshakePhase(_HandshakePhase.none);
    _clearSensitiveSessionMaterial(clearAuthKey: true);
    _resumeAuthenticatedSession = false;
    _recoveringPostAuthClose = false;
    _failPending(const _Cancelled());
    if (_connection != TuiProtocolConnectionState.disconnected) {
      _connection = TuiProtocolConnectionState.awaitingAuthKey;
      _setHandshakePhase(_HandshakePhase.awaitingAuthKey);
    }
    _emit('authkey 与会话材料已从内存清除。');
  }

  Future<void> connect(
    TuiTransportDevice device, {
    DeviceProfile? profile,
    required TuiBackendBindingMaterial? bindingMaterial,
  }) async {
    if (!Platform.isMacOS)
      throw UnsupportedError('Wristload TUI only supports macOS.');
    if (!kSppAuthProtocolVerified) throw StateError('SPP 鉴权尚未通过真机验证。');
    await disconnect();
    final resolvedProfile =
        profile ?? DeviceProfile.matchAdvertisementName(device.name);
    if (resolvedProfile == null ||
        resolvedProfile.generation != ProtocolGeneration.v2Vela) {
      throw StateError('仅支持已验证的 V2 Vela 安装设备。');
    }
    _device = device;
    _profile = resolvedProfile;
    _connection = TuiProtocolConnectionState.connecting;
    _accumulator = Accumulator();
    _clearSensitiveSessionMaterial(clearBinding: true);
    // disconnect() and the explicit cleanup above erased all retired session
    // material. Lock this exact per-device binding only after that boundary so
    // it survives the logical session, including a post-auth RFCOMM rebuild.
    // This is optional explicit WearAuthV2 material for the exact device. The
    // official Classic path also permits f=26 without it; never derive a
    // replacement from the Bluetooth address or authkey.
    _sessionBinding = bindingMaterial;
    _resumeAuthenticatedSession = false;
    _postAuthReconnectAttempts = 0;
    final epoch = ++_sessionEpoch;
    final generation = ++_transportGeneration;
    _setHandshakePhase(_HandshakePhase.connecting);
    _emit('正在通过 macOS RFCOMM 连接 ${device.address}。');
    try {
      await _transport.connect(device);
      if (epoch != _sessionEpoch) return;
      // TuiMacBluetoothTransport.connect completes only after a new physical
      // RFCOMM connection has emitted connect.done. Old 8-bit ACKs therefore
      // cannot arrive on this new byte stream and the sequence space may be
      // created afresh here. Never reset it before that boundary.
      _sequenceAllocator = SppSequenceAllocator();
      final phaseToken = _setHandshakePhase(_HandshakePhase.l1StartSent);
      _failureCode = null;
      _connection = TuiProtocolConnectionState.authenticating;
      _emit('RFCOMM 已连接，发送 L1START。');
      await _writeOrdered(SppProtocol.buildL1StartRequest(), generation);
      _journalL1StartSent(resumed: false);
      if (_disposed || epoch != _sessionEpoch) return;
      _armWatchdog('15 秒内未收到 L1START 响应。', expectedPhaseToken: phaseToken);
    } on Object catch (error) {
      if (epoch == _sessionEpoch) {
        _invalidateSession();
        _emit('RFCOMM 连接失败：$error');
      }
      rethrow;
    }
  }

  Future<void> disconnect() async {
    if (_disposed && _connection == TuiProtocolConnectionState.disconnected)
      return;
    _explicitDisconnect = true;
    ++_sessionEpoch;
    ++_transportGeneration;
    _setHandshakePhase(_HandshakePhase.none);
    _watchdog?.cancel();
    _watchdog = null;
    if (_installing) await cancelInstall();
    _failPending(const _Cancelled());
    _clearSensitiveSessionMaterial(clearBinding: true);
    _resumeAuthenticatedSession = false;
    _recoveringPostAuthClose = false;
    _postAuthReconnectAttempts = 0;
    _connection = TuiProtocolConnectionState.disconnected;
    _device = null;
    _profile = null;
    try {
      await _transport.disconnect();
    } on Object catch (error) {
      _log('RFCOMM 本地清理返回错误：$error');
    } finally {
      _explicitDisconnect = false;
    }
    _emit('已断开 RFCOMM。');
  }

  void enqueue(InstallRequest request) {
    _queue.add(QueueEntry(request: request));
    _emit('已加入安装队列。');
  }

  bool removeQueueEntry(int index) {
    if (index < 0 || index >= _queue.length) return false;
    if (_queue[index].stage == QueueStage.installing) return false;
    _queue.removeAt(index);
    _emit('已移除队列条目。');
    return true;
  }

  bool reorderQueue(int oldIndex, int newIndex) {
    if (_queue.any((entry) => entry.stage == QueueStage.installing))
      return false;
    if (oldIndex < 0 || oldIndex >= _queue.length) return false;
    if (newIndex < 0 || newIndex > _queue.length) return false;
    if (oldIndex < newIndex) newIndex--;
    final entry = _queue.removeAt(oldIndex);
    _queue.insert(newIndex, entry);
    _emit('已调整队列顺序。');
    return true;
  }

  void clearCompletedQueue() {
    _queue.removeWhere((entry) => entry.stage == QueueStage.done);
    _emit('已清理完成的队列条目。');
  }

  Future<QueueFileImportResult> importFiles(Iterable<String> paths) async {
    final result = await QueueFileImporter().prepare(paths,
        existingPaths: _queue.map((entry) => entry.request.path));
    for (final request in result.requests) {
      _queue.add(QueueEntry(request: request));
    }
    _emit('队列导入完成：${result.addedCount} 个文件。');
    return result;
  }

  Future<void> runQueue({QueueEntry? preferredEntry}) async {
    if (_installing || _queueRunning) return;
    _queueRunning = true;
    _emit(null);
    try {
      while (true) {
        final preferred = preferredEntry != null &&
                _queue.contains(preferredEntry) &&
                preferredEntry.stage == QueueStage.waiting
            ? preferredEntry
            : null;
        if (preferred == null && _queue.any((entry) => entry.canRetry)) return;
        final entry = preferred ?? _firstWaitingEntry();
        preferredEntry = null;
        if (entry == null) return;
        entry
          ..stage = QueueStage.installing
          ..message = null;
        _emit('开始队列安装 ${entry.request.metadata.fileName}。');
        try {
          await startInstall(entry.request);
        } on Object catch (error) {
          entry
            ..stage = QueueStage.failed
            ..message = '安装未启动：$error'
            ..failureAttempts += 1;
          _emit(entry.message);
          return;
        }
        final stage = _latestTask?.stage;
        if (stage == InstallStage.waitingForProtocol ||
            stage == InstallStage.idle ||
            stage == null) {
          entry
            ..stage = QueueStage.waiting
            ..message = _latestTask?.message;
          _emit(entry.message);
          return;
        }
        entry.stage = switch (stage) {
          InstallStage.succeeded => QueueStage.done,
          InstallStage.cancelled => QueueStage.cancelled,
          InstallStage.stateUnknown => QueueStage.stateUnknown,
          _ => QueueStage.failed,
        };
        entry.message = _latestTask?.message;
        if (entry.isFailure) entry.failureAttempts++;
        _emit(entry.message);
        if (entry.isFailure) return;
      }
    } finally {
      _queueRunning = false;
      _emit(null);
    }
  }

  Future<void> retry(QueueEntry entry) async {
    if (!_queue.contains(entry) || !entry.canRetry) return;
    final previousStage = entry.stage;
    final previousMessage = entry.message;
    final previousAttempts = entry.failureAttempts;
    _journalEvent(
      event: 'install.retry',
      category: DiagnosticCategory.install,
      message: 'Installation retry requested.',
      stage: previousStage.name,
      retry: previousAttempts + 1,
      fields: <String, Object?>{'kind': entry.request.kind.name},
    );
    try {
      if (!sessionReady) {
        final device = _device;
        if (device == null) throw StateError('没有要重连的设备。');
        // A retry reuses the exact optional material captured for this logical
        // session. Its absence selects the official nonce-only Classic branch;
        // never derive a replacement from the device identity or authkey.
        final bindingMaterial = _sessionBinding;
        await connect(
          device,
          profile: _profile,
          bindingMaterial: bindingMaterial,
        );
        await _waitForReady();
      }
      entry
        ..stage = QueueStage.waiting
        ..message = null;
    } on Object {
      entry
        ..stage = previousStage
        ..message = previousMessage
        ..failureAttempts = previousAttempts;
      _emit('重试前的连接或鉴权失败；保留原队列终态。');
      rethrow;
    }
    await runQueue(preferredEntry: entry);
  }

  Future<void> startInstall(InstallRequest request) async {
    if (_installing) throw StateError('已有安装任务正在运行。');
    try {
      const VerificationGate().ensureCanSend();
    } on StateError catch (error) {
      _publish(request, InstallStage.waitingForProtocol, error.message);
      return;
    }
    if (!sessionReady || _cipher == null || _device == null) {
      _publish(
          request, InstallStage.waitingForProtocol, '请先连接设备并完成 authkey 鉴权。');
      return;
    }
    _installing = true;
    _journalEvent(
      event: 'install.requested',
      category: DiagnosticCategory.install,
      message: 'Installation requested.',
      stage: 'requested',
      fields: <String, Object?>{
        'kind': request.kind.name,
        'totalBytes': request.metadata.fileSize,
      },
    );
    _cancelled = false;
    _lastRequest = request;
    _cancelSignal = Completer<void>();
    _transportFailure = Completer<Object>();
    _clearPostAuthTransition();
    try {
      await _runInstall(request);
    } on _Cancelled {
      _publish(request, InstallStage.cancelled, '已取消；设备可能保留部分数据。');
    } on _DeviceFailure catch (error) {
      await _clearCheckpoint();
      _publish(request, InstallStage.failed, error.message);
    } on SppSequenceSpaceExhausted catch (error) {
      _failureCode = sppSequenceSpaceExhaustedFailureCode;
      _invalidateTransportSession(error);
      _publish(request, InstallStage.stateUnknown, error.userMessage);
    } on FormatException catch (error) {
      _publish(request, InstallStage.failed, error.message);
    } on _InvalidDeviceResponse catch (error) {
      _invalidateTransportSession(error);
      _publish(
          request, InstallStage.stateUnknown, '设备响应无法验证，状态未知：${error.message}');
    } on TimeoutException catch (error) {
      _invalidateTransportSession(error);
      _publish(request, InstallStage.stateUnknown,
          '设备超时，状态未知：${error.message ?? ''}');
    } on Object catch (error) {
      _invalidateTransportSession(error);
      _publish(request, InstallStage.stateUnknown, '传输停止，设备状态未知：$error');
    } finally {
      for (final waiter in _completionWaiters.toList()) {
        await waiter.cancel();
      }
      _completionWaiters.clear();
      _failPending(const _Cancelled());
      _installing = false;
      _cancelSignal = null;
      _transportFailure = null;
      _emit(_latestTask?.message);
    }
  }

  Future<void> cancelInstall() async {
    if (!_installing) return;
    _journalEvent(
      event: 'install.cancel_requested',
      category: DiagnosticCategory.install,
      severity: DiagnosticSeverity.warning,
      message: 'Installation cancellation requested.',
      stage: _latestTask?.stage.name ?? 'running',
      fields: <String, Object?>{
        if (_latestTask != null) 'kind': _latestTask!.kind.name,
      },
    );
    _cancelled = true;
    if (!(_cancelSignal?.isCompleted ?? true)) _cancelSignal!.complete();
    _invalidateTransportSession(const _Cancelled());
    _log('取消了本地发送；未发送未经验证的设备取消帧。');
  }

  Future<InstallCheckpoint?> checkRecoverableInstall() async {
    final checkpoint = await _checkpointStore.load();
    if (checkpoint == null) return null;
    final file = File(checkpoint.path);
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.length != checkpoint.fileSize ||
        md5.convert(bytes).toString() != checkpoint.md5Hex ||
        sha256.convert(bytes).toString() != checkpoint.sha256Hex) return null;
    _emit('检查点文件校验通过；续传偏移仍以设备 MassPrepare 为准。');
    return checkpoint;
  }

  Future<void> setTransferSettings(
      {required int segmentIntervalMs, required int massWindowSize}) async {
    _segmentIntervalMs = segmentIntervalMs.clamp(1, 20).toInt();
    _massWindowSize = massWindowSize.clamp(1, 50).toInt();
    await _settingsStore.write(
        segmentIntervalMs: _segmentIntervalMs, massWindowSize: _massWindowSize);
    _emit('传输设置已保存。');
  }

  Future<void> _restoreSettings() async {
    final settings = await _settingsStore.read();
    if (settings.segmentIntervalMs case final value?
        when value >= 1 && value <= 20) _segmentIntervalMs = value;
    if (settings.massWindowSize case final value?
        when value >= 1 && value <= 50) _massWindowSize = value;
    _emit(null);
  }

  QueueEntry? _firstWaitingEntry() {
    for (final entry in _queue) {
      if (entry.stage == QueueStage.waiting) return entry;
    }
    return null;
  }

  Future<void> _runInstall(InstallRequest request) async {
    _validateRequest(request);
    final bytes = await _readAndVerify(request);
    _publish(request, InstallStage.validating, '元数据与文件哈希已重新校验。');
    final dataType = request.kind == InstallKind.watchface
        ? MassDataType.watchface
        : MassDataType.quickAppRpk;
    final completion = request.kind == InstallKind.watchface
        ? _listenBusiness(ZauCommand.setFace, 5)
        : _listenQuickAppResult(request.metadata.packageName!);
    var preinstallSlice = 0;
    if (request.kind == InstallKind.watchface) {
      final reply = await _requestBusiness(
          Zau(
              command: ZauCommand.setFace,
              sub: 4,
              payload: A9u.withFileInfo(
                  faceId: request.metadata.faceId!, fileSize: bytes.length)),
          ZauCommand.setFace,
          4);
      final payload = reply.payload;
      if (payload == null) throw const _InvalidDeviceResponse('表盘预安装响应缺少载荷。');
      late final ({String kind, int code, String? faceId}) parsed;
      try {
        parsed = A9u.parse(payload.$2);
      } on FormatException catch (error) {
        throw _InvalidDeviceResponse(error.message);
      }
      if (parsed.code != 0)
        throw _DeviceFailure('设备拒绝表盘预安装，状态=${parsed.code}。');
    } else {
      final reply = await _requestBusiness(
          Zau(
              command: ZauCommand.prepareInstallApp,
              sub: 1,
              payload: V8s.prepareRequest(
                  packageName: request.metadata.packageName!,
                  versionCode: request.metadata.versionCode!,
                  packageSize: bytes.length)),
          ZauCommand.prepareInstallApp,
          1);
      final payload = reply.payload;
      if (payload == null) throw const _InvalidDeviceResponse('RPK 预安装响应缺少载荷。');
      late final ({int status, int expectedSliceLength}) result;
      try {
        result = V8s.parsePrepareResponse(payload.$2);
      } on FormatException catch (error) {
        throw _InvalidDeviceResponse(error.message);
      }
      if (result.status != 0)
        throw _DeviceFailure('设备拒绝 RPK 预安装，状态=${result.status}。');
      preinstallSlice = result.expectedSliceLength;
    }
    _checkCancelled();
    final prepared = await _requestBusiness(
        Zau(
            command: ZauCommand.massTransfer,
            payload: O1h.prepareRequest(
                dataType: dataType,
                fileMd5: _hex(request.metadata.md5Hex),
                fileLength: bytes.length)),
        ZauCommand.massTransfer,
        0);
    final payload = prepared.payload;
    if (payload == null)
      throw const _InvalidDeviceResponse('MassPrepare 响应缺少载荷。');
    late final ({
      int prepareStatus,
      int remainLength,
      int expectedSliceLength
    }) mass;
    try {
      mass = O1h.parsePrepareResponse(payload.$2);
    } on FormatException catch (error) {
      throw _InvalidDeviceResponse(error.message);
    }
    if (mass.prepareStatus != 0)
      throw _DeviceFailure('MassPrepare 被拒绝，状态=${mass.prepareStatus}。');
    if (mass.remainLength < 0 || mass.remainLength > bytes.length)
      throw StateError('设备给出无效续传偏移。');
    final segmentLength = mass.expectedSliceLength > 4
        ? mass.expectedSliceLength
        : (preinstallSlice > 4 ? preinstallSlice : defaultMassSegmentLength);
    final plan = mass.remainLength == bytes.length
        ? null
        : planMassFile(
            fileBytes: bytes,
            dataType: dataType,
            fileMd5: _hex(request.metadata.md5Hex),
            segmentLength: segmentLength,
            sentLength: mass.remainLength);
    await _saveCheckpoint(request, dataType, 0, 'transferring');
    var confirmed = mass.remainLength;
    _lastSpeedTime = DateTime.now();
    _lastSpeedBytes = confirmed;
    _bytesPerSecond = null;
    final iterator = plan?.segments.iterator;
    while (iterator != null) {
      final batch = <MassSegment>[];
      final confirmedBySegment = <int, int>{};
      var queued = confirmed;
      while (batch.length < _massWindowSize && iterator.moveNext()) {
        final segment = iterator.current;
        batch.add(segment);
        queued = min(bytes.length, queued + segment.fileByteCount);
        confirmedBySegment[segment.index] = queued;
      }
      if (batch.isEmpty) break;
      _checkCancelled();
      _publish(request, InstallStage.transferring,
          '正在发送第 ${batch.first.index}-${batch.last.index}/${batch.last.total} 片。',
          currentSegment: batch.first.index - 1,
          totalSegments: batch.last.total,
          confirmedBytes: confirmed,
          queuedSegment: batch.last.index,
          queuedBytes: queued,
          totalBytes: bytes.length,
          bytesPerSecond: _bytesPerSecond);
      await _queueMassWindow(batch, request, confirmedBySegment, bytes.length);
      confirmed = queued;
      await _saveCheckpoint(
          request, dataType, batch.last.index, 'transferring');
      if (batch.last.index < batch.last.total)
        await Future<void>.delayed(Duration(milliseconds: _segmentIntervalMs));
    }
    final totalSegments = plan?.totalSegments ?? 0;
    _publish(request, InstallStage.awaitingDevice, '文件已确认发送，正在等待设备安装结果。',
        currentSegment: totalSegments,
        totalSegments: totalSegments,
        confirmedBytes: bytes.length,
        queuedSegment: totalSegments,
        queuedBytes: bytes.length,
        totalBytes: bytes.length,
        bytesPerSecond: _bytesPerSecond);
    await _saveCheckpoint(request, dataType, totalSegments, 'awaitingDevice');
    final result = await _withCancellation(completion.future.timeout(
        request.kind == InstallKind.watchface
            ? const Duration(minutes: 5)
            : const Duration(seconds: 120)));
    if (request.kind == InstallKind.watchface) {
      final resultPayload = result.payload;
      if (resultPayload == null)
        throw const _InvalidDeviceResponse('表盘完成事件缺少载荷。');
      late final ({String kind, int code, String? faceId}) parsed;
      try {
        parsed = A9u.parse(resultPayload.$2);
      } on FormatException catch (error) {
        throw _InvalidDeviceResponse(error.message);
      }
      if (parsed.kind != 'installResult' ||
          (parsed.code != 2 && parsed.code != 3))
        throw _DeviceFailure('设备拒绝表盘安装，状态=${parsed.code}。');
      if (parsed.faceId != request.metadata.faceId) {
        throw _InvalidDeviceResponse('表盘完成事件与当前任务 faceId 不匹配。');
      }
      await _requestBusiness(
          Zau(
              command: ZauCommand.setFace,
              sub: 1,
              payload: A9u.withFaceId(request.metadata.faceId!)),
          ZauCommand.setFace,
          1);
      await _clearCheckpoint();
      _publish(request, InstallStage.succeeded, '表盘已安装并已请求切换。',
          successVerifiedByDeviceBusinessEvent: true);
    } else {
      final resultPayload = result.payload;
      if (resultPayload == null)
        throw const _InvalidDeviceResponse('RPK 完成事件缺少载荷。');
      late final ({int code, String packageName}) parsed;
      try {
        parsed = V8s.parseInstallResult(resultPayload.$2);
      } on FormatException catch (error) {
        throw _InvalidDeviceResponse(error.message);
      }
      if (parsed.packageName != request.metadata.packageName ||
          parsed.code != 0)
        throw _DeviceFailure('设备报告 RPK 安装失败，状态=${parsed.code}。');
      await _clearCheckpoint();
      _publish(request, InstallStage.succeeded, '快应用已安装：${parsed.packageName}。',
          successVerifiedByDeviceBusinessEvent: true);
    }
  }

  Future<Uint8List> _readAndVerify(InstallRequest request) async {
    final file = File(request.path);
    if (!await file.exists()) throw StateError('源文件不存在。');
    final bytes = await file.readAsBytes();
    if (bytes.length != request.metadata.fileSize ||
        md5.convert(bytes).toString() != request.metadata.md5Hex ||
        sha256.convert(bytes).toString() != request.metadata.sha256Hex)
      throw StateError('源文件已变化，拒绝使用旧元数据发送。');
    return bytes;
  }

  void _validateRequest(InstallRequest request) {
    if (request.kind == InstallKind.watchface &&
        !RegExp(r'^\d+$').hasMatch(request.metadata.faceId ?? ''))
      throw const FormatException('faceId 必须为数值。');
    if (request.kind == InstallKind.quickApp &&
        (request.metadata.packageName == null ||
            request.metadata.versionCode == null ||
            request.metadata.versionCode! <= 0 ||
            request.metadata.versionCode! > maxRpkVersionCode))
      throw const FormatException('RPK 必须包含有效包名和版本号。');
    final expected = _profile?.watchfaceResolution;
    if (request.kind == InstallKind.watchface &&
        expected != null &&
        request.metadata.watchfaceResolutions.isNotEmpty &&
        !request.metadata.watchfaceResolutions.contains(expected) &&
        !request.watchfaceResolutionConfirmed)
      throw FormatException('表盘分辨率与 ${_profile!.displayName} 不匹配。');
    if (_profile?.family == DeviceFamily.redmiWatch5 &&
        request.metadata.containsLua &&
        !request.unsupportedLuaConfirmed)
      throw const FormatException('REDMI Watch 5 的 Lua 表盘必须明确确认。');
  }

  Future<Zau> _requestBusiness(Zau message, int command, int sub) async {
    final waiter = _BusinessWaiter(
        _business.stream, (item) => item.command == command && item.sub == sub);
    try {
      await _sendBusiness(message);
      return await _withCancellation(
          waiter.future.timeout(const Duration(seconds: 12)));
    } finally {
      await waiter.cancel();
    }
  }

  _BusinessWaiter _listenBusiness(int command, int sub) {
    final waiter = _BusinessWaiter(
        _business.stream, (item) => item.command == command && item.sub == sub);
    _completionWaiters.add(waiter);
    return waiter;
  }

  _BusinessWaiter _listenQuickAppResult(String packageName) {
    final waiter = _BusinessWaiter(_business.stream, (item) {
      if (item.command != ZauCommand.prepareInstallApp ||
          item.sub != 2 ||
          item.payload == null) return false;
      late final ({int code, String packageName}) result;
      try {
        result = V8s.parseInstallResult(item.payload!.$2);
      } on FormatException catch (error) {
        throw _InvalidDeviceResponse('RPK 完成事件格式无效：${error.message}');
      }
      return result.packageName == packageName;
    });
    _completionWaiters.add(waiter);
    return waiter;
  }

  Future<void> _sendBusiness(Zau message) async {
    final cipher = _cipher;
    if (cipher == null) throw StateError('认证会话已失效。');
    await _writeL2(SppProtocol.channelPb, SppProtocol.opCodeWriteEnc,
        cipher.encryptOutbound(message.encode()));
  }

  Future<void> _writeL2(int channel, int opcode, List<int> payload) async {
    final sequence = _nextSequence();
    final ack = _registerAck(
      sequence,
      waitForAck: true,
      mass: channel == SppProtocol.channelMass,
    );
    try {
      await _transport.write(SppProtocol.buildDataFrame(sequence, payload,
          channel: channel, opCode: opcode));
      await _withCancellation(ack.future!.timeout(_ackTimeout));
    } finally {
      _discardAck(ack);
    }
  }

  Future<void> _queueMassWindow(
      List<MassSegment> segments,
      InstallRequest request,
      Map<int, int> confirmedBytes,
      int totalBytes) async {
    final frames = <int>[];
    final waiting = <Future<void>>[];
    final queuedAcks = <_PendingAck>[];
    // Reserve the whole window before registering or writing any frame.
    // Exhaustion must not leave a partially allocated Mass window.
    final sequences = _sequenceAllocator.reserve(segments.length);
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      final sequence = sequences[index];
      final ack = _registerAck(sequence, waitForAck: true, mass: true);
      queuedAcks.add(ack);
      _massProgress[ack] = _Progress(
          request,
          segment.index,
          segment.total,
          confirmedBytes[segment.index]!,
          segments.last.index,
          confirmedBytes[segments.last.index]!,
          totalBytes);
      waiting.add(ack.future!);
      frames.addAll(SppProtocol.buildDataFrame(sequence, segment.data,
          channel: SppProtocol.channelMass, opCode: SppProtocol.opCodeWrite));
    }
    try {
      await _transport.write(frames);
      await _withCancellation(waitForMassAcknowledgements(waiting,
          idleTimeout: _ackTimeout,
          timeoutMessage: (done, total) =>
              'Mass ACK 空闲超时：已确认 $done/$total 片。'));
    } finally {
      for (final ack in queuedAcks) {
        _discardAck(ack);
      }
    }
  }

  void _onInput(Uint8List data) {
    if (data.isEmpty) return _onTransportClosed();
    _accumulator.buffer = [..._accumulator.buffer, ...data];
    for (final packet in SppProtocol.parse(_accumulator)) {
      final attribution = _FrameAttribution(
        epoch: _sessionEpoch,
        generation: _transportGeneration,
      );
      _orderedPacketHandling = _orderedPacketHandling.then((_) async {
        if (!_attributionIsCurrent(attribution)) {
          _log('忽略来自旧连接代际的 SPP 帧。');
          return;
        }
        await _handlePacket(packet, attribution);
      }).catchError((Object error, StackTrace stack) {
        if (_attributionIsCurrent(attribution)) {
          _rejectHandshake('处理 SPP 握手帧失败：$error');
        }
      });
    }
  }

  Future<void> _handlePacket(
    SppPacket packet,
    _FrameAttribution attribution,
  ) async {
    if (_connection == TuiProtocolConnectionState.disconnected ||
        _handshake == _HandshakePhase.none ||
        !_attributionIsCurrent(attribution)) {
      _log('忽略失效连接的握手帧。');
      return;
    }
    if (packet.type == SppProtocol.typeCmd &&
        packet.payload.isNotEmpty &&
        packet.payload.first == SppProtocol.cmdL1StartRsp) {
      if (_handshake != _HandshakePhase.l1StartSent) {
        _rejectHandshake('拒绝无归属、过期或重复的 L1START 响应。');
        return;
      }
      final L1StartConfiguration configuration;
      try {
        configuration = SppProtocol.parseL1StartResponse(packet.payload);
      } on FormatException {
        _rejectHandshake('拒绝格式错误的 L1START 配置响应。');
        return;
      }
      if (_resumeAuthenticatedSession && _cipher != null) {
        _setHandshakePhase(_HandshakePhase.ready);
        _resumeAuthenticatedSession = false;
        _recoveringPostAuthClose = false;
        _authenticatedAt = null;
        _connection = TuiProtocolConnectionState.ready;
        _watchdog?.cancel();
        _journalEvent(
          event: 'protocol.l1start.accepted',
          category: DiagnosticCategory.framing,
          message: 'L1START response accepted.',
          stage: 'l1start.response',
          fields: _l1StartResponseFields(configuration, resumed: true),
        );
        _journalReady(resumed: true);
        _emit('RFCOMM 传输已恢复，继续使用已确认的会话密钥。');
      } else if (_authKey == null) {
        _setHandshakePhase(_HandshakePhase.awaitingAuthKey);
        _connection = TuiProtocolConnectionState.awaitingAuthKey;
        _watchdog?.cancel();
        _journalEvent(
          event: 'protocol.l1start.accepted',
          category: DiagnosticCategory.framing,
          message: 'L1START response accepted.',
          stage: 'l1start.response',
          fields: _l1StartResponseFields(configuration, resumed: false),
        );
        _emit('L1 会话已建立，请输入 authkey 继续鉴权。');
      } else {
        _setHandshakePhase(_HandshakePhase.f26Sent);
        _connection = TuiProtocolConnectionState.authenticating;
        _journalEvent(
          event: 'protocol.l1start.accepted',
          category: DiagnosticCategory.framing,
          message: 'L1START response accepted.',
          stage: 'l1start.response',
          fields: _l1StartResponseFields(configuration, resumed: false),
        );
        _runHandshakeStep(
          (epoch, token) =>
              _sendAuthStep1(expectedEpoch: epoch, expectedPhaseToken: token),
          '发送 f=26',
        );
      }
      return;
    }
    if (packet.type == SppProtocol.typeData) {
      if (packet.payload.length < 2) {
        _rejectHandshake('拒绝缺少 L2 channel/opcode 的 DATA 帧。');
        return;
      }
      final channel = packet.payload[0] & 0x0f;
      final opcode = packet.payload[1];
      if (!_acceptDataFrame(channel, opcode, packet.payload.sublist(2))) return;
      await _writeOrdered(
        SppProtocol.buildAck(packet.seq),
        attribution.generation,
        expectedEpoch: attribution.epoch,
      );
      if (!_attributionIsCurrent(attribution)) return;
      await _handleData(packet.payload, attribution);
      return;
    }
    if (packet.type == SppProtocol.typeAck) {
      if (_connection == TuiProtocolConnectionState.disconnected) {
        _log('忽略已失效会话的 SPP ACK（seq=${packet.seq}）。');
        return;
      }
      final epoch = _sessionEpoch;
      final index = _massAckOrder.indexWhere(
          (ack) => ack.epoch == epoch && ack.sequence == packet.seq);
      if (index >= 0) {
        final confirmed = _massAckOrder.sublist(0, index + 1);
        _Progress? progress;
        for (final ack in confirmed) {
          progress = _massProgress[ack] ?? progress;
          _discardAck(ack, acknowledged: true);
          ack.complete();
        }
        if (progress != null) {
          _updateSpeed(progress.confirmedBytes);
          _publish(progress.request, InstallStage.transferring,
              '设备已确认第 ${progress.segmentIndex}/${progress.totalSegments} 片。',
              currentSegment: progress.segmentIndex,
              totalSegments: progress.totalSegments,
              confirmedBytes: progress.confirmedBytes,
              queuedSegment: progress.queuedSegment,
              queuedBytes: progress.queuedBytes,
              totalBytes: progress.totalBytes,
              bytesPerSecond: _bytesPerSecond);
        }
      } else {
        final ack = _acks[packet.seq];
        if (ack != null && ack.epoch == epoch) {
          _discardAck(ack, acknowledged: true);
          ack.complete();
        } else if (_sequenceAllocator.isUsed(packet.seq)) {
          _log('忽略当前 RFCOMM 代际中已退役的 SPP ACK（seq=${packet.seq}）。');
        } else {
          _invalidateTransportSession(
            StateError('收到不属于当前连接的 SPP ACK（seq=${packet.seq}）。'),
          );
        }
      }
    }
  }

  Future<void> _handleData(
    List<int> payload,
    _FrameAttribution attribution,
  ) async {
    final channel = payload[0] & 0x0f;
    final opcode = payload[1];
    final data = payload.sublist(2);
    if (channel == SppProtocol.channelPb &&
        opcode == SppProtocol.opCodeWriteEnc) {
      final cipher = _cipher;
      if (cipher == null) return;
      Zau? business;
      try {
        business = Zau.tryParse(cipher.decryptInbound(data));
      } on Object catch (error) {
        _handleInvalidEncryptedResponse(error);
        return;
      }
      if (business != null && business.command != XiaomiAuth.commandType)
        _business.add(business);
      return;
    }
    final auth = XiaomiAuth.parse(data);
    if (_handshake == _HandshakePhase.f26Sent &&
        auth?.type == XiaomiAuth.commandType &&
        auth?.subtype == XiaomiAuth.cmdNonce &&
        auth?.watchNonce != null &&
        auth!.watchNonce!.isNotEmpty &&
        auth.watchHmac != null &&
        auth.watchHmac!.isNotEmpty &&
        _phoneNonce != null) {
      final phaseToken = _setHandshakePhase(_HandshakePhase.f27Sent);
      _journalEvent(
        event: 'auth.f26.response_received',
        category: DiagnosticCategory.auth,
        message: 'WearAuthV2 f=26 response accepted.',
        stage: 'f26.response',
      );
      await _sendAuthConfirm(
        auth.watchNonce!,
        auth.watchHmac!,
        expectedEpoch: attribution.epoch,
        expectedPhaseToken: phaseToken,
      );
      return;
    }
    if (_handshake == _HandshakePhase.f27Sent &&
        auth?.type == XiaomiAuth.commandType &&
        auth?.subtype == XiaomiAuth.cmdAuth &&
        auth?.authStatus == 1) {
      final keys = _pendingKeys;
      if (keys == null) {
        _rejectHandshake('拒绝没有当前 f=27 派生密钥的鉴权确认。');
        return;
      }
      _cipher = SessionCipher(keys);
      _setHandshakePhase(_HandshakePhase.ready);
      _pendingKeys = null;
      _wipeBytes(_phoneNonce);
      _phoneNonce = null;
      _retireOptionalAcks(_sessionEpoch);
      _connection = TuiProtocolConnectionState.ready;
      _armPostAuthTransition();
      _watchdog?.cancel();
      _journalEvent(
        event: 'auth.success',
        category: DiagnosticCategory.auth,
        message: 'WearAuthV2 authentication succeeded.',
        stage: 'f27.confirmed',
        fields: const <String, Object?>{'result': 'success'},
      );
      _journalReady(resumed: false);
      _emit('鉴权完成，设备就绪。');
      return;
    }
    _rejectHandshake('拒绝与当前握手阶段不匹配的 channel/opcode/auth 帧。');
  }

  bool _acceptDataFrame(int channel, int opcode, List<int> data) {
    if (_handshake == _HandshakePhase.ready) {
      if (channel == SppProtocol.channelPb &&
          opcode == SppProtocol.opCodeWriteEnc) {
        return true;
      }
      _rejectHandshake('拒绝 ready 会话中的错误 channel/opcode DATA 帧。');
      return false;
    }
    if (_handshake != _HandshakePhase.f26Sent &&
        _handshake != _HandshakePhase.f27Sent) {
      _rejectHandshake('拒绝当前阶段未请求的鉴权 DATA 帧。');
      return false;
    }
    if (channel != SppProtocol.channelPb || opcode != SppProtocol.opCodeWrite) {
      _rejectHandshake('拒绝鉴权阶段的错误 channel/opcode DATA 帧。');
      return false;
    }
    final auth = XiaomiAuth.parse(data);
    final validF26 = _handshake == _HandshakePhase.f26Sent &&
        auth?.type == XiaomiAuth.commandType &&
        auth?.subtype == XiaomiAuth.cmdNonce &&
        auth?.watchNonce != null &&
        auth!.watchNonce!.isNotEmpty &&
        auth.watchHmac != null &&
        auth.watchHmac!.isNotEmpty &&
        _phoneNonce != null;
    final validF27 = _handshake == _HandshakePhase.f27Sent &&
        auth?.type == XiaomiAuth.commandType &&
        auth?.subtype == XiaomiAuth.cmdAuth &&
        auth?.authStatus == 1 &&
        _pendingKeys != null;
    if (validF26 || validF27) return true;
    _rejectHandshake('拒绝无归属、过期、重复或 opcode 不匹配的鉴权帧。');
    return false;
  }

  bool _attributionIsCurrent(_FrameAttribution attribution) =>
      !_disposed &&
      attribution.epoch == _sessionEpoch &&
      attribution.generation == _transportGeneration;

  Future<void> _writeOrdered(
    List<int> bytes,
    int generation, {
    int? expectedEpoch,
  }) {
    final result = Completer<void>();
    _orderedWrite = _orderedWrite.catchError((Object _) {}).then((_) async {
      if (_disposed ||
          generation != _transportGeneration ||
          (expectedEpoch != null && expectedEpoch != _sessionEpoch)) {
        throw const _StaleHandshakeOperation();
      }
      await _transport.write(bytes);
    });
    _orderedWrite.then(
      (_) => result.complete(),
      onError: (Object error, StackTrace stack) =>
          result.completeError(error, stack),
    );
    return result.future;
  }

  void _rejectHandshake(String message) {
    if (_connection == TuiProtocolConnectionState.disconnected) {
      _log(message);
      return;
    }
    final failure = _InvalidDeviceResponse(message);
    _journalAuthFailure('invalid_handshake_frame');
    _invalidateTransportSession(failure);
    _emit('$message 会话已失效。');
  }

  Future<void> _sendAuthStep1({
    required int expectedEpoch,
    required int expectedPhaseToken,
  }) async {
    if (_disposed ||
        expectedEpoch != _sessionEpoch ||
        expectedPhaseToken != _handshakePhaseToken) return;
    final binding = _sessionBinding;
    final nonce = List<int>.generate(16, (_) => _random.nextInt(256));
    _phoneNonce = nonce;
    final sequence = _nextSequence();
    final ack = _registerAck(sequence);
    try {
      await _writeOrdered(
          SppProtocol.buildDataFrame(
              sequence,
              XiaomiAuth.buildNonceCommand(
                nonce,
                appDeviceId: binding?.appDeviceId,
                hasOob: binding?.hasOob ?? false,
              )),
          _transportGeneration,
          expectedEpoch: expectedEpoch);
    } on Object {
      _discardAck(ack);
      rethrow;
    }
    if (_disposed ||
        expectedEpoch != _sessionEpoch ||
        expectedPhaseToken != _handshakePhaseToken) return;
    _journalEvent(
      event: 'auth.f26.sent',
      category: DiagnosticCategory.auth,
      message: 'WearAuthV2 f=26 request sent.',
      stage: 'f26.sent',
      fields: <String, Object?>{
        'sequence': sequence,
        'bindingMaterial': binding == null ? 'absent' : 'provided',
      },
    );
    _armWatchdog('15 秒内未收到设备 nonce。', expectedPhaseToken: expectedPhaseToken);
  }

  Future<void> _sendAuthConfirm(List<int> watchNonce, List<int> watchHmac,
      {required int expectedEpoch, required int expectedPhaseToken}) async {
    if (_disposed ||
        expectedEpoch != _sessionEpoch ||
        expectedPhaseToken != _handshakePhaseToken) return;
    _retireOptionalAcks(expectedEpoch);
    final secret = XiaomiAuth.secretKeyFromHex(_authKey ?? '');
    if (secret == null) throw StateError('authkey 无效。');
    final phoneNonce = _phoneNonce;
    if (phoneNonce == null) throw StateError('鉴权响应缺少本地 nonce。');
    String phoneModel;
    try {
      final hostname = Platform.localHostname.trim();
      phoneModel = hostname.isEmpty
          ? 'macOS'
          : hostname.substring(0, min(64, hostname.length));
    } on Object {
      phoneModel = 'macOS';
    }
    final command = XiaomiAuth.buildAuthStep3Command(
        secretKey: secret,
        phoneNonce: phoneNonce,
        watchNonce: watchNonce,
        watchHmac: watchHmac,
        phoneModel: phoneModel,
        oob: _sessionBinding?.oob);
    if (command == null) {
      _rejectDeviceSignatureMismatch(
        expectedEpoch: expectedEpoch,
        expectedPhaseToken: expectedPhaseToken,
      );
      return;
    }
    final pendingKeys = SessionKeys.fromHkdf(
      XiaomiAuth.computeStep3Hmac(secret, phoneNonce, watchNonce),
    );
    if (_disposed ||
        expectedEpoch != _sessionEpoch ||
        expectedPhaseToken != _handshakePhaseToken) return;
    _pendingKeys = pendingKeys;
    final sequence = _nextSequence();
    final ack = _registerAck(sequence);
    try {
      await _writeOrdered(
          SppProtocol.buildDataFrame(sequence, command), _transportGeneration,
          expectedEpoch: expectedEpoch);
    } on Object {
      _discardAck(ack);
      rethrow;
    }
    if (_disposed ||
        expectedEpoch != _sessionEpoch ||
        expectedPhaseToken != _handshakePhaseToken) {
      if (identical(_pendingKeys, pendingKeys)) _clearPendingKeys();
      return;
    }
    _journalEvent(
      event: 'auth.f27.sent',
      category: DiagnosticCategory.auth,
      message: 'WearAuthV2 f=27 request sent.',
      stage: 'f27.sent',
      fields: <String, Object?>{'sequence': sequence},
    );
    _armWatchdog('15 秒内未收到 f=27 鉴权确认。', expectedPhaseToken: expectedPhaseToken);
  }

  void _rejectDeviceSignatureMismatch({
    required int expectedEpoch,
    required int expectedPhaseToken,
  }) {
    if (_disposed ||
        expectedEpoch != _sessionEpoch ||
        expectedPhaseToken != _handshakePhaseToken) {
      return;
    }
    _failureCode = deviceSignatureMismatchFailureCode;
    _journalAuthFailure(
      deviceSignatureMismatchFailureCode,
      stage: 'f26.response',
    );
    _invalidateTransportSession(const _DeviceSignatureMismatch());
    _emit('设备签名校验失败；未发送 f=27，会话已关闭。');
  }

  Future<T> _withCancellation<T>(Future<T> future) {
    final cancel = _cancelSignal;
    final failure = _transportFailure;
    if (cancel == null || failure == null) return future;
    return Future.any([
      future,
      cancel.future.then<T>((_) => throw const _Cancelled()),
      failure.future.then<T>((error) => throw error)
    ]);
  }

  Future<void> _waitForReady() async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!sessionReady && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!sessionReady) throw TimeoutException('SPP 鉴权恢复超时。');
  }

  void _runHandshakeStep(
    Future<void> Function(int epoch, int phaseToken) action,
    String description,
  ) {
    final epoch = _sessionEpoch;
    final phaseToken = _handshakePhaseToken;
    unawaited(() async {
      try {
        await action(epoch, phaseToken);
        if (_disposed ||
            epoch != _sessionEpoch ||
            phaseToken != _handshakePhaseToken) return;
      } on Object catch (error) {
        if (_disposed ||
            epoch != _sessionEpoch ||
            phaseToken != _handshakePhaseToken) return;
        if (error is SppSequenceSpaceExhausted) {
          _journalAuthFailure('sequence_space_exhausted');
          _failureCode = sppSequenceSpaceExhaustedFailureCode;
          _invalidateTransportSession(error);
          _emit('$description 失败：${error.userMessage}');
        } else {
          _journalAuthFailure('handshake_write_failed');
          _invalidateSession();
          _failPending(error);
          _emit('$description 失败，会话已失效：$error');
          try {
            await _transport.disconnect();
          } on Object {
            // The failed write may already have closed the native channel.
          }
        }
      }
    }());
  }

  Future<void> _recoverPostAuthRfcomm(
    TuiTransportDevice device,
    int epoch,
  ) async {
    try {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (_disposed || epoch != _sessionEpoch || !_resumeAuthenticatedSession) {
        return;
      }
      _accumulator = Accumulator();
      final generation = ++_transportGeneration;
      final connectingToken = _setHandshakePhase(_HandshakePhase.connecting);
      _journalEvent(
        event: 'session.retry',
        category: DiagnosticCategory.session,
        message: 'Post-authentication RFCOMM recovery requested.',
        stage: 'post_auth_reconnect',
        retry: _postAuthReconnectAttempts,
      );
      final reconnect = _postAuthReconnect;
      if (reconnect != null) {
        await reconnect(device);
      } else {
        await _transport.connect(device);
      }
      if (_disposed ||
          epoch != _sessionEpoch ||
          connectingToken != _handshakePhaseToken) return;
      // This is a new physical RFCOMM generation after the post-auth close.
      // Only now may sequence numbers start at zero again.
      _sequenceAllocator = SppSequenceAllocator();
      final phaseToken = _setHandshakePhase(_HandshakePhase.l1StartSent);
      _failureCode = null;
      await _writeOrdered(SppProtocol.buildL1StartRequest(), generation,
          expectedEpoch: epoch);
      _journalL1StartSent(resumed: true);
      _armWatchdog('15 秒内未收到恢复链路的 L1START 响应。', expectedPhaseToken: phaseToken);
    } on Object catch (error) {
      if (epoch != _sessionEpoch || _disposed) return;
      _recoveringPostAuthClose = false;
      _invalidateSession();
      _failPending(error);
      _emit('f=27 后的 RFCOMM 链路重建失败：$error');
    }
  }

  Future<void> _saveCheckpoint(
          InstallRequest request, int dataType, int segment, String phase) =>
      _checkpointStore.save(InstallCheckpoint(
          kind: request.kind,
          path: request.path,
          fileSize: request.metadata.fileSize,
          md5Hex: request.metadata.md5Hex,
          sha256Hex: request.metadata.sha256Hex,
          dataType: dataType,
          lastAcknowledgedSegment: segment,
          phase: phase,
          faceId: request.metadata.faceId,
          packageName: request.metadata.packageName,
          versionCode: request.metadata.versionCode));
  Future<void> _clearCheckpoint() async {
    try {
      await _checkpointStore.clear();
    } on Object catch (error) {
      _log('检查点清理失败：$error');
    }
  }

  void _checkCancelled() {
    if (_cancelled) throw const _Cancelled();
  }

  int _nextSequence() => _sequenceAllocator.allocate();

  _PendingAck _registerAck(
    int sequence, {
    bool waitForAck = false,
    bool mass = false,
  }) {
    final existing = _acks[sequence];
    if (existing != null || !_sequenceAllocator.isActive(sequence)) {
      throw StateError('SPP 序号 $sequence 的本地生命周期不一致。');
    }
    final ack = _PendingAck(
      epoch: _sessionEpoch,
      sequence: sequence,
      completer: waitForAck ? Completer<void>() : null,
    );
    _acks[sequence] = ack;
    if (mass) _massAckOrder.add(ack);
    return ack;
  }

  void _removeAckFromMap(_PendingAck ack) {
    if (identical(_acks[ack.sequence], ack)) {
      _acks.remove(ack.sequence);
    }
  }

  void _discardAck(_PendingAck ack, {bool acknowledged = false}) {
    final owned = identical(_acks[ack.sequence], ack) ||
        _massAckOrder.contains(ack) ||
        _massProgress.containsKey(ack);
    if (!owned) return;
    _removeAckFromMap(ack);
    _massAckOrder.remove(ack);
    _massProgress.remove(ack);
    if (acknowledged) {
      _sequenceAllocator.acknowledge(ack.sequence);
    } else {
      _sequenceAllocator.quarantine(ack.sequence);
    }
  }

  void _retireOptionalAcks(int epoch) {
    for (final ack in _acks.values.toList(growable: false)) {
      if (ack.epoch == epoch && !ack.waitForAck) _discardAck(ack);
    }
  }

  List<int> _hex(String value) => [
        for (var i = 0; i < value.length; i += 2)
          int.parse(value.substring(i, i + 2), radix: 16)
      ];
  void _updateSpeed(int bytes) {
    final now = DateTime.now();
    final then = _lastSpeedTime;
    if (then != null) {
      final elapsed = now.difference(then).inMicroseconds;
      if (elapsed > 0 && bytes > _lastSpeedBytes) {
        final current = (bytes - _lastSpeedBytes) *
            Duration.microsecondsPerSecond /
            elapsed;
        _bytesPerSecond = _bytesPerSecond == null
            ? current
            : _bytesPerSecond! * .65 + current * .35;
      }
    }
    _lastSpeedTime = now;
    _lastSpeedBytes = bytes;
  }

  void _armWatchdog(String message, {required int expectedPhaseToken}) {
    _watchdog?.cancel();
    final epoch = _sessionEpoch;
    _watchdog = Timer(_handshakeTimeout, () {
      if (_disposed ||
          sessionReady ||
          epoch != _sessionEpoch ||
          expectedPhaseToken != _handshakePhaseToken) return;
      final timedOutPhase = _handshake.name;
      _journalEvent(
        event: 'watchdog.timeout',
        category: DiagnosticCategory.session,
        severity: DiagnosticSeverity.error,
        message: 'Protocol watchdog timed out.',
        stage: timedOutPhase,
        timeoutMs: _handshakeTimeout.inMilliseconds,
        fields: const <String, Object?>{'result': 'timeout'},
      );
      _journalAuthFailure('watchdog_timeout', stage: timedOutPhase);
      _invalidateSession();
      _failPending(TimeoutException(message));
      _emit(message);
      unawaited(_transport.disconnect().catchError((_) {}));
    });
  }

  int _setHandshakePhase(_HandshakePhase phase) {
    final previous = _handshake;
    _handshake = phase;
    if (previous != phase) {
      _journalEvent(
        event: 'session.transition',
        category: DiagnosticCategory.session,
        message: 'Protocol session phase changed.',
        stage: phase.name,
        fields: <String, Object?>{
          'from': previous.name,
          'to': phase.name,
        },
      );
    }
    return ++_handshakePhaseToken;
  }

  void _onTransportError(Object error, [StackTrace? stack]) {
    if (_disposed) return;
    if (_connection == TuiProtocolConnectionState.disconnected) {
      _emit('macOS Bluetooth helper 报告错误：$error');
      return;
    }
    final request = _lastRequest;
    final wasInstalling = _installing;
    _invalidateTransportSession(error);
    if (wasInstalling && request != null) {
      _publish(request, InstallStage.stateUnknown, '蓝牙传输失败，设备状态未知：$error');
    } else {
      _emit('macOS Bluetooth helper 报告错误，会话已失效：$error');
    }
  }

  void _onTransportClosed() {
    if (_disposed ||
        _explicitDisconnect ||
        _connection == TuiProtocolConnectionState.disconnected) {
      return;
    }
    final device = _device;
    final isPostAuthTransition = device != null &&
        _cipher != null &&
        _postAuthTransitionDeadline != null &&
        DateTime.now().isBefore(_postAuthTransitionDeadline!) &&
        _postAuthReconnectAttempts == 0 &&
        !_recoveringPostAuthClose &&
        !_installing;
    if (isPostAuthTransition) {
      _postAuthReconnectAttempts++;
      _recoveringPostAuthClose = true;
      _resumeAuthenticatedSession = true;
      _connection = TuiProtocolConnectionState.connecting;
      _setHandshakePhase(_HandshakePhase.connecting);
      ++_transportGeneration;
      _failPending(StateError('RFCOMM 正在切换到鉴权后的新连接。'));
      final epoch = ++_sessionEpoch;
      _emit('检测到 f=27 后的传输切换，正在重建持久 RFCOMM 链路。');
      unawaited(_recoverPostAuthRfcomm(device, epoch));
      return;
    }
    _invalidateSession();
    _failPending(StateError('RFCOMM 远端已关闭'));
    _emit('RFCOMM 已关闭，会话已失效。');
  }

  void _handleInvalidEncryptedResponse(Object error) {
    final failure = _InvalidDeviceResponse('加密业务响应无法处理：$error');
    _invalidateTransportSession(failure);
    final request = _lastRequest;
    if (_installing && request != null) {
      _publish(request, InstallStage.stateUnknown, '设备加密响应无法验证，状态未知：$error');
    } else {
      _emit('设备加密响应无法处理，会话已失效：$error');
    }
  }

  void _invalidateSession({bool clearBinding = false}) {
    ++_sessionEpoch;
    ++_transportGeneration;
    _setHandshakePhase(_HandshakePhase.none);
    _watchdog?.cancel();
    _watchdog = null;
    // Keep the exact optional material only for an in-memory retry of this
    // logical device attempt. Explicit disconnect, new connect, clear-key,
    // and dispose paths clear it. Never synthesize a replacement.
    _clearSensitiveSessionMaterial(clearBinding: clearBinding);
    _resumeAuthenticatedSession = false;
    _recoveringPostAuthClose = false;
    _connection = TuiProtocolConnectionState.disconnected;
  }

  void _clearSensitiveSessionMaterial({
    bool clearAuthKey = false,
    bool clearBinding = true,
  }) {
    if (clearAuthKey) _authKey = null;
    if (clearBinding) _sessionBinding = null;
    _wipeBytes(_phoneNonce);
    _phoneNonce = null;
    _clearPendingKeys();
    final cipher = _cipher;
    if (cipher != null) _wipeSessionKeys(cipher.keys);
    _cipher = null;
    _clearPostAuthTransition();
  }

  void _armPostAuthTransition() {
    _clearPostAuthTransition();
    _postAuthTransitionDeadline =
        DateTime.now().add(const Duration(seconds: 10));
    _postAuthTransitionTimer = Timer(const Duration(seconds: 10), () {
      _postAuthTransitionDeadline = null;
      _postAuthTransitionTimer = null;
    });
  }

  void _clearPostAuthTransition() {
    _postAuthTransitionTimer?.cancel();
    _postAuthTransitionTimer = null;
    _postAuthTransitionDeadline = null;
  }

  void _invalidateTransportSession(Object error) {
    _invalidateSession();
    _failPending(error);
    unawaited(_transport.disconnect().catchError((_) {}));
  }

  void _clearPendingKeys() {
    final keys = _pendingKeys;
    if (keys != null) _wipeSessionKeys(keys);
    _pendingKeys = null;
  }

  void _wipeSessionKeys(SessionKeys keys) {
    _wipeBytes(keys.deviceKey);
    _wipeBytes(keys.appKey);
    _wipeBytes(keys.deviceIv);
    _wipeBytes(keys.appIv);
  }

  void _wipeBytes(List<int>? bytes) {
    if (bytes != null) bytes.fillRange(0, bytes.length, 0);
  }

  void _failPending(Object error) {
    for (final ack in _acks.values.toList(growable: false)) {
      ack.completeError(error);
      _discardAck(ack);
    }
    if (!(_transportFailure?.isCompleted ?? true))
      _transportFailure!.complete(error);
  }

  void _publish(InstallRequest request, InstallStage stage, String message,
      {int? currentSegment,
      int? totalSegments,
      int? confirmedBytes,
      int? queuedSegment,
      int? queuedBytes,
      int? totalBytes,
      double? bytesPerSecond,
      bool successVerifiedByDeviceBusinessEvent = false}) {
    _latestTask = InstallTask(
        kind: request.kind,
        fileName: request.metadata.fileName,
        stage: stage,
        message: message,
        targetDeviceName: _device?.name ?? _profile?.displayName,
        md5Hex: request.metadata.md5Hex,
        faceId: request.metadata.faceId,
        packageName: request.metadata.packageName,
        versionCode: request.metadata.versionCode,
        currentSegment: currentSegment,
        totalSegments: totalSegments,
        confirmedBytes: confirmedBytes,
        queuedSegment: queuedSegment,
        queuedBytes: queuedBytes,
        totalBytes: totalBytes,
        bytesPerSecond: bytesPerSecond,
        successVerifiedByDeviceBusinessEvent:
            successVerifiedByDeviceBusinessEvent);
    _journalInstallStage(
      request,
      stage,
      currentSegment: currentSegment,
      totalSegments: totalSegments,
      confirmedBytes: confirmedBytes,
      queuedBytes: queuedBytes,
      totalBytes: totalBytes,
      successVerifiedByDeviceBusinessEvent:
          successVerifiedByDeviceBusinessEvent,
    );
    _emit(message);
  }

  void _journalL1StartSent({required bool resumed}) {
    _journalEvent(
      event: 'protocol.l1start.sent',
      category: DiagnosticCategory.framing,
      message: 'L1START request sent.',
      stage: 'l1start.sent',
      fields: <String, Object?>{'resumed': resumed},
    );
  }

  Map<String, Object?> _l1StartResponseFields(
    L1StartConfiguration configuration, {
    required bool resumed,
  }) =>
      <String, Object?>{
        'resumed': resumed,
        'configTlvCount': configuration.tlvCount,
        'unknownConfigTlvCount': configuration.unknownTlvCount,
        if (configuration.version != null)
          'remoteVersion': configuration.version,
        if (configuration.remoteMps != null)
          'remoteMps': configuration.remoteMps,
        if (configuration.remoteTxWindow != null)
          'remoteTxWindow': configuration.remoteTxWindow,
        if (configuration.remoteSendTimeoutMs != null)
          'remoteSendTimeoutMs': configuration.remoteSendTimeoutMs,
      };

  void _journalReady({required bool resumed}) {
    _journalEvent(
      event: 'session.ready',
      category: DiagnosticCategory.session,
      message: 'Protocol session is ready.',
      stage: 'ready',
      fields: <String, Object?>{
        'result': 'ready',
        'resumed': resumed,
      },
    );
  }

  void _journalAuthFailure(String reason, {String? stage}) {
    _journalEvent(
      event: 'auth.failure',
      category: DiagnosticCategory.auth,
      severity: DiagnosticSeverity.error,
      message: 'WearAuthV2 authentication failed.',
      stage: stage ?? _handshake.name,
      fields: <String, Object?>{
        'result': 'failure',
        'reason': reason,
      },
    );
  }

  void _journalInstallStage(
    InstallRequest request,
    InstallStage stage, {
    int? currentSegment,
    int? totalSegments,
    int? confirmedBytes,
    int? queuedBytes,
    int? totalBytes,
    required bool successVerifiedByDeviceBusinessEvent,
  }) {
    final event = switch (stage) {
      InstallStage.idle => 'install.idle',
      InstallStage.validating => 'install.started',
      InstallStage.waitingForProtocol => 'install.deferred',
      InstallStage.transferring => 'install.progress',
      InstallStage.awaitingDevice => 'install.awaiting_device',
      InstallStage.succeeded => 'install.succeeded',
      InstallStage.cancelled => 'install.cancelled',
      InstallStage.stateUnknown => 'install.state_unknown',
      InstallStage.failed => 'install.failed',
    };
    final severity = switch (stage) {
      InstallStage.cancelled ||
      InstallStage.stateUnknown =>
        DiagnosticSeverity.warning,
      InstallStage.failed => DiagnosticSeverity.error,
      _ => DiagnosticSeverity.info,
    };
    _journalEvent(
      event: event,
      category: DiagnosticCategory.install,
      severity: severity,
      message: 'Installation entered ${stage.name}.',
      stage: stage.name,
      fields: <String, Object?>{
        'kind': request.kind.name,
        if (currentSegment != null) 'currentSegment': currentSegment,
        if (totalSegments != null) 'totalSegments': totalSegments,
        if (confirmedBytes != null) 'confirmedBytes': confirmedBytes,
        if (queuedBytes != null) 'queuedBytes': queuedBytes,
        if (totalBytes != null) 'totalBytes': totalBytes,
        'deviceBusinessEventVerified': successVerifiedByDeviceBusinessEvent,
      },
    );
  }

  void _journalEvent({
    required String event,
    required DiagnosticCategory category,
    required String message,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
    String? stage,
    int? timeoutMs,
    int? retry,
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    final journal = _diagnosticJournal;
    if (journal == null) return;
    final transport = _transport.snapshot;
    final diagnostic = DiagnosticEvent(
      timestamp: DateTime.now().toUtc(),
      severity: severity,
      category: category,
      component: 'wristload.TuiProtocolBackend',
      event: event,
      message: message,
      deviceId: transport.addressKey ?? _device?.addressKey,
      sessionId: transport.activeSessionId,
      connectionId: transport.connectionId,
      generation: transport.connectionGeneration ?? _transportGeneration,
      transport: transport.transport,
      endpoint: transport.endpoint,
      serviceUuid: transport.serviceUuid,
      channel: transport.channel,
      stage: stage,
      timeoutMs: timeoutMs,
      retry: retry,
      fields: <String, Object?>{
        'sessionEpoch': _sessionEpoch,
        'transportGeneration': _transportGeneration,
        ...fields,
      },
    );
    final next = _journalTail.then<void>(
      (_) => journal.append(diagnostic),
      onError: (_) => journal.append(diagnostic),
    );
    _journalTail = next.then<void>((_) {}, onError: (_) {});
  }

  void _log(String message) {
    _logs.add('[${DateTime.now().toIso8601String()}] $message');
    if (_logs.length > 500) _logs.removeRange(0, _logs.length - 500);
  }

  void _emit(String? message) {
    if (_disposed) return;
    _message = message;
    if (message != null) _log(message);
    if (!_snapshots.isClosed) _snapshots.add(_makeSnapshot());
  }

  TuiProtocolSnapshot _makeSnapshot() => TuiProtocolSnapshot(
      connection: _connection,
      device: _device,
      profile: _profile,
      queue: List.unmodifiable(_queue),
      latestTask: _latestTask,
      message: _message,
      failureCode: _failureCode,
      logs: List.unmodifiable(_logs),
      authKeyLoaded: _authKey != null,
      queueRunning: _queueRunning,
      installRunning: _installing,
      segmentIntervalMs: _segmentIntervalMs,
      massWindowSize: _massWindowSize);

  Future<void> dispose() async {
    if (_disposed) return;
    await disconnect();
    _clearSensitiveSessionMaterial(clearAuthKey: true, clearBinding: true);
    _lastRequest = null;
    await _journalTail;
    _disposed = true;
    ++_sessionEpoch;
    await _inputSubscription?.cancel();
    await _errorSubscription?.cancel();
    await _business.close();
    await _snapshots.close();
    await _transport.dispose();
  }
}

enum _HandshakePhase {
  none,
  connecting,
  l1StartSent,
  awaitingAuthKey,
  f26Sent,
  f27Sent,
  ready,
}

final class _FrameAttribution {
  const _FrameAttribution({required this.epoch, required this.generation});

  final int epoch;
  final int generation;
}

final class _StaleHandshakeOperation implements Exception {
  const _StaleHandshakeOperation();
}

class _PendingAck {
  const _PendingAck({
    required this.epoch,
    required this.sequence,
    required this.completer,
  });

  final int epoch;
  final int sequence;
  final Completer<void>? completer;

  bool get waitForAck => completer != null;
  Future<void>? get future => completer?.future;

  void complete() {
    final target = completer;
    if (target != null && !target.isCompleted) target.complete();
  }

  void completeError(Object error) {
    final target = completer;
    if (target != null && !target.isCompleted) target.completeError(error);
  }
}

class _Progress {
  const _Progress(
      this.request,
      this.segmentIndex,
      this.totalSegments,
      this.confirmedBytes,
      this.queuedSegment,
      this.queuedBytes,
      this.totalBytes);
  final InstallRequest request;
  final int segmentIndex;
  final int totalSegments;
  final int confirmedBytes;
  final int queuedSegment;
  final int queuedBytes;
  final int totalBytes;
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _DeviceFailure implements Exception {
  const _DeviceFailure(this.message);
  final String message;
}

class _InvalidDeviceResponse implements Exception {
  const _InvalidDeviceResponse(this.message);
  final String message;
}

class _DeviceSignatureMismatch implements Exception {
  const _DeviceSignatureMismatch();
}

class _BusinessWaiter {
  _BusinessWaiter(Stream<Zau> stream, bool Function(Zau) predicate) {
    _subscription = stream.listen((item) {
      if (_completer.isCompleted) return;
      try {
        if (!predicate(item)) return;
        _completer.complete(item);
        unawaited(_subscription.cancel());
      } on Object catch (error, stack) {
        _completer.completeError(error, stack);
        unawaited(_subscription.cancel());
      }
    }, onError: (Object error, StackTrace stack) {
      if (!_completer.isCompleted) _completer.completeError(error, stack);
    });
  }
  final Completer<Zau> _completer = Completer<Zau>();
  late final StreamSubscription<Zau> _subscription;
  Future<Zau> get future => _completer.future;
  Future<void> cancel() => _subscription.cancel();
}
