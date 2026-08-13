library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'mac_bluetooth_transport.dart';

typedef MacBridgeProcessStarter = Future<Process> Function(String executable);

/// Supervises the macOS IOBluetooth helper and maps protocol-v1 JSON Lines to
/// the transport contract used by [WristloadBackend].
final class JsonLineMacBluetoothTransport implements MacBluetoothTransport {
  JsonLineMacBluetoothTransport({
    required this.executablePath,
    MacBridgeProcessStarter? processStarter,
  }) : _processStarter = processStarter ?? _defaultProcessStarter;

  static const int protocolVersion = 1;
  static const int _maxWriteChunkBytes = 256 * 1024;
  static const Duration _defaultRequestTimeout = Duration(seconds: 15);

  final String executablePath;
  final MacBridgeProcessStarter _processStarter;
  final StreamController<Uint8List> _input =
      StreamController<Uint8List>.broadcast(sync: true);
  final StreamController<Object> _errors =
      StreamController<Object>.broadcast(sync: true);
  final StreamController<MacBluetoothDevice> _discoveries =
      StreamController<MacBluetoothDevice>.broadcast(sync: true);
  final StreamController<MacBluetoothTransportSnapshot> _snapshots =
      StreamController<MacBluetoothTransportSnapshot>.broadcast(sync: true);
  final Map<String, _PendingRequest> _pending = {};
  final Set<String> _retiredConnectionIds = {};

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  Future<void>? _starting;
  Future<void> _stdinTail = Future<void>.value();
  Future<void> _writeTail = Future<void>.value();
  MacBluetoothTransportSnapshot _snapshot =
      const MacBluetoothTransportSnapshot.stopped();
  String _stderrTail = '';
  String? _helperSessionId;
  String? _connectionId;
  // Owns every native disconnect/cleanup operation. Replacement connects wait
  // for this future so the helper cannot still own an older connection ID.
  Future<void>? _disconnecting;
  String? _scanId;
  int _requestCounter = 0;
  int _connectionCounter = 0;
  int _scanCounter = 0;
  int _helperEpoch = 0;
  bool _disposing = false;
  bool _disposed = false;

  @override
  Stream<Uint8List> get input => _input.stream;
  @override
  Stream<Object> get errors => _errors.stream;
  @override
  Stream<MacBluetoothDevice> get discoveries => _discoveries.stream;
  @override
  Stream<MacBluetoothTransportSnapshot> get snapshots => _snapshots.stream;
  @override
  MacBluetoothTransportSnapshot get snapshot => _snapshot;

  static Future<Process> _defaultProcessStarter(String executable) =>
      Process.start(executable, const [], runInShell: false);

