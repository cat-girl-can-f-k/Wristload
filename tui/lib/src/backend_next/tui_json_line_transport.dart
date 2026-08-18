library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../diagnostics/diagnostic_journal.dart';
import 'tui_mac_bluetooth_transport.dart';

typedef MacBridgeProcessStarter = Future<Process> Function(String executable);

/// Supervises the macOS IOBluetooth helper and maps protocol-v1 JSON Lines to
/// the transport contract owned by the standalone TUI.
final class TuiJsonLineMacBluetoothTransport
    implements TuiMacBluetoothTransport {
  TuiJsonLineMacBluetoothTransport({
    required this.executablePath,
    MacBridgeProcessStarter? processStarter,
    this.diagnosticJournal,
  }) : _processStarter = processStarter ?? _defaultProcessStarter;

  static const int protocolVersion = 1;
  static const int _maxWriteChunkBytes = 256 * 1024;
  static const Duration _defaultRequestTimeout = Duration(seconds: 15);
  static const Duration _nativeTerminalGrace = Duration(seconds: 1);
  static const Object _snapshotUnset = Object();

  final String executablePath;
  final MacBridgeProcessStarter _processStarter;
  final DiagnosticJournal? diagnosticJournal;
  final StreamController<Uint8List> _input =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<Object> _errors =
      StreamController<Object>.broadcast(sync: true);
  final StreamController<TuiTransportDevice> _discoveries =
      StreamController<TuiTransportDevice>.broadcast(sync: true);
  final StreamController<TuiPairingStage> _pairingStages =
      StreamController<TuiPairingStage>.broadcast(sync: true);
  final StreamController<TuiMacTransportSnapshot> _snapshots =
      StreamController<TuiMacTransportSnapshot>.broadcast(sync: true);
  final Map<String, _PendingRequest> _pending = {};
  final Set<String> _retiredConnectionIds = {};
  final Map<String, Completer<void>> _connectionTerminals = {};
  final Map<String, String> _connectionAddressKeys = {};
  final Map<String, int> _connectionGenerations = {};
  final Map<String, _IdentityCandidateBinding> _identityCandidates = {};
  final Map<String, String> _pairingCandidates = {};

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Future<void>? _starting;
  Future<void> _stdinTail = Future<void>.value();
  Future<void> _writeTail = Future<void>.value();
  Future<void> _journalTail = Future<void>.value();
  TuiMacTransportSnapshot _snapshot = const TuiMacTransportSnapshot.stopped();
  String _stderrTail = '';
  String? _helperSessionId;
  String? _connectionId;
  // Owns every native disconnect/cleanup operation. Replacement connects wait
  // for this future so the helper cannot still own an older connection ID.
  Future<void>? _disconnecting;
  String? _disconnectingConnectionId;
  String? _scanId;
  int _requestCounter = 0;
  int _connectionCounter = 0;
  int _scanCounter = 0;
  int _pairingCounter = 0;
  int _helperEpoch = 0;
  bool _disposing = false;
  bool _disposed = false;

  @override
  Stream<Uint8List> get input => _input.stream;
  @override
  Stream<Object> get errors => _errors.stream;
  @override
  Stream<TuiTransportDevice> get discoveries => _discoveries.stream;
  @override
  Stream<TuiPairingStage> get pairingStages => _pairingStages.stream;
  @override
  Stream<TuiMacTransportSnapshot> get snapshots => _snapshots.stream;
  @override
  TuiMacTransportSnapshot get snapshot => _snapshot;

  static Future<Process> _defaultProcessStarter(String executable) =>
      Process.start(executable, const [], runInShell: false);

  @override
  Future<void> start() {
    if (_disposed) throw StateError('macOS Bluetooth transport 已释放。');
    if (_snapshot.helperState == TuiMacHelperState.ready) {
      return Future<void>.value();
    }
    return _starting ??= _startProcess().whenComplete(() => _starting = null);
  }

  Future<void> _startProcess() async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('Wristload TUI 只支持 macOS。');
    }
    if (executablePath.trim().isEmpty) {
      throw ArgumentError.value(executablePath, 'executablePath', '不能为空');
    }
    _setSnapshot(
      helperState: TuiMacHelperState.starting,
      message: '正在启动 macOS Bluetooth helper。',
    );
    final epoch = ++_helperEpoch;
    try {
      final process = await _processStarter(executablePath);
      if (_disposed || epoch != _helperEpoch) {
        process.kill();
        throw StateError('helper 启动已被取消。');
      }
      _process = process;
      _stderrTail = '';
      _stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) => _handleLine(epoch, line),
            onError: (Object error, StackTrace stack) =>
                _fatalSession(epoch, '读取 helper stdout 失败：$error', stack),
            onDone: () => _handleProcessExit(epoch, null),
          );
      _stderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (epoch != _helperEpoch) return;
        _stderrTail = (_stderrTail + line + '\n');
        if (_stderrTail.length > 4096) {
          _stderrTail = _stderrTail.substring(_stderrTail.length - 4096);
        }
      });
      unawaited(
          process.exitCode.then((code) => _handleProcessExit(epoch, code)));
      final response = await _request(
        'hello',
        const {},
        expectedEvent: 'hello.done',
        ensureStarted: false,
        timeout: const Duration(seconds: 5),
      );
      final version = _asInt(response['protocolVersion']);
      final sessionId = response['helperSessionId'];
      if (version != protocolVersion ||
          sessionId is! String ||
          sessionId.isEmpty) {
        throw TuiTransportProtocolException(
          'helper 协议不兼容：需要 v$protocolVersion，收到 ${version ?? '未知'}。',
        );
      }
      _helperSessionId = sessionId;
      _setSnapshot(
        helperState: TuiMacHelperState.ready,
        message: 'macOS Bluetooth helper 已就绪。',
        helperSessionId: sessionId,
        stage: 'hello.done',
        stageCode: 'ready',
        stageDetail: 'macOS Bluetooth helper 已就绪。',
      );
    } on Object catch (error, stack) {
      if (epoch == _helperEpoch) {
        _fatalSession(epoch, '启动 macOS Bluetooth helper 失败：$error', stack);
      }
      rethrow;
    }
  }

  @override
  Future<List<TuiTransportDevice>> listPairedDevices() async {
    await start();
    final response = await _request(
      'paired.list',
      const {},
      expectedEvent: 'paired.list.done',
    );
    final raw = response['devices'];
    if (raw is! List) {
      throw const TuiTransportProtocolException(
        'paired.list.done 缺少 devices 数组。',
      );
    }
    return [
      for (final item in raw)
        if (item is Map)
          _deviceFromJson(
            Map<String, Object?>.from(item),
            fallbackSource: TuiTransportDeviceSource.paired,
          ),
    ];
  }

  @override
  Future<void> startScan(
      {Duration duration = const Duration(seconds: 10)}) async {
    await start();
    if (duration < const Duration(seconds: 1) ||
        duration > const Duration(seconds: 255)) {
      throw RangeError.range(duration.inSeconds, 1, 255, 'duration');
    }
    final scanId = _newScopedId('s', ++_scanCounter);
    final response = await _request(
      'scan.start',
      {'scanId': scanId, 'duration': duration.inSeconds},
      expectedEvent: 'scan.started',
    );
    if (response['scanId'] != scanId) {
      throw const TuiTransportProtocolException('scan.started 的 scanId 不匹配。');
    }
    _scanId = scanId;
    _setSnapshot(scanning: true, message: '正在扫描经典蓝牙设备。');
  }

  @override
  Future<void> stopScan() async {
    final scanId = _scanId;
    if (scanId == null || !_snapshot.scanning) return;
    await _request(
      'scan.stop',
      {'scanId': scanId},
      expectedEvent: 'scan.stop.done',
    );
    if (_scanId == scanId) {
      _scanId = null;
      _setSnapshot(scanning: false, message: '经典蓝牙扫描已停止。');
    }
  }

  @override
  Future<TuiIdentityResolutionResult> resolveIdentity(
    TuiIdentityCandidate candidate,
  ) async {
    await start();
    _validateCandidateInput(candidate);
    final response = await _request(
      'identity.resolve',
      <String, Object?>{
        'candidateId': candidate.candidateId,
        'advertisedName': candidate.advertisedName,
        if (candidate.directedExactAddress)
          'directedExactAddress': true,
        if (candidate.address != null) 'address': candidate.address,
        if (candidate.addressKey != null) 'addressKey': candidate.addressKey,
      },
      expectedEvent: 'identity.resolve.done',
    );
    _validateCandidateResponse(response, candidate.candidateId);
    final result = _identityResolutionFromJson(response, candidate.candidateId);
    _validateCandidateResult(candidate, result);
    _identityCandidates[candidate.candidateId] =
        _IdentityCandidateBinding.fromCandidate(candidate, result);
    return result;
  }

  @override
  Future<TuiPairingResult> startPairing(
    TuiIdentityCandidate candidate,
  ) async {
    await start();
    _validateCandidateInput(candidate);
    final existing = _identityCandidates[candidate.candidateId];
    if (existing == null) {
      throw const TuiTransportProtocolException(
        'startPairing 必须先完成 identity.resolve。',
      );
    }
    _validateCandidateBinding(candidate, existing);
    final addressKey = existing.addressKey;
    if (addressKey == null || addressKey.isEmpty) {
      throw const TuiTransportProtocolException(
        'identity.resolve 必须返回精确 Classic address 才能配对。',
      );
    }
    final address = TuiBluetoothAddress.parse(addressKey).display;
    final pairingId = _newScopedId('p', ++_pairingCounter);
    _pairingCandidates[pairingId] = candidate.candidateId;
    try {
      final response = await _request(
        'pair.start',
        <String, Object?>{
          'pairingId': pairingId,
          'candidateId': candidate.candidateId,
          'advertisedName': candidate.advertisedName,
          'address': address,
          'addressKey': addressKey,
        },
        expectedEvent: 'pair.done',
        timeout: const Duration(seconds: 120),
      );
      _validatePairingResponse(response, pairingId, candidate.candidateId);
      final device = _deviceFromJson(response,
          fallbackSource: TuiTransportDeviceSource.paired);
      if (device.addressKey != addressKey) {
        throw const TuiTransportProtocolException(
          'pair.done 的 Classic address 与 identity.resolve binding 不匹配。',
        );
      }
      if (!device.paired) {
        throw const TuiTransportProtocolException(
            'pair.done 必须确认 Classic identity 已 paired。');
      }
      final identityState = _identityState(response['identityState']);
      if (identityState == TuiIdentityState.confirmed) {
        throw const TuiTransportProtocolException(
            'pair.done 不得在 Xiaomi authentication 前返回 confirmed identity。');
      }
      _identityCandidates[candidate.candidateId] =
          _IdentityCandidateBinding.fromPairing(candidate, device, response);
      return TuiPairingResult(
        pairingId: pairingId,
        candidateId: candidate.candidateId,
        identityState: identityState,
        device: device,
        matchMode: _string(response['matchMode']),
        generation: _asInt(response['generation']),
      );
    } finally {
      _pairingCandidates.remove(pairingId);
    }
  }

  @override
  Future<void> cancelPairing({String? pairingId}) async {
    await start();
    if (pairingId != null) {
      final expectedCandidate = _pairingCandidates[pairingId];
      if (expectedCandidate == null) {
        throw ArgumentError.value(pairingId, 'pairingId', '不是当前 TUI 配对世代');
      }
    }
    await _request(
      'pair.cancel',
      <String, Object?>{if (pairingId != null) 'pairingId': pairingId},
      expectedEvent: 'pair.cancel.done',
    );
    if (pairingId != null) _pairingCandidates.remove(pairingId);
  }

  @override
  Future<TuiIdentityResolutionResult> confirmIdentity(
    TuiIdentityConfirmation confirmation,
  ) async {
    await start();
    final currentConnection = _connectionId;
    if (currentConnection == null ||
        currentConnection != confirmation.connectionId) {
      throw StateError('identity.confirm 必须绑定当前 RFCOMM connectionId。');
    }
    if (!_snapshot.connected) {
      throw StateError('identity.confirm 只能绑定已打开的 RFCOMM connection。');
    }
    final knownGeneration = _connectionGenerations[currentConnection];
    if (knownGeneration == null) {
      throw StateError('当前 RFCOMM connection 缺少 native generation。');
    }
    if (confirmation.generation != null &&
        confirmation.generation != knownGeneration) {
      throw StateError('identity.confirm 的 generation 已过期。');
    }
    final expectedAddressKey = _connectionAddressKeys[currentConnection];
    if (expectedAddressKey == null ||
        confirmation.addressKey != expectedAddressKey) {
      throw StateError('identity.confirm 的 address 不属于当前 RFCOMM connection。');
    }
    final binding = _identityCandidates[confirmation.candidateId];
    if (binding == null) {
      throw StateError(
          'identity.confirm 缺少此前 identity.resolve 的 candidate binding。');
    }
    _validateCandidateConfirmation(confirmation, binding);
    final response = await _request(
      'identity.confirm',
      <String, Object?>{
        'candidateId': confirmation.candidateId,
        'advertisedName': confirmation.advertisedName,
        'address': confirmation.address,
        'addressKey': confirmation.addressKey,
        'connectionId': confirmation.connectionId,
        'generation': knownGeneration,
      },
      expectedEvent: 'identity.confirm.done',
    );
    _validateCandidateResponse(response, confirmation.candidateId);
    if (response['connectionId'] != confirmation.connectionId) {
      throw const TuiTransportProtocolException(
          'identity.confirm.done 的 connectionId 不匹配。');
    }
    final responseGeneration = _requireGeneration(
        response['generation'], 'identity.confirm.done 缺少 native generation。');
    if (responseGeneration != knownGeneration) {
      throw const TuiTransportProtocolException(
          'identity.confirm.done 的 generation 不匹配。');
    }
    final responseKey = _validatedAddressKey(
      response,
      expected: expectedAddressKey,
      required: true,
    );
    if (responseKey != confirmation.addressKey) {
      throw const TuiTransportProtocolException(
          'identity.confirm.done 的 address 不匹配。');
    }
    final result =
        _identityResolutionFromJson(response, confirmation.candidateId);
    if (result.resolution != TuiIdentityResolution.confirmed ||
        result.identityState != TuiIdentityState.confirmed) {
      throw const TuiTransportProtocolException(
          'identity.confirm.done 未确认 authenticated identity。');
    }
    _identityCandidates[confirmation.candidateId] =
        binding.confirmed(responseGeneration);
    _setSnapshot(connectionGeneration: responseGeneration);
    return result;
  }

  @override
  Future<TuiIdentityForgetResult> forgetIdentity(String candidateId) async {
    await start();
    final normalizedCandidateId = _requiredCandidateId(candidateId);
    final response = await _request(
      'identity.forget',
      <String, Object?>{'candidateId': normalizedCandidateId},
      expectedEvent: 'identity.forget.done',
    );
    _validateCandidateResponse(response, normalizedCandidateId);
    final forgotten = _requiredBool(
      response['forgotten'],
      'identity.forget.done 缺少 forgotten。',
    );
    final unpaired = _requiredBool(
      response['unpaired'],
      'identity.forget.done 缺少 unpaired。',
    );
    final disconnected = _requiredBool(
      response['disconnected'],
      'identity.forget.done 缺少 disconnected。',
    );
    _identityCandidates.remove(normalizedCandidateId);
    return TuiIdentityForgetResult(
      candidateId: normalizedCandidateId,
      forgotten: forgotten,
      unpaired: unpaired,
      disconnected: disconnected,
    );
  }

  @override
  Future<void> connect(
    TuiTransportDevice device, {
    String serviceUuid = '00001101-0000-1000-8000-00805f9b34fb',
  }) async {
    await start();
    // Do not begin a replacement connect while the helper is still cancelling
    // a timed-out SDP/RFCOMM attempt. Otherwise it can reject the new request
    // with connection_busy even though this transport has released its ID.
    while (true) {
      final disconnecting = _disconnecting;
      if (disconnecting == null) break;
      await disconnecting;
    }
    if (_connectionId != null) {
      throw StateError('已有 RFCOMM 连接或连接尝试。');
    }
    final connectionId = _newScopedId('c', ++_connectionCounter);
    _connectionId = connectionId;
    _connectionAddressKeys[connectionId] = device.addressKey;
    final terminal = Completer<void>();
    _connectionTerminals[connectionId] = terminal;
    _setSnapshot(
      connected: false,
      message: '正在建立 RFCOMM 连接。',
      transport: 'classic-rfcomm',
      serviceUuid: serviceUuid,
      connectionId: connectionId,
      addressKey: device.addressKey,
      endpoint: null,
      channel: null,
      mtu: null,
      sessionId: null,
      stage: 'connect.requested',
      stageCode: null,
      stageDetail: null,
    );
    try {
      final response = await _request(
        'connect',
        {
          'connectionId': connectionId,
          'address': device.address,
          'addressKey': device.addressKey,
          'serviceUuid': serviceUuid,
        },
        expectedEvent: 'connect.done',
        timeout: const Duration(seconds: 30),
      );
      if (response['connectionId'] != connectionId) {
        throw const TuiTransportProtocolException(
          'connect.done 的 connectionId 不匹配。',
        );
      }
      final generation = _requireGeneration(
        response['generation'],
        'connect.done 缺少 native generation。',
      );
      final observedGeneration = _connectionGenerations[connectionId];
      if (observedGeneration != null && observedGeneration != generation) {
        throw const TuiTransportProtocolException(
          'connect.done 的 native generation 与当前连接阶段不匹配。',
        );
      }
      _connectionGenerations[connectionId] = generation;
      _setSnapshot(
        connected: true,
        message: 'RFCOMM 已连接。',
        connectionId: connectionId,
        addressKey: _validatedAddressKey(
          response,
          expected: device.addressKey,
          required: true,
        ),
        transport: _string(response['transport']) ?? 'classic-rfcomm',
        endpoint: _string(response['endpoint']),
        serviceUuid: _string(response['serviceUuid']) ?? serviceUuid,
        channel: _asInt(response['channel']),
        mtu: _asInt(response['mtu'] ?? response['mtuBytes']),
        connectionGeneration: generation,
        sessionId: _string(response['sessionId']),
        stage: 'connect.done',
        stageCode: 'connected',
        stageDetail: 'RFCOMM 已连接。',
      );
    } on TimeoutException {
      // The helper can still be waiting in SDP/open after Dart has stopped
      // waiting. Retire this ID before allowing a replacement connection,
      // then ask the helper to cancel the original attempt.
      _retiredConnectionIds.add(connectionId);
      _setSnapshot(connected: false, message: 'RFCOMM 连接超时。');
      _scheduleConnectionCleanup(connectionId);
      rethrow;
    } on Object {
      // Native connect failures may arrive before `closed`; keep the ID
      // retired, but let the helper's guaranteed error -> cleanup -> closed
      // sequence settle before sending a redundant disconnect.
      if (_connectionId == connectionId) {
        _retiredConnectionIds.add(connectionId);
        _setSnapshot(connected: false, message: 'RFCOMM 连接失败。');
        _scheduleConnectionCleanup(connectionId);
      }
      rethrow;
    }
  }

  Future<void> _awaitConnectionTerminal(
    String connectionId,
    Completer<void>? terminal, {
    required Duration timeout,
  }) async {
    if (_connectionId != connectionId) return;
    final currentTerminal = terminal ?? _connectionTerminals[connectionId];
    if (currentTerminal == null) {
      throw StateError('RFCOMM 连接缺少原生终止事件。');
    }
    await currentTerminal.future.timeout(timeout);
  }

  Future<void> _requestBestEffortDisconnect(String connectionId) async {
    final terminal = _connectionTerminals[connectionId];
    if (terminal == null || _connectionId != connectionId) return;

    // The native helper guarantees error -> cleanup -> closed. Prefer that
    // terminal path before sending a redundant disconnect command.
    try {
      await terminal.future.timeout(_nativeTerminalGrace);
      return;
    } on TimeoutException {
      // The helper did not close promptly; request a best-effort cleanup.
    }
    if (_connectionId != connectionId) return;

    final acknowledged = _request(
      'disconnect',
      {'connectionId': connectionId},
      expectedEvent: 'disconnect.done',
      ensureStarted: false,
      timeout: const Duration(seconds: 10),
    ).then(
      (value) => value['connectionId'] == connectionId,
      onError: (Object _) => false,
    );
    await Future.any<bool>([
      acknowledged,
      terminal.future.then((_) => true),
    ]);
    if (_connectionId != connectionId) return;

    // `disconnect.done` alone is not proof that native ownership ended. Keep
    // the generation active until `closed`, otherwise a replacement connect
    // can race a still-open RFCOMM channel.
    try {
      await _awaitConnectionTerminal(
        connectionId,
        terminal,
        timeout: const Duration(seconds: 10),
      );
    } on TimeoutException {
      // Fail closed: _connectionId stays set and the next connect reports the
      // unresolved native ownership boundary instead of reusing the helper.
    }
  }

  Future<void> _scheduleConnectionCleanup(String connectionId) {
    final ongoing = _disconnecting;
    if (ongoing != null && _disconnectingConnectionId == connectionId) {
      return ongoing;
    }
    final previous = ongoing;
    late final Future<void> cleanup;
    cleanup = (() async {
      if (previous != null) {
        try {
          await previous;
        } on Object {
          // Continue best-effort cleanup even if an earlier request timed out.
        }
      }
      if (_connectionId != connectionId) return;
      await _requestBestEffortDisconnect(connectionId);
    })();
    _disconnecting = cleanup;
    _disconnectingConnectionId = connectionId;
    unawaited(cleanup.then<void>(
      (_) => _finishDisconnectOperation(cleanup, connectionId),
      onError: (Object _, StackTrace __) =>
          _finishDisconnectOperation(cleanup, connectionId),
    ));
    return cleanup;
  }

  @override
  Future<void> write(List<int> bytes) {
    if (bytes.isEmpty) return Future<void>.value();
    final copy = Uint8List.fromList(bytes);
    final next = _writeTail.then<void>(
      (_) => _writeNow(copy),
      onError: (_) => _writeNow(copy),
    );
    _writeTail = next;
    return next;
  }

  Future<void> _writeNow(Uint8List bytes) async {
    final connectionId = _connectionId;
    if (connectionId == null || !_snapshot.connected) {
      throw StateError('没有可写入的 RFCOMM 连接。');
    }
    try {
      for (var offset = 0;
          offset < bytes.length;
          offset += _maxWriteChunkBytes) {
        final end =
            (offset + _maxWriteChunkBytes).clamp(0, bytes.length).toInt();
        final chunk = Uint8List.sublistView(bytes, offset, end);
        final response = await _request(
          'write',
          {
            'connectionId': connectionId,
            'base64': base64Encode(chunk),
          },
          expectedEvent: 'write.done',
        );
        if (response['connectionId'] != connectionId ||
            _asInt(response['byteCount']) != chunk.length) {
          throw const TuiTransportProtocolException(
            'write.done 的连接或字节数不匹配。',
          );
        }
        final responseGeneration = _requireGeneration(
          response['generation'],
          'write.done 缺少 native generation。',
        );
        final connectionGeneration = _connectionGenerations[connectionId];
        if (connectionGeneration == null ||
            responseGeneration != connectionGeneration) {
          throw const TuiTransportProtocolException(
            'write.done 的 native generation 与当前连接不匹配。',
          );
        }
        _validatedAddressKey(
          response,
          expected: _connectionAddressKeys[connectionId],
          required: true,
        );
        final nativeLength = _asInt(response['length']);
        if (nativeLength != null && nativeLength != chunk.length) {
          throw const TuiTransportProtocolException(
            'write.done 的原生 length 与提交字节数不匹配。',
          );
        }
        final writeResult = _string(response['writeResult']);
        if (writeResult != null && writeResult != 'success') {
          throw TuiTransportProtocolException(
            'write.done 返回非成功 writeResult：$writeResult。',
          );
        }
        _journalRawWrite(chunk, response);
      }
    } on Object {
      // A missing or malformed write acknowledgement leaves the protocol
      // position unknown. Retire the connection before another frame can be
      // queued on a socket whose delivery state cannot be proven.
      _retiredConnectionIds.add(connectionId);
      _setSnapshot(connected: false, message: 'RFCOMM 写入失败，会话已失效。');
      _scheduleConnectionCleanup(connectionId);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    final ongoing = _disconnecting;
    if (ongoing != null) return ongoing;
    final connectionId = _connectionId;
    if (connectionId == null) return;
    late final Future<void> operation;
    operation = _disconnectCurrent(connectionId);
    _disconnecting = operation;
    _disconnectingConnectionId = connectionId;
    unawaited(operation.then<void>(
      (_) => _finishDisconnectOperation(operation, connectionId),
      onError: (Object _, StackTrace __) =>
          _finishDisconnectOperation(operation, connectionId),
    ));
    return operation;
  }

  void _finishDisconnectOperation(
    Future<void> operation,
    String connectionId,
  ) {
    if (identical(_disconnecting, operation) &&
        _disconnectingConnectionId == connectionId) {
      _disconnecting = null;
      _disconnectingConnectionId = null;
    }
  }

  Future<void> _disconnectCurrent(String connectionId) async {
    final terminal = _connectionTerminals[connectionId];
    if (terminal == null && _connectionId == connectionId) {
      throw StateError('RFCOMM 连接缺少原生终止事件。');
    }
    try {
      final response = await _request(
        'disconnect',
        {'connectionId': connectionId},
        expectedEvent: 'disconnect.done',
        timeout: const Duration(seconds: 10),
      );
      if (response['connectionId'] != connectionId) {
        throw const TuiTransportProtocolException(
          'disconnect.done 的 connectionId 不匹配。',
        );
      }
      await _awaitConnectionTerminal(
        connectionId,
        terminal,
        timeout: const Duration(seconds: 10),
      );
    } on Object {
      if (_connectionId == connectionId) {
        _setSnapshot(
          connected: false,
          message: 'RFCOMM 断开失败。',
          connectionId: connectionId,
        );
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> _request(
    String command,
    Map<String, Object?> fields, {
    required String expectedEvent,
    bool ensureStarted = true,
    Duration? timeout,
  }) async {
    if (ensureStarted) await start();
    final process = _process;
    if (process == null) throw StateError('macOS Bluetooth helper 未运行。');
    final requestId = 'r${++_requestCounter}';
    final completer = Completer<Map<String, Object?>>();
    final connectionId = _string(fields['connectionId']);
    _pending[requestId] = _PendingRequest(
      expectedEvent,
      completer,
      connectionId: connectionId,
      addressKey: connectionId == null
          ? null
          : _connectionAddressKeys[connectionId] ??
              _string(fields['addressKey']),
      generation:
          connectionId == null ? null : _connectionGenerations[connectionId],
    );
    try {
      await _sendLine({'command': command, 'requestId': requestId, ...fields});
      return await completer.future.timeout(
        timeout ?? _defaultRequestTimeout,
      );
    } finally {
      // A timeout must forget its request ID. Otherwise a late native reply
      // can complete stale state and prevent a later request from recovering.
      _pending.remove(requestId);
    }
  }

  Future<void> _sendLine(Map<String, Object?> message) {
    final encoded = '${jsonEncode(message)}\n';
    final next = _stdinTail.then<void>((_) async {
      final process = _process;
      if (process == null) throw StateError('helper stdin 已关闭。');
      process.stdin.add(utf8.encode(encoded));
      await process.stdin.flush();
    });
    _stdinTail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  void _handleLine(int epoch, String line) {
    if (epoch != _helperEpoch || _disposed) return;
    late final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on Object catch (error, stack) {
      _fatalSession(epoch, 'helper 输出了无效 JSONL：$error', stack);
      return;
    }
    if (decoded is! Map) {
      _fatalSession(epoch, 'helper JSONL 事件不是对象。');
      return;
    }
    final event = Map<String, Object?>.from(decoded);
    final eventName = event['event'];
    if (eventName is! String) {
      _fatalSession(epoch, 'helper JSONL 事件缺少 event。');
      return;
    }
    final connectionId = _string(event['connectionId']);
    // Native connection callbacks are capabilities scoped by the complete
    // (connectionId, addressKey, generation) tuple. A retired connection may
    // only deliver its matching terminal `closed`; every other late callback
    // is ignored before it can reach journals, request waiters, snapshots, or
    // protocol input.
    if (_isStrictlyScopedConnectionEvent(eventName) &&
        !_acceptConnectionEventTuple(eventName, event)) {
      return;
    }
    try {
      _validateScopedEventIdentity(event);
    } on TuiTransportProtocolException catch (error, stack) {
      _fatalSession(epoch, error.message, stack);
      return;
    }
    _journalNativeEvent(eventName, event);
    final requestId = event['requestId'];
    var requestHandled = false;
    TuiNativeTransportException? nativeError;
    if (eventName == 'error') {
      try {
        _validatedAddressKey(
          event,
          expected: _expectedAddressKey(event),
          required: false,
        );
        nativeError = _nativeException(event);
      } on TuiTransportProtocolException catch (error, stack) {
        _fatalSession(epoch, error.message, stack);
        return;
      }
    }
    if (requestId is String) {
      final pending = _pending[requestId];
      if (pending != null) {
        if (eventName == 'error') {
          _pending.remove(requestId);
          requestHandled = true;
          pending.completer.completeError(nativeError!);
        } else if (eventName == pending.expectedEvent) {
          _pending.remove(requestId);
          requestHandled = true;
          pending.completer.complete(event);
        }
      }
    }
    switch (eventName) {
      case 'pairing.stage':
        try {
          final pairingId = _requiredJsonId(
              event['pairingId'], 'pairing.stage 缺少 pairingId。');
          final candidateId = _requiredJsonId(
              event['candidateId'], 'pairing.stage 缺少 candidateId。');
          final expectedCandidate = _pairingCandidates[pairingId];
          if (expectedCandidate == null || expectedCandidate != candidateId)
            return;
          _pairingStages
              .add(_pairingStageFromJson(event, pairingId, candidateId));
        } on TuiTransportProtocolException catch (error, stack) {
          _fatalSession(epoch, error.message, stack);
        }
        return;
      case 'connection.stage':
        final stage = event['stage'];
        if (stage is String) _applyConnectionStage(event, stage);
        return;
      case 'device':
        if (event['scanId'] != _scanId) return;
        try {
          _discoveries.add(_deviceFromJson(event));
        } on Object catch (error, stack) {
          _fatalSession(epoch, 'helper device 事件无效：$error', stack);
        }
        return;
      case 'scan.finished':
        if (event['scanId'] != _scanId) return;
        _scanId = null;
        _setSnapshot(scanning: false, message: '经典蓝牙扫描已结束。');
        return;
      case 'data':
        final encoded = event['base64'];
        if (encoded is! String) {
          _fatalSession(epoch, 'helper data 事件缺少 base64。');
          return;
        }
        try {
          _input.add(base64Decode(encoded));
        } on FormatException catch (error, stack) {
          _fatalSession(epoch, 'helper data 事件包含无效 base64：$error', stack);
        }
        return;
      case 'closed':
        if (connectionId is! String) return;
        try {
          _validatedAddressKey(
            event,
            expected: _expectedAddressKey(event),
            required: false,
          );
        } on TuiTransportProtocolException catch (error, stack) {
          // Even malformed terminal metadata must release the native
          // generation; the helper has already closed this connection.
          final terminal = _connectionTerminals.remove(connectionId);
          if (terminal != null && !terminal.isCompleted) terminal.complete();
          if (connectionId == _connectionId) _connectionId = null;
          _retiredConnectionIds.remove(connectionId);
          _connectionAddressKeys.remove(connectionId);
          _fatalSession(epoch, error.message, stack);
          return;
        }
        final terminal = _connectionTerminals.remove(connectionId);
        if (terminal != null && !terminal.isCompleted) terminal.complete();
        _retiredConnectionIds.remove(connectionId);
        _connectionGenerations.remove(connectionId);
        if (connectionId != _connectionId) {
          _connectionAddressKeys.remove(connectionId);
          return;
        }
        _connectionId = null;
        final reason = event['reason'];
        _setSnapshot(
          connected: false,
          message: reason == 'remote'
              ? 'RFCOMM 远端已关闭。'
              : reason == 'error'
                  ? 'RFCOMM 连接已在原生错误后清理。'
                  : 'RFCOMM 已在本地清理。',
          helperSessionId: _helperSessionId,
          connectionId: connectionId,
          addressKey: _validatedAddressKey(
            event,
            expected: _snapshot.addressKey,
            required: false,
          ),
          transport: _string(event['transport']) ?? _snapshot.transport,
          endpoint: _string(event['endpoint']) ?? _snapshot.endpoint,
          serviceUuid: _string(event['serviceUuid']) ?? _snapshot.serviceUuid,
          channel: _asInt(event['channel']) ?? _snapshot.channel,
          mtu: _asInt(event['mtu'] ?? event['mtuBytes']) ?? _snapshot.mtu,
          sessionId: _string(event['sessionId']) ?? _snapshot.sessionId,
          stage: 'closed',
          stageCode: reason is String ? reason : null,
          stageDetail: _string(event['stageDetail'] ?? event['stageMessage']),
        );
        _connectionAddressKeys.remove(connectionId);
        if (reason == 'remote') _input.add(Uint8List(0));
        return;
      case 'error':
        final error = nativeError ?? _nativeException(event);
        // A helper-level error (for example, scan or pairing) has no native
        // connection capability. It must not invalidate an already-open
        // RFCOMM channel owned by the active connection ID.
        final errorConnectionId = _string(event['connectionId']);
        _setSnapshot(
          connected:
              errorConnectionId != null && errorConnectionId == _connectionId
                  ? false
                  : _snapshot.connected,
          message: error.message,
          helperSessionId: error.helperSessionId ?? _helperSessionId,
          connectionId: error.connectionId ?? _snapshot.connectionId,
          addressKey: error.addressKey ?? _snapshot.addressKey,
          transport: error.transport ?? _snapshot.transport,
          endpoint: error.endpoint ?? _snapshot.endpoint,
          serviceUuid: error.serviceUuid ?? _snapshot.serviceUuid,
          channel: error.channel ?? _snapshot.channel,
          mtu: error.mtu ?? _snapshot.mtu,
          sessionId: error.sessionId ?? _snapshot.sessionId,
          stage: error.stage ?? 'error',
          stageCode: error.stageCode ?? error.code,
          stageDetail: error.stageDetail ?? error.message,
        );
        if (!requestHandled) _errors.add(error);
        return;
      default:
        return;
    }
  }

  static TuiTransportDevice _deviceFromJson(
    Map<String, Object?> value, {
    TuiTransportDeviceSource? fallbackSource,
  }) {
    final address = value['address'];
    if (address is! String) {
      throw const TuiTransportProtocolException('设备事件缺少 address。');
    }
    final key = _validatedAddressKey(value, required: true);
    final source = switch (value['source']) {
      'paired' => TuiTransportDeviceSource.paired,
      'inquiry' => TuiTransportDeviceSource.inquiry,
      _ => fallbackSource ?? TuiTransportDeviceSource.inquiry,
    };
    final device = TuiTransportDevice(
      address: address,
      name: value['name'] is String ? value['name']! as String : '',
      rssi: _asInt(value['rssi']),
      paired:
          value['paired'] == true || source == TuiTransportDeviceSource.paired,
      source: source,
    );
    if (device.addressKey != key) {
      throw const TuiTransportProtocolException(
        '设备事件的 addressKey 与 address 不匹配。',
      );
    }
    return device;
  }

  static TuiIdentityResolutionResult _identityResolutionFromJson(
    Map<String, Object?> value,
    String expectedCandidateId,
  ) {
    _validateCandidateResponse(value, expectedCandidateId);
    final resolution = _identityResolution(value['resolution']);
    final identityState = _identityState(value['identityState']);
    TuiTransportDevice? device;
    if (value['address'] != null || value['addressKey'] != null) {
      device = _deviceFromJson(value,
          fallbackSource: TuiTransportDeviceSource.manual);
    }
    return TuiIdentityResolutionResult(
      candidateId: expectedCandidateId,
      resolution: resolution,
      identityState: identityState,
      device: device,
      matchMode: _string(value['matchMode']),
      generation: _asInt(value['generation']),
    );
  }

  static TuiIdentityState _identityState(Object? value) => switch (value) {
        'confirmed' => TuiIdentityState.confirmed,
        'provisional' => TuiIdentityState.provisional,
        'unresolved' => TuiIdentityState.unresolved,
        _ => throw const TuiTransportProtocolException('identityState 无效或缺失。'),
      };

  static TuiIdentityResolution _identityResolution(Object? value) =>
      switch (value) {
        'confirmed' => TuiIdentityResolution.confirmed,
        'provisional' => TuiIdentityResolution.provisional,
        'uniquePaired' => TuiIdentityResolution.uniquePaired,
        'needsSelection' => TuiIdentityResolution.needsSelection,
        'notPaired' => TuiIdentityResolution.notPaired,
        'directClassic' => TuiIdentityResolution.directClassic,
        _ => throw const TuiTransportProtocolException(
            'identity resolution 无效或缺失。'),
      };

  static TuiPairingStage _pairingStageFromJson(
    Map<String, Object?> value,
    String pairingId,
    String candidateId,
  ) =>
      TuiPairingStage(
        pairingId: pairingId,
        candidateId: candidateId,
        stage: switch (value['stage']) {
          'resolving' => TuiPairingStageKind.resolving,
          'pairingStarted' => TuiPairingStageKind.pairingStarted,
          'waitingPin' => TuiPairingStageKind.waitingPin,
          'waitingConfirmation' => TuiPairingStageKind.waitingConfirmation,
          'completed' => TuiPairingStageKind.completed,
          'failed' => TuiPairingStageKind.failed,
          'cancelled' => TuiPairingStageKind.cancelled,
          _ => throw const TuiTransportProtocolException(
              'pairing.stage 的 stage 无效或缺失。'),
        },
        timestamp: _eventTimestamp(value),
        generation: _asInt(value['generation']),
        message: _string(value['message'] ?? value['stageDetail']),
        nativeDomain: _string(
            value['nativeDomain'] ?? value['domain'] ?? value['errorDomain']),
        nativeCode: _asInt(value['nativeCode'] ?? value['osStatus']),
      );

  static void _validateCandidateResponse(
    Map<String, Object?> value,
    String expectedCandidateId,
  ) {
    if (_requiredJsonId(value['candidateId'], 'helper 事件缺少 candidateId。') !=
        expectedCandidateId) {
      throw const TuiTransportProtocolException(
          'helper 事件的 candidateId 与当前操作不匹配。');
    }
  }

  static void _validateCandidateInput(TuiIdentityCandidate candidate) {
    _requiredCandidateId(candidate.candidateId);
    if (candidate.advertisedName.trim().isEmpty) {
      throw const TuiTransportProtocolException(
        'identity candidate 缺少 advertisedName。',
      );
    }
    if (candidate.addressKey != null) {
      _validateCandidateAddress(candidate, candidate.addressKey);
    }
  }

  static void _validateCandidateResult(
    TuiIdentityCandidate candidate,
    TuiIdentityResolutionResult result,
  ) {
    if (result.candidateId != candidate.candidateId) {
      throw const TuiTransportProtocolException(
        'identity.resolve 返回了错误的 candidateId。',
      );
    }
    final device = result.device;
    if (device != null) {
      _validateCandidateAddress(candidate, device.addressKey);
    }
    if (result.resolution == TuiIdentityResolution.confirmed &&
        result.identityState != TuiIdentityState.confirmed) {
      throw const TuiTransportProtocolException(
        'confirmed resolution 必须同时返回 confirmed identityState。',
      );
    }
    if (result.identityState == TuiIdentityState.confirmed &&
        result.resolution != TuiIdentityResolution.confirmed) {
      throw const TuiTransportProtocolException(
        'confirmed identityState 只能来自 confirmed resolution。',
      );
    }
  }

  static void _validateCandidateBinding(
    TuiIdentityCandidate candidate,
    _IdentityCandidateBinding binding,
  ) {
    if (binding.candidateId != candidate.candidateId ||
        binding.advertisedName != candidate.advertisedName.trim() ||
        binding.directedExactAddress != candidate.directedExactAddress) {
      throw const TuiTransportProtocolException(
        'identity candidate 复用了不同设备的 binding。',
      );
    }
    _validateCandidateAddress(candidate, binding.addressKey);
  }

  static void _validateCandidateAddress(
    TuiIdentityCandidate candidate,
    String? addressKey,
  ) {
    final expected = candidate.addressKey;
    if (expected != null && (addressKey == null || expected != addressKey)) {
      throw const TuiTransportProtocolException(
        'identity candidate 的 Classic address 与返回 identity 不匹配。',
      );
    }
  }

  static void _validateCandidateConfirmation(
    TuiIdentityConfirmation confirmation,
    _IdentityCandidateBinding binding,
  ) {
    if (binding.candidateId != confirmation.candidateId ||
        binding.advertisedName != confirmation.advertisedName.trim()) {
      throw const TuiTransportProtocolException(
        'identity.confirm 的 candidate binding 不匹配。',
      );
    }
    if (binding.addressKey != null &&
        binding.addressKey != confirmation.addressKey) {
      throw const TuiTransportProtocolException(
        'identity.confirm 的 address 不匹配此前 candidate binding。',
      );
    }
  }

  static int _requireGeneration(Object? value, String message) {
    final generation = _asInt(value);
    if (generation == null || generation <= 0) {
      throw TuiTransportProtocolException(message);
    }
    return generation;
  }

  static bool _requiredBool(Object? value, String message) {
    if (value is! bool) {
      throw TuiTransportProtocolException(message);
    }
    return value;
  }

  static void _validatePairingResponse(
    Map<String, Object?> value,
    String expectedPairingId,
    String expectedCandidateId,
  ) {
    if (_requiredJsonId(value['pairingId'], 'pair.done 缺少 pairingId。') !=
        expectedPairingId) {
      throw const TuiTransportProtocolException('pair.done 的 pairingId 不匹配。');
    }
    _validateCandidateResponse(value, expectedCandidateId);
  }

  static String _requiredJsonId(Object? value, String message) {
    if (value is! String || value.trim().isEmpty) {
      throw TuiTransportProtocolException(message);
    }
    return value.trim();
  }

  static String _requiredCandidateId(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, 'candidateId', '不能为空');
    }
    return normalized;
  }

  static int? _asInt(Object? value) => value is num ? value.toInt() : null;

  static String? _string(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  static String? _validatedAddressKey(
    Map<String, Object?> value, {
    String? expected,
    bool required = false,
  }) {
    final raw = value['addressKey'];
    if (raw == null) {
      if (required) {
        throw const TuiTransportProtocolException(
          'helper 事件缺少 canonical addressKey。',
        );
      }
      _validateAddressAgainstKey(value['address'], expected);
      return expected;
    }
    if (raw is! String || !RegExp(r'^[0-9A-F]{12}$').hasMatch(raw)) {
      throw const TuiTransportProtocolException(
        'helper 事件的 addressKey 必须是 12 位大写十六进制。',
      );
    }
    if (expected != null && raw != expected) {
      throw const TuiTransportProtocolException(
        'helper 事件的 addressKey 与当前连接不匹配。',
      );
    }
    _validateAddressAgainstKey(value['address'], raw);
    return raw;
  }

  static void _validateAddressAgainstKey(Object? address, String? key) {
    if (address == null) return;
    if (address is! String) {
      throw const TuiTransportProtocolException(
        'helper 事件的经典蓝牙 address 必须是字符串。',
      );
    }
    try {
      if (key != null && TuiBluetoothAddress.parse(address).key != key) {
        throw const TuiTransportProtocolException(
          'helper 事件的 addressKey 与 address 不匹配。',
        );
      }
    } on FormatException {
      throw const TuiTransportProtocolException(
        'helper 事件包含无效经典蓝牙 address。',
      );
    }
  }

  void _validateScopedEventIdentity(Map<String, Object?> event) {
    final connectionId = _string(event['connectionId']);
    if (connectionId == null) return;
    final expected = _connectionAddressKeys[connectionId];
    if (expected == null) return;
    _validatedAddressKey(event, expected: expected, required: false);
  }

  static bool _isStrictlyScopedConnectionEvent(String eventName) =>
      eventName == 'connection.stage' ||
      eventName == 'connection.diagnostic' ||
      eventName == 'error' ||
      eventName == 'data' ||
      eventName == 'write.done' ||
      eventName == 'disconnect.done' ||
      eventName == 'closed';

  bool _acceptConnectionEventTuple(
    String eventName,
    Map<String, Object?> event,
  ) {
    final connectionId = _string(event['connectionId']);
    if (connectionId == null) {
      // Errors without a connection ID belong to helper/scan/pairing request
      // scope and continue through their request ID validation.
      return eventName == 'error';
    }
    if (_acceptPendingPreActiveConnectError(eventName, event, connectionId)) {
      return true;
    }
    if (_acceptPendingDisconnectDone(eventName, event, connectionId)) {
      return true;
    }
    final expectedAddressKey = _connectionAddressKeys[connectionId];
    final isCurrent = connectionId == _connectionId;
    final isRetired = _retiredConnectionIds.contains(connectionId);
    if (expectedAddressKey == null || (!isCurrent && !isRetired)) {
      return false;
    }
    if (isRetired && eventName != 'closed') return false;

    try {
      _validatedAddressKey(
        event,
        expected: expectedAddressKey,
        required: true,
      );
    } on TuiTransportProtocolException {
      return false;
    }
    final generation = _asInt(event['generation']);
    if (generation == null || generation <= 0) return false;
    final expectedGeneration = _connectionGenerations[connectionId];
    if (expectedGeneration != null) return generation == expectedGeneration;
    if (!isCurrent || isRetired) return false;

    // connection.stage can precede connect.done. Bind the first fully scoped
    // native callback, then require connect.done and all later callbacks to
    // prove the same generation.
    _connectionGenerations[connectionId] = generation;
    return true;
  }

  bool _acceptPendingPreActiveConnectError(
    String eventName,
    Map<String, Object?> event,
    String connectionId,
  ) {
    if (eventName != 'error' ||
        event['addressKey'] != null ||
        _asInt(event['generation']) != null ||
        connectionId != _connectionId ||
        _retiredConnectionIds.contains(connectionId) ||
        _connectionGenerations.containsKey(connectionId)) {
      return false;
    }
    final requestId = _string(event['requestId']);
    final pending = requestId == null ? null : _pending[requestId];
    if (pending == null ||
        pending.expectedEvent != 'connect.done' ||
        pending.connectionId != connectionId) {
      return false;
    }
    try {
      _validatedAddressKey(
        event,
        expected: pending.addressKey,
        required: false,
      );
    } on TuiTransportProtocolException {
      return false;
    }
    return true;
  }

  bool _acceptPendingDisconnectDone(
    String eventName,
    Map<String, Object?> event,
    String connectionId,
  ) {
    if (eventName != 'disconnect.done') return false;
    final requestId = _string(event['requestId']);
    final pending = requestId == null ? null : _pending[requestId];
    if (pending == null ||
        pending.expectedEvent != 'disconnect.done' ||
        pending.connectionId != connectionId ||
        pending.addressKey == null ||
        pending.generation == null ||
        _asInt(event['generation']) != pending.generation) {
      return false;
    }
    try {
      _validatedAddressKey(
        event,
        expected: pending.addressKey,
        required: true,
      );
    } on TuiTransportProtocolException {
      return false;
    }
    return true;
  }

  String? _expectedAddressKey(Map<String, Object?> event) {
    final eventConnectionId = event['connectionId'];
    return eventConnectionId is String
        ? _connectionAddressKeys[eventConnectionId]
        : null;
  }

  TuiNativeTransportException _nativeException(Map<String, Object?> event) {
    final connectionAddressKey = _expectedAddressKey(event);
    final enriched = <String, Object?>{
      ...event,
      if (event['domain'] == null &&
          event['errorDomain'] == null &&
          event['nativeDomain'] != null)
        'domain': event['nativeDomain'],
      if (event['helperSessionId'] == null && _helperSessionId != null)
        'helperSessionId': _helperSessionId,
      if (event['addressKey'] == null &&
          (connectionAddressKey ?? _snapshot.addressKey) != null)
        'addressKey': connectionAddressKey ?? _snapshot.addressKey,
      if (event['transport'] == null && _snapshot.transport != null)
        'transport': _snapshot.transport,
      if (event['endpoint'] == null && _snapshot.endpoint != null)
        'endpoint': _snapshot.endpoint,
      if (event['serviceUuid'] == null && _snapshot.serviceUuid != null)
        'serviceUuid': _snapshot.serviceUuid,
      if (event['channel'] == null && _snapshot.channel != null)
        'channel': _snapshot.channel,
      if (event['mtu'] == null && _snapshot.mtu != null) 'mtu': _snapshot.mtu,
    };
    return TuiNativeTransportException.fromJson(enriched);
  }

  static String _connectionStageMessage(
    String stage,
    Map<String, Object?> event,
  ) {
    final channel = _asInt(event['channel']);
    return switch (stage) {
      'sdp.started' => '正在查询 SDP 服务端点。',
      'sdp.completed' => 'SDP 查询已返回，正在解析 RFCOMM 端点。',
      'sdp.timeout' => 'SDP 查询未收到 macOS 终止回调。',
      'rfcomm.open.started' =>
        '正在打开 RFCOMM 通道${channel == null ? '' : ' $channel'}。',
      'rfcomm.open.completed' => 'RFCOMM 打开回调已返回。',
      'rfcomm.open.timeout' => 'RFCOMM 打开未收到 macOS 终止回调。',
      'cleanup.completed' => 'RFCOMM 原生连接状态已清理。',
      _ => 'RFCOMM 连接阶段：$stage',
    };
  }

  void _applyConnectionStage(Map<String, Object?> event, String stage) {
    final connectionId = _string(event['connectionId']);
    if (connectionId == null || connectionId != _connectionId) return;
    final addressKey = _validatedAddressKey(
      event,
      expected: _expectedAddressKey(event),
      required: false,
    );
    final stageDetail = _string(event['stageDetail'] ?? event['stageMessage']);
    final normalized = stage.toLowerCase();
    final transport = _string(event['transport']) ?? _snapshot.transport;
    final endpoint = _string(event['endpoint']) ?? _snapshot.endpoint;
    final serviceUuid = _string(event['serviceUuid']) ?? _snapshot.serviceUuid;
    final channel = _asInt(event['channel']) ?? _snapshot.channel;
    final mtu = _asInt(event['mtu'] ?? event['mtuBytes']) ?? _snapshot.mtu;
    final sessionId = _string(event['sessionId']) ?? _snapshot.sessionId;
    final connected = (normalized == 'rfcomm.open.completed' &&
            (_asInt(event['status']) ?? 0) == 0) ||
        normalized == 'connect.done' ||
        normalized == 'connected';
    final message = stageDetail ?? _connectionStageMessage(stage, event);
    _setSnapshot(
      connected: connected,
      message: message,
      helperSessionId: _string(event['helperSessionId']) ?? _helperSessionId,
      connectionId: connectionId,
      addressKey: addressKey ?? _snapshot.addressKey,
      transport: transport,
      endpoint: endpoint,
      serviceUuid: serviceUuid,
      channel: channel,
      mtu: mtu,
      connectionGeneration:
          _asInt(event['generation']) ?? _snapshot.connectionGeneration,
      sessionId: sessionId,
      stage: stage,
      stageCode: _string(event['stageCode']) ?? _string(event['code']),
      stageDetail: stageDetail,
    );
  }

  void _journalNativeEvent(String eventName, Map<String, Object?> event) {
    final journal = diagnosticJournal;
    if (journal == null) return;
    // write.done is emitted only after the matching write request has been
    // validated, so the TX journal can include the exact submitted bytes.
    if (eventName == 'write.done') return;
    final category = switch (eventName) {
      'device' ||
      'scan.started' ||
      'scan.finished' ||
      'scan.stop.done' =>
        DiagnosticCategory.scan,
      'paired.list.done' ||
      'identity.resolve.done' ||
      'identity.confirm.done' ||
      'identity.forget.done' ||
      'pairing.stage' ||
      'pair.done' ||
      'pair.cancel.done' =>
        DiagnosticCategory.pairing,
      'connection.stage' => _journalStageCategory(event['stage']),
      'data' => DiagnosticCategory.rawRx,
      'write.done' => DiagnosticCategory.rawTx,
      'closed' || 'disconnect.done' => DiagnosticCategory.rfcomm,
      'error' => _journalStageCategory(event['stage']),
      'hello.done' => DiagnosticCategory.session,
      _ => DiagnosticCategory.system,
    };
    final severity = eventName == 'error'
        ? DiagnosticSeverity.error
        : eventName == 'closed'
            ? DiagnosticSeverity.warning
            : DiagnosticSeverity.info;
    final encoded = _string(event['base64']);
    var byteCount = _asInt(event['byteCount'] ?? event['length']);
    var hex = _string(event['hex']);
    if (encoded != null) {
      try {
        final bytes = base64Decode(encoded);
        byteCount ??= bytes.length;
        hex = bytes
            .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
            .join(' ');
      } on FormatException {
        // Keep the native event visible even when payload metadata is bad.
      }
    }
    final fields = <String, Object?>{
      'event': eventName,
      if (event['requestId'] is String) 'requestId': event['requestId'],
      if (_string(event['candidateId']) != null)
        'candidateId': _string(event['candidateId']),
      if (_string(event['pairingId']) != null)
        'pairingId': _string(event['pairingId']),
      if (_asInt(event['generation']) != null)
        'generation': _asInt(event['generation']),
      if (_string(event['stage']) != null) 'stage': _string(event['stage']),
      if (_string(event['reason']) != null) 'reason': _string(event['reason']),
      if (_string(event['serviceUuid']) != null)
        'serviceUuid': _string(event['serviceUuid']),
      if (_asInt(event['channel']) != null) 'channel': _asInt(event['channel']),
      if (_asInt(event['mtu'] ?? event['mtuBytes']) != null)
        'mtu': _asInt(event['mtu'] ?? event['mtuBytes']),
      if (_string(event['transport']) != null)
        'transport': _string(event['transport']),
      if (_string(event['endpoint']) != null)
        'endpoint': _string(event['endpoint']),
      if (byteCount != null) 'length': byteCount,
      if (hex != null) 'hex': hex,
      if (_string(event['writeResult']) != null)
        'writeResult': _string(event['writeResult']),
      if (_string(event['readResult']) != null)
        'readResult': _string(event['readResult']),
      if (_string(event['nativeDomain'] ??
              event['domain'] ??
              event['errorDomain']) !=
          null)
        'nativeDomain': _string(
            event['nativeDomain'] ?? event['domain'] ?? event['errorDomain']),
      if (_asInt(event['nativeCode'] ?? event['osStatus']) != null)
        'nativeCode': _asInt(event['nativeCode'] ?? event['osStatus']),
    };
    final diagnostic = DiagnosticEvent(
      timestamp: _eventTimestamp(event),
      severity: severity,
      category: category,
      message: _string(event['message']) ??
          _string(event['stageDetail'] ?? event['stageMessage']) ??
          _string(event['reason']) ??
          eventName,
      deviceId: _string(event['addressKey']) ??
          _expectedAddressKey(event) ??
          _snapshot.addressKey,
      sessionId: _string(event['sessionId']) ??
          _string(event['connectionId']) ??
          _helperSessionId,
      nativeDomain: _string(
        event['nativeDomain'] ?? event['domain'] ?? event['errorDomain'],
      ),
      nativeCode: _asInt(event['nativeCode'] ?? event['osStatus']),
      disconnectReason: _string(event['reason']),
      timeoutMs: _asInt(event['timeoutMs']),
      retry: _asInt(event['retry']),
      direction: eventName == 'data'
          ? 'rx'
          : eventName == 'write.done'
              ? 'tx'
              : null,
      byteCount: byteCount,
      endpoint: _string(event['endpoint']) ?? _snapshot.endpoint,
      fields: fields,
    );
    final next = _journalTail.then<void>(
      (_) => journal.append(diagnostic),
      onError: (_) => journal.append(diagnostic),
    );
    _journalTail = next.then<void>((_) {}, onError: (_) {});
  }

  static DiagnosticCategory _journalStageCategory(Object? value) {
    final stage = value is String ? value.toLowerCase() : '';
    if (stage.startsWith('sdp')) return DiagnosticCategory.sdp;
    if (stage.startsWith('rfcomm') ||
        stage.startsWith('connect') ||
        stage.startsWith('disconnect') ||
        stage.startsWith('cleanup')) {
      return DiagnosticCategory.rfcomm;
    }
    if (stage.startsWith('auth')) return DiagnosticCategory.auth;
    if (stage.startsWith('session')) return DiagnosticCategory.session;
    if (stage.startsWith('install')) return DiagnosticCategory.install;
    return DiagnosticCategory.system;
  }

  void _journalRawWrite(
    Uint8List bytes,
    Map<String, Object?> response,
  ) {
    final journal = diagnosticJournal;
    if (journal == null) return;
    final connectionId = _string(response['connectionId']);
    final nativeHex = _string(response['hex']);
    final submittedHex = _hexBytes(bytes);
    final writeResult = _string(response['writeResult']) ?? 'acknowledged';
    final nativeDomain = _string(
      response['nativeDomain'] ?? response['domain'] ?? response['errorDomain'],
    );
    final nativeCode = _asInt(response['nativeCode'] ?? response['osStatus']);
    final diagnostic = DiagnosticEvent(
      timestamp: _eventTimestamp(response),
      severity: DiagnosticSeverity.info,
      category: DiagnosticCategory.rawTx,
      message: 'RFCOMM write acknowledged.',
      deviceId: _string(response['addressKey']) ??
          (connectionId == null
              ? null
              : _connectionAddressKeys[connectionId]) ??
          _snapshot.addressKey,
      sessionId: _string(response['sessionId']) ??
          _string(response['connectionId']) ??
          _snapshot.activeSessionId,
      direction: 'tx',
      byteCount: bytes.length,
      endpoint: _string(response['endpoint']) ?? _snapshot.endpoint,
      nativeDomain: nativeDomain,
      nativeCode: nativeCode,
      fields: <String, Object?>{
        'event': 'write.done',
        'writeResult': writeResult,
        'length': bytes.length,
        'hex': submittedHex,
        if (nativeHex != null && nativeHex != submittedHex)
          'nativeHex': nativeHex,
        if (_string(response['transport']) ?? _snapshot.transport
            case final transport?)
          'transport': transport,
        if (_string(response['endpoint']) ?? _snapshot.endpoint
            case final endpoint?)
          'endpoint': endpoint,
        if (nativeDomain != null) 'nativeDomain': nativeDomain,
        if (nativeCode != null) 'nativeCode': nativeCode,
        if (_snapshot.serviceUuid != null) 'serviceUuid': _snapshot.serviceUuid,
        if (_snapshot.channel != null) 'channel': _snapshot.channel,
        if (_snapshot.mtu != null) 'mtu': _snapshot.mtu,
      },
    );
    _appendJournal(diagnostic);
  }

  static String _hexBytes(Iterable<int> bytes) =>
      bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');

  static DateTime _eventTimestamp(Map<String, Object?> event) {
    final timestampMs = _asInt(event['timestampMs']);
    if (timestampMs != null && timestampMs >= 0) {
      return DateTime.fromMillisecondsSinceEpoch(timestampMs, isUtc: true);
    }
    final timestamp = _string(event['timestamp']);
    return DateTime.tryParse(timestamp ?? '')?.toUtc() ??
        DateTime.now().toUtc();
  }

  void _appendJournal(DiagnosticEvent event) {
    final journal = diagnosticJournal;
    if (journal == null) return;
    final next = _journalTail.then<void>(
      (_) => journal.append(event),
      onError: (_) => journal.append(event),
    );
    _journalTail = next.then<void>((_) {}, onError: (_) {});
  }

  String _newScopedId(String prefix, int counter) =>
      '${_helperSessionId ?? 'starting'}-$prefix$counter';

  void _setSnapshot({
    Object? helperState = _snapshotUnset,
    Object? scanning = _snapshotUnset,
    Object? connected = _snapshotUnset,
    Object? message = _snapshotUnset,
    Object? transport = _snapshotUnset,
    Object? endpoint = _snapshotUnset,
    Object? serviceUuid = _snapshotUnset,
    Object? channel = _snapshotUnset,
    Object? mtu = _snapshotUnset,
    Object? helperSessionId = _snapshotUnset,
    Object? sessionId = _snapshotUnset,
    Object? connectionId = _snapshotUnset,
    Object? connectionGeneration = _snapshotUnset,
    Object? addressKey = _snapshotUnset,
    Object? stage = _snapshotUnset,
    Object? stageCode = _snapshotUnset,
    Object? stageDetail = _snapshotUnset,
  }) {
    _snapshot = _snapshot.copyWith(
      helperState: identical(helperState, _snapshotUnset)
          ? null
          : helperState as TuiMacHelperState,
      scanning: identical(scanning, _snapshotUnset) ? null : scanning as bool,
      connected:
          identical(connected, _snapshotUnset) ? null : connected as bool,
      message: identical(message, _snapshotUnset) ? _snapshot.message : message,
      transport: identical(transport, _snapshotUnset)
          ? _snapshot.transport
          : transport,
      endpoint:
          identical(endpoint, _snapshotUnset) ? _snapshot.endpoint : endpoint,
      serviceUuid: identical(serviceUuid, _snapshotUnset)
          ? _snapshot.serviceUuid
          : serviceUuid,
      channel: identical(channel, _snapshotUnset) ? _snapshot.channel : channel,
      mtu: identical(mtu, _snapshotUnset) ? _snapshot.mtu : mtu,
      helperSessionId: identical(helperSessionId, _snapshotUnset)
          ? _snapshot.helperSessionId
          : helperSessionId,
      sessionId: identical(sessionId, _snapshotUnset)
          ? _snapshot.sessionId
          : sessionId,
      connectionId: identical(connectionId, _snapshotUnset)
          ? _snapshot.connectionId
          : connectionId,
      connectionGeneration: identical(connectionGeneration, _snapshotUnset)
          ? _snapshot.connectionGeneration
          : connectionGeneration,
      addressKey: identical(addressKey, _snapshotUnset)
          ? _snapshot.addressKey
          : addressKey,
      stage: identical(stage, _snapshotUnset) ? _snapshot.stage : stage,
      stageCode: identical(stageCode, _snapshotUnset)
          ? _snapshot.stageCode
          : stageCode,
      stageDetail: identical(stageDetail, _snapshotUnset)
          ? _snapshot.stageDetail
          : stageDetail,
    );
    if (!_snapshots.isClosed) _snapshots.add(_snapshot);
  }

  void _handleProcessExit(int epoch, int? exitCode) {
    if (epoch != _helperEpoch || _process == null) return;
    final expected = _disposing || _disposed;
    final suffix =
        _stderrTail.trim().isEmpty ? '' : '；stderr: ${_stderrTail.trim()}';
    _terminateSession(
      epoch,
      expected
          ? 'macOS Bluetooth helper 已退出。'
          : 'macOS Bluetooth helper 意外退出（code=${exitCode ?? '未知'}）$suffix',
      reportError: !expected,
    );
  }

  void _fatalSession(int epoch, String message, [StackTrace? stack]) {
    if (epoch != _helperEpoch) return;
    final process = _process;
    _terminateSession(epoch, message, reportError: true, stack: stack);
    process?.kill();
  }

  void _terminateSession(
    int epoch,
    String message, {
    required bool reportError,
    StackTrace? stack,
  }) {
    if (epoch != _helperEpoch) return;
    _helperEpoch++;
    final hadConnection = _connectionId != null;
    _process = null;
    _helperSessionId = null;
    _connectionId = null;
    _disconnecting = null;
    _disconnectingConnectionId = null;
    _retiredConnectionIds.clear();
    _connectionAddressKeys.clear();
    _connectionGenerations.clear();
    _pairingCandidates.clear();
    for (final terminal in _connectionTerminals.values) {
      if (!terminal.isCompleted) terminal.complete();
    }
    _connectionTerminals.clear();
    _scanId = null;
    final error = TuiTransportProtocolException(message);
    for (final request in _pending.values) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error, stack);
      }
    }
    _pending.clear();
    if (reportError && !_errors.isClosed) _errors.add(error);
    if (hadConnection && !_input.isClosed) _input.add(Uint8List(0));
    _setSnapshot(
      helperState: _disposed
          ? TuiMacHelperState.disposed
          : reportError
              ? TuiMacHelperState.failed
              : TuiMacHelperState.stopped,
      scanning: false,
      connected: false,
      message: message,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposing = true;
    try {
      try {
        await stopScan();
      } on Object {
        // Process shutdown below remains authoritative.
      }
      try {
        await disconnect();
      } on Object {
        // Process shutdown below remains authoritative.
      }
      final process = _process;
      if (process != null) {
        try {
          await process.stdin.close();
        } on Object {
          process.kill();
        }
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } on Object {
          process.kill();
        }
      }
    } finally {
      _disposed = true;
      _disposing = false;
      _helperEpoch++;
      for (final request in _pending.values) {
        if (!request.completer.isCompleted) {
          request.completer.completeError(StateError('transport 已释放。'));
        }
      }
      _pending.clear();
      _disconnecting = null;
      _disconnectingConnectionId = null;
      _retiredConnectionIds.clear();
      _connectionAddressKeys.clear();
      _connectionGenerations.clear();
      _pairingCandidates.clear();
      for (final terminal in _connectionTerminals.values) {
        if (!terminal.isCompleted) terminal.complete();
      }
      _connectionTerminals.clear();
      await _stdoutSubscription?.cancel();
      await _stderrSubscription?.cancel();
      _snapshot = const TuiMacTransportSnapshot(
        helperState: TuiMacHelperState.disposed,
        scanning: false,
        connected: false,
        message: 'macOS Bluetooth transport 已释放。',
      );
      if (!_snapshots.isClosed) _snapshots.add(_snapshot);
      await _input.close();
      await _errors.close();
      await _discoveries.close();
      await _pairingStages.close();
      await _snapshots.close();
    }
  }
}

final class _PendingRequest {
  const _PendingRequest(
    this.expectedEvent,
    this.completer, {
    this.connectionId,
    this.addressKey,
    this.generation,
  });

  final String expectedEvent;
  final Completer<Map<String, Object?>> completer;
  final String? connectionId;
  final String? addressKey;
  final int? generation;
}

/// Immutable identity binding owned by this transport generation.  A pairing
/// result is deliberately provisional; only [confirmed] may transition the
/// binding after successful Xiaomi authentication and identity confirmation.
final class _IdentityCandidateBinding {
  const _IdentityCandidateBinding({
    required this.candidateId,
    required this.advertisedName,
    required this.addressKey,
    required this.identityState,
    required this.directedExactAddress,
    this.generation,
  });

  final String candidateId;
  final String advertisedName;
  final String? addressKey;
  final TuiIdentityState identityState;
  final bool directedExactAddress;
  final int? generation;

  factory _IdentityCandidateBinding.fromCandidate(
    TuiIdentityCandidate candidate,
    TuiIdentityResolutionResult result,
  ) =>
      _IdentityCandidateBinding(
        candidateId: candidate.candidateId,
        advertisedName: candidate.advertisedName.trim(),
        addressKey: result.device?.addressKey ?? candidate.addressKey,
        identityState: result.identityState,
        directedExactAddress: candidate.directedExactAddress,
        generation: result.generation,
      );

  factory _IdentityCandidateBinding.fromPairing(
    TuiIdentityCandidate candidate,
    TuiTransportDevice device,
    Map<String, Object?> response,
  ) =>
      _IdentityCandidateBinding(
        candidateId: candidate.candidateId,
        advertisedName: candidate.advertisedName.trim(),
        addressKey: device.addressKey,
        identityState: TuiIdentityState.provisional,
        directedExactAddress: candidate.directedExactAddress,
        generation: response['generation'] is num
            ? (response['generation'] as num).toInt()
            : null,
      );

  _IdentityCandidateBinding confirmed(int generation) =>
      _IdentityCandidateBinding(
        candidateId: candidateId,
        advertisedName: advertisedName,
        addressKey: addressKey,
        identityState: TuiIdentityState.confirmed,
        directedExactAddress: directedExactAddress,
        generation: generation,
      );
}