  @override
  Future<void> start() {
    if (_disposed) throw StateError('macOS Bluetooth transport 已释放。');
    if (_snapshot.helperState == MacBluetoothHelperState.ready) {
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
      helperState: MacBluetoothHelperState.starting,
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
        throw MacBluetoothProtocolException(
          'helper 协议不兼容：需要 v$protocolVersion，收到 ${version ?? '未知'}。',
        );
      }
      _helperSessionId = sessionId;
      _setSnapshot(
        helperState: MacBluetoothHelperState.ready,
        message: 'macOS Bluetooth helper 已就绪。',
      );
    } on Object catch (error, stack) {
      if (epoch == _helperEpoch) {
        _fatalSession(epoch, '启动 macOS Bluetooth helper 失败：$error', stack);
      }
      rethrow;
    }
  }

  @override
  Future<List<MacBluetoothDevice>> listPairedDevices() async {
    await start();
    final response = await _request(
      'paired.list',
      const {},
      expectedEvent: 'paired.list.done',
    );
    final raw = response['devices'];
    if (raw is! List) {
      throw const MacBluetoothProtocolException(
        'paired.list.done 缺少 devices 数组。',
      );
    }
    return [
      for (final item in raw)
        if (item is Map)
          _deviceFromJson(
            Map<String, Object?>.from(item),
            fallbackSource: MacBluetoothDeviceSource.paired,
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
      throw const MacBluetoothProtocolException('scan.started 的 scanId 不匹配。');
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
  Future<void> connect(
    MacBluetoothDevice device, {
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
    try {
      final response = await _request(
        'connect',
        {
          'connectionId': connectionId,
          'address': device.address,
          'serviceUuid': serviceUuid,
        },
        expectedEvent: 'connect.done',
        timeout: const Duration(seconds: 30),
      );
      if (response['connectionId'] != connectionId) {
        throw const MacBluetoothProtocolException(
          'connect.done 的 connectionId 不匹配。',
        );
      }
      _setSnapshot(connected: true, message: 'RFCOMM 已连接。');
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
      // retired and serialize an explicit cleanup before allowing reconnect.
      _retiredConnectionIds.add(connectionId);
      _scheduleConnectionCleanup(connectionId);
      _setSnapshot(connected: false, message: 'RFCOMM 连接失败。');
      rethrow;
    }
  }

  Future<bool> _disconnectTimedOutConnection(String connectionId) async {
    try {
      final response = await _request(
        'disconnect',
        {'connectionId': connectionId},
        expectedEvent: 'disconnect.done',
        ensureStarted: false,
        timeout: const Duration(seconds: 10),
      );
      return response['connectionId'] == connectionId;
    } on Object {
      // The original timeout is the caller-visible error. This best-effort
      // cleanup must not replace it or reattach the retired connection.
      return false;
    }
  }

  void _scheduleConnectionCleanup(String connectionId) {
    final previous = _disconnecting;
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
      final completed = await _disconnectTimedOutConnection(connectionId);
      if (completed && _connectionId == connectionId) {
        _connectionId = null;
        _setSnapshot(connected: false, message: 'RFCOMM 清理完成。');
      }
    })();
    _disconnecting = cleanup;
    unawaited(cleanup.then<void>(
      (_) => _finishDisconnectOperation(cleanup),
      onError: (Object _, StackTrace __) => _finishDisconnectOperation(cleanup),
    ));
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
          throw const MacBluetoothProtocolException(
            'write.done 的连接或字节数不匹配。',
          );
        }
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
    unawaited(operation.then<void>(
      (_) => _finishDisconnectOperation(operation),
      onError: (Object _, StackTrace __) =>
          _finishDisconnectOperation(operation),
    ));
    return operation;
  }

  void _finishDisconnectOperation(Future<void> operation) {
    if (identical(_disconnecting, operation)) _disconnecting = null;
  }

  Future<void> _disconnectCurrent(String connectionId) async {
    var completed = false;
    try {
      final response = await _request(
        'disconnect',
        {'connectionId': connectionId},
        expectedEvent: 'disconnect.done',
        timeout: const Duration(seconds: 10),
      );
      if (response['connectionId'] != connectionId) {
        throw const MacBluetoothProtocolException(
          'disconnect.done 的 connectionId 不匹配。',
        );
      }
      completed = true;
    } finally {
      if (completed && _connectionId == connectionId) _connectionId = null;
      _setSnapshot(connected: false, message: 'RFCOMM 已断开。');
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
    _pending[requestId] = _PendingRequest(expectedEvent, completer);
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
    final requestId = event['requestId'];
    var requestHandled = false;
    if (requestId is String) {
      final pending = _pending[requestId];
      if (pending != null) {
        if (eventName == 'error') {
          _pending.remove(requestId);
          requestHandled = true;
          pending.completer
              .completeError(MacBluetoothNativeException.fromJson(event));
        } else if (eventName == pending.expectedEvent) {
          _pending.remove(requestId);
          requestHandled = true;
          pending.completer.complete(event);
        }
      }
    }
    final connectionId = event['connectionId'];
    if (connectionId is String &&
        _retiredConnectionIds.contains(connectionId)) {
      // A timed-out connect is explicitly cancelled. Do not surface late
      // connect/error/data events from that generation to a newer session.
      return;
    }
    switch (eventName) {
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
        if (event['connectionId'] != _connectionId) return;
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
        if (event['connectionId'] != _connectionId) return;
        _connectionId = null;
        _setSnapshot(connected: false, message: 'RFCOMM 远端已关闭。');
        _input.add(Uint8List(0));
        return;
      case 'error':
        if (!requestHandled) {
          _errors.add(MacBluetoothNativeException.fromJson(event));
        }
        return;
      default:
        return;
    }
  }

  static MacBluetoothDevice _deviceFromJson(
    Map<String, Object?> value, {
    MacBluetoothDeviceSource? fallbackSource,
  }) {
    final address = value['address'];
    if (address is! String) {
      throw const MacBluetoothProtocolException('设备事件缺少 address。');
    }
    final source = switch (value['source']) {
      'paired' => MacBluetoothDeviceSource.paired,
      'inquiry' => MacBluetoothDeviceSource.inquiry,
      _ => fallbackSource ?? MacBluetoothDeviceSource.inquiry,
    };
    return MacBluetoothDevice(
      address: address,
      name: value['name'] is String ? value['name']! as String : '',
      rssi: _asInt(value['rssi']),
      paired:
          value['paired'] == true || source == MacBluetoothDeviceSource.paired,
      source: source,
    );
  }

  static int? _asInt(Object? value) => value is num ? value.toInt() : null;

  String _newScopedId(String prefix, int counter) =>
      '${_helperSessionId ?? 'starting'}-$prefix$counter';

  void _setSnapshot({
    MacBluetoothHelperState? helperState,
    bool? scanning,
    bool? connected,
    String? message,
  }) {
    _snapshot = MacBluetoothTransportSnapshot(
      helperState: helperState ?? _snapshot.helperState,
      scanning: scanning ?? _snapshot.scanning,
      connected: connected ?? _snapshot.connected,
      message: message,
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
    _retiredConnectionIds.clear();
    _scanId = null;
    final error = MacBluetoothProtocolException(message);
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
          ? MacBluetoothHelperState.disposed
          : reportError
              ? MacBluetoothHelperState.failed
              : MacBluetoothHelperState.stopped,
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
      _retiredConnectionIds.clear();
      await _stdoutSubscription?.cancel();
      await _stderrSubscription?.cancel();
      _snapshot = const MacBluetoothTransportSnapshot(
        helperState: MacBluetoothHelperState.disposed,
        scanning: false,
        connected: false,
        message: 'macOS Bluetooth transport 已释放。',
      );
      if (!_snapshots.isClosed) _snapshots.add(_snapshot);
      await _input.close();
      await _errors.close();
      await _discoveries.close();
      await _snapshots.close();
    }
  }
}

final class MacBluetoothNativeException implements Exception {
  const MacBluetoothNativeException(this.code, this.message);

  factory MacBluetoothNativeException.fromJson(Map<String, Object?> value) =>
      MacBluetoothNativeException(
        value['code'] is String ? value['code']! as String : 'native_error',
        value['message'] is String
            ? value['message']! as String
            : '原生 helper 错误',
      );

  final String code;
  final String message;

  @override
  String toString() => 'MacBluetoothNativeException($code): $message';
}

final class MacBluetoothProtocolException implements Exception {
  const MacBluetoothProtocolException(this.message);

  final String message;

  @override
  String toString() => 'MacBluetoothProtocolException: $message';
}

final class _PendingRequest {
  const _PendingRequest(this.expectedEvent, this.completer);

  final String expectedEvent;
  final Completer<Map<String, Object?>> completer;
}
