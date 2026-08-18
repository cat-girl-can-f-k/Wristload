/// TUI-owned transport boundary for macOS classic Bluetooth.
///
/// This file intentionally contains only immutable transport DTOs and the
/// narrow operations the standalone TUI needs. JSONL/native details live in a
/// separate bridge implementation and never leak into the application layer.
library;

import 'dart:typed_data';

final class TuiBluetoothAddress {
  TuiBluetoothAddress._(this.key);

  factory TuiBluetoothAddress.parse(String value) {
    final input = value.trim();
    final compact = switch (input) {
      _ when RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(input) => input,
      _
          when RegExp(r'^(?:[0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2}$')
              .hasMatch(input) =>
        input.replaceAll('-', ''),
      _
          when RegExp(r'^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$')
              .hasMatch(input) =>
        input.replaceAll(':', ''),
      _ => throw const FormatException('经典蓝牙地址必须是 12 位十六进制，可使用连字符或冒号分隔。'),
    };
    return TuiBluetoothAddress._(compact.toUpperCase());
  }

  final String key;

  String get display => [
        for (var offset = 0; offset < key.length; offset += 2)
          key.substring(offset, offset + 2),
      ].join('-');

  @override
  bool operator ==(Object other) =>
      other is TuiBluetoothAddress && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

enum TuiTransportDeviceSource { inquiry, paired, manual }

/// Whether a Classic address has been independently verified for a scanned
/// candidate. A provisional result is intentionally not treated as a pairing
/// or a post-session identity proof.
enum TuiIdentityState { unresolved, provisional, confirmed }

enum TuiIdentityResolution {
  confirmed,
  provisional,
  uniquePaired,
  needsSelection,
  notPaired,
  directClassic,
}

enum TuiPairingStageKind {
  resolving,
  pairingStarted,
  waitingPin,
  waitingConfirmation,
  completed,
  failed,
  cancelled,
}

final class TuiIdentityCandidate {
  TuiIdentityCandidate({
    required String candidateId,
    required String advertisedName,
    String? address,
    this.directedExactAddress = false,
  })  : candidateId = _requiredId(candidateId, 'candidateId'),
        advertisedName = _requiredId(advertisedName, 'advertisedName'),
        bluetoothAddress =
            address == null ? null : TuiBluetoothAddress.parse(address);

  final String candidateId;
  final String advertisedName;
  final TuiBluetoothAddress? bluetoothAddress;

  /// Explicit short-lived authorization to resolve this exact Classic address
  /// even when native Bluetooth has no usable device name. It is granted only
  /// by a user selecting this current Classic discovery row or by an explicit
  /// temporary launch target; it is never inferred merely because an address
  /// appears in scan results or saved state.
  final bool directedExactAddress;

  String? get address => bluetoothAddress?.display;
  String? get addressKey => bluetoothAddress?.key;
}

final class TuiIdentityResolutionResult {
  const TuiIdentityResolutionResult({
    required this.candidateId,
    required this.resolution,
    required this.identityState,
    this.device,
    this.matchMode,
    this.generation,
  });

  final String candidateId;
  final TuiIdentityResolution resolution;
  final TuiIdentityState identityState;
  final TuiTransportDevice? device;
  final String? matchMode;
  final int? generation;
}

final class TuiPairingStage {
  const TuiPairingStage({
    required this.pairingId,
    required this.candidateId,
    required this.stage,
    required this.timestamp,
    this.generation,
    this.message,
    this.nativeDomain,
    this.nativeCode,
  });

  final String pairingId;
  final String candidateId;
  final TuiPairingStageKind stage;
  final DateTime timestamp;
  final int? generation;
  final String? message;
  final String? nativeDomain;
  final int? nativeCode;
}

final class TuiPairingResult {
  const TuiPairingResult({
    required this.pairingId,
    required this.candidateId,
    required this.identityState,
    required this.device,
    this.matchMode,
    this.generation,
  });

  final String pairingId;
  final String candidateId;
  final TuiIdentityState identityState;
  final TuiTransportDevice device;
  final String? matchMode;
  final int? generation;
}

final class TuiIdentityConfirmation {
  TuiIdentityConfirmation({
    required String candidateId,
    required String advertisedName,
    required String address,
    required String connectionId,

    /// When omitted, the transport uses the currently owned native RFCOMM
    /// generation. A supplied value must equal that generation.
    this.generation,
  })  : candidateId = _requiredId(candidateId, 'candidateId'),
        advertisedName = _requiredId(advertisedName, 'advertisedName'),
        bluetoothAddress = TuiBluetoothAddress.parse(address),
        connectionId = _requiredId(connectionId, 'connectionId');

  final String candidateId;
  final String advertisedName;
  final TuiBluetoothAddress bluetoothAddress;
  final String connectionId;
  final int? generation;

  String get address => bluetoothAddress.display;
  String get addressKey => bluetoothAddress.key;
}

final class TuiIdentityForgetResult {
  const TuiIdentityForgetResult({
    required this.candidateId,
    required this.forgotten,
    required this.unpaired,
    required this.disconnected,
  });

  final String candidateId;
  final bool forgotten;
  final bool unpaired;
  final bool disconnected;
}

final class TuiTransportDevice {
  TuiTransportDevice({
    required String address,
    required this.name,
    this.rssi,
    this.paired = false,
    this.source = TuiTransportDeviceSource.manual,
  }) : bluetoothAddress = TuiBluetoothAddress.parse(address);

  TuiTransportDevice.fromAddress({
    required this.bluetoothAddress,
    required this.name,
    this.rssi,
    this.paired = false,
    this.source = TuiTransportDeviceSource.manual,
  });

  final TuiBluetoothAddress bluetoothAddress;
  final String name;
  final int? rssi;
  final bool paired;
  final TuiTransportDeviceSource source;

  String get address => bluetoothAddress.display;
  String get addressKey => bluetoothAddress.key;

  TuiTransportDevice merge(TuiTransportDevice other) {
    if (addressKey != other.addressKey) {
      throw ArgumentError('不能合并不同经典蓝牙地址的设备。');
    }
    return TuiTransportDevice.fromAddress(
      bluetoothAddress: bluetoothAddress,
      name: other.name.trim().isNotEmpty ? other.name : name,
      rssi: other.rssi ?? rssi,
      paired: paired || other.paired,
      source: other.paired ? other.source : source,
    );
  }
}

enum TuiMacHelperState { stopped, starting, ready, failed, disposed }

final class TuiMacTransportSnapshot {
  const TuiMacTransportSnapshot({
    required this.helperState,
    required this.scanning,
    required this.connected,
    this.message,
    this.transport,
    this.endpoint,
    this.serviceUuid,
    this.channel,
    this.mtu,
    this.helperSessionId,
    this.sessionId,
    this.connectionId,
    this.connectionGeneration,
    this.addressKey,
    this.stage,
    this.stageCode,
    this.stageDetail,
  });

  const TuiMacTransportSnapshot.stopped()
      : this(
          helperState: TuiMacHelperState.stopped,
          scanning: false,
          connected: false,
        );

  final TuiMacHelperState helperState;
  final bool scanning;
  final bool connected;
  final String? message;

  /// Native transport evidence. These fields are deliberately nullable: a
  /// helper may report only lifecycle state before an endpoint is selected.
  final String? transport;
  final String? endpoint;
  final String? serviceUuid;
  final int? channel;
  final int? mtu;
  final String? helperSessionId;
  final String? sessionId;
  final String? connectionId;

  /// Native RFCOMM attempt generation. This is separate from any UI state
  /// revision and fences identity confirmation to the physical connection.
  final int? connectionGeneration;
  final String? addressKey;

  /// The helper's raw stage name (for example `sdp.started` or
  /// `rfcomm.open.completed`) and optional structured detail. Keeping the raw
  /// name avoids losing forward-compatible native stages.
  final String? stage;
  final String? stageCode;
  final String? stageDetail;

  /// Generic physical-session identity, preferring the connection generation
  /// and falling back to the helper process session.
  String? get activeSessionId => sessionId ?? connectionId ?? helperSessionId;

  TuiMacTransportSnapshot copyWith({
    TuiMacHelperState? helperState,
    bool? scanning,
    bool? connected,
    Object? message = _unset,
    Object? transport = _unset,
    Object? endpoint = _unset,
    Object? serviceUuid = _unset,
    Object? channel = _unset,
    Object? mtu = _unset,
    Object? helperSessionId = _unset,
    Object? sessionId = _unset,
    Object? connectionId = _unset,
    Object? connectionGeneration = _unset,
    Object? addressKey = _unset,
    Object? stage = _unset,
    Object? stageCode = _unset,
    Object? stageDetail = _unset,
  }) =>
      TuiMacTransportSnapshot(
        helperState: helperState ?? this.helperState,
        scanning: scanning ?? this.scanning,
        connected: connected ?? this.connected,
        message: identical(message, _unset) ? this.message : message as String?,
        transport: identical(transport, _unset)
            ? this.transport
            : transport as String?,
        endpoint:
            identical(endpoint, _unset) ? this.endpoint : endpoint as String?,
        serviceUuid: identical(serviceUuid, _unset)
            ? this.serviceUuid
            : serviceUuid as String?,
        channel: identical(channel, _unset) ? this.channel : channel as int?,
        mtu: identical(mtu, _unset) ? this.mtu : mtu as int?,
        helperSessionId: identical(helperSessionId, _unset)
            ? this.helperSessionId
            : helperSessionId as String?,
        sessionId: identical(sessionId, _unset)
            ? this.sessionId
            : sessionId as String?,
        connectionId: identical(connectionId, _unset)
            ? this.connectionId
            : connectionId as String?,
        connectionGeneration: identical(connectionGeneration, _unset)
            ? this.connectionGeneration
            : connectionGeneration as int?,
        addressKey: identical(addressKey, _unset)
            ? this.addressKey
            : addressKey as String?,
        stage: identical(stage, _unset) ? this.stage : stage as String?,
        stageCode: identical(stageCode, _unset)
            ? this.stageCode
            : stageCode as String?,
        stageDetail: identical(stageDetail, _unset)
            ? this.stageDetail
            : stageDetail as String?,
      );

  factory TuiMacTransportSnapshot.fromJson(Map<String, Object?> value) =>
      TuiMacTransportSnapshot(
        helperState: _helperStateFromJson(value['helperState']),
        scanning: value['scanning'] == true,
        connected: value['connected'] == true,
        message: _string(value['message']),
        transport: _string(value['transport']),
        endpoint: _string(value['endpoint']),
        serviceUuid: _string(value['serviceUuid']),
        channel: _int(value['channel']),
        mtu: _int(value['mtu'] ?? value['mtuBytes']),
        helperSessionId: _string(value['helperSessionId']),
        sessionId: _string(value['sessionId']),
        connectionId: _string(value['connectionId']),
        connectionGeneration:
            _int(value['connectionGeneration'] ?? value['generation']),
        addressKey: _string(value['addressKey']),
        stage: _string(value['stage']),
        stageCode: _string(value['stageCode']),
        stageDetail: _string(value['stageDetail'] ?? value['stageMessage']),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'helperState': helperState.name,
        'scanning': scanning,
        'connected': connected,
        if (message != null) 'message': message,
        if (transport != null) 'transport': transport,
        if (endpoint != null) 'endpoint': endpoint,
        if (serviceUuid != null) 'serviceUuid': serviceUuid,
        if (channel != null) 'channel': channel,
        if (mtu != null) 'mtu': mtu,
        if (helperSessionId != null) 'helperSessionId': helperSessionId,
        if (sessionId != null) 'sessionId': sessionId,
        if (connectionId != null) 'connectionId': connectionId,
        if (connectionGeneration != null)
          'connectionGeneration': connectionGeneration,
        if (addressKey != null) 'addressKey': addressKey,
        if (stage != null) 'stage': stage,
        if (stageCode != null) 'stageCode': stageCode,
        if (stageDetail != null) 'stageDetail': stageDetail,
      };
}

const Object _unset = Object();
String? _string(Object? value) =>
    value is String && value.isNotEmpty ? value : null;
int? _int(Object? value) => value is num ? value.toInt() : null;
TuiMacHelperState _helperStateFromJson(Object? value) => switch (value) {
      'starting' => TuiMacHelperState.starting,
      'ready' => TuiMacHelperState.ready,
      'failed' => TuiMacHelperState.failed,
      'disposed' => TuiMacHelperState.disposed,
      _ => TuiMacHelperState.stopped,
    };

abstract interface class TuiMacBluetoothTransport {
  Stream<Uint8List> get input;
  Stream<Object> get errors;
  Stream<TuiTransportDevice> get discoveries;
  Stream<TuiPairingStage> get pairingStages;
  Stream<TuiMacTransportSnapshot> get snapshots;

  TuiMacTransportSnapshot get snapshot;

  Future<void> start();
  Future<List<TuiTransportDevice>> listPairedDevices();
  Future<void> startScan({Duration duration = const Duration(seconds: 10)});
  Future<void> stopScan();

  /// Resolves an inquiry/BLE candidate to a TUI-owned Classic identity.
  /// Callers must not treat [TuiIdentityState.provisional] as confirmation.
  Future<TuiIdentityResolutionResult> resolveIdentity(
    TuiIdentityCandidate candidate,
  );

  /// Starts directed macOS system pairing for a prior [resolveIdentity]
  /// binding with an exact Classic address. Native stage updates are emitted on
  /// [pairingStages] and terminal success is represented by the returned value.
  Future<TuiPairingResult> startPairing(TuiIdentityCandidate candidate);
  Future<void> cancelPairing({String? pairingId});

  /// Confirms the candidate after a successful session. The implementation
  /// must reject a connection ID or generation it does not currently own.
  Future<TuiIdentityResolutionResult> confirmIdentity(
    TuiIdentityConfirmation confirmation,
  );

  /// Removes only TUI-owned identity metadata. It does not imply unpairing or
  /// disconnecting a macOS Bluetooth device.
  Future<TuiIdentityForgetResult> forgetIdentity(String candidateId);
  Future<void> connect(
    TuiTransportDevice device, {
    String serviceUuid = '00001101-0000-1000-8000-00805f9b34fb',
  });
  Future<void> write(List<int> bytes);
  Future<void> disconnect();
  Future<void> dispose();
}

final class TuiNativeTransportException implements Exception {
  const TuiNativeTransportException(
    this.code,
    this.message, {
    this.domain,
    this.nativeCode,
    this.transport,
    this.endpoint,
    this.serviceUuid,
    this.channel,
    this.mtu,
    this.helperSessionId,
    this.sessionId,
    this.connectionId,
    this.addressKey,
    this.stage,
    this.stageCode,
    this.stageDetail,
    this.generation,
  });

  factory TuiNativeTransportException.fromJson(Map<String, Object?> value) =>
      TuiNativeTransportException(
        value['code'] is String
            ? value['code']! as String
            : value['errorCode'] is String
                ? value['errorCode']! as String
                : 'native_error',
        value['message'] is String
            ? value['message']! as String
            : value['errorMessage'] is String
                ? value['errorMessage']! as String
                : '原生 helper 错误',
        domain: _string(value['domain'] ?? value['errorDomain']),
        nativeCode: _int(value['nativeCode'] ??
            value['osStatus'] ??
            (value['errorCode'] is num ? value['errorCode'] : null)),
        transport: _string(value['transport']),
        endpoint: _string(value['endpoint']),
        serviceUuid: _string(value['serviceUuid']),
        channel: _int(value['channel']),
        mtu: _int(value['mtu'] ?? value['mtuBytes']),
        helperSessionId: _string(value['helperSessionId']),
        sessionId: _string(value['sessionId']),
        connectionId: _string(value['connectionId']),
        addressKey: _string(value['addressKey']),
        stage: _string(value['stage']),
        stageCode: _string(value['stageCode']),
        stageDetail: _string(value['stageDetail'] ?? value['stageMessage']),
        generation: _int(value['generation']),
      );

  final String code;
  final String message;
  final String? domain;
  final int? nativeCode;
  final String? transport;
  final String? endpoint;
  final String? serviceUuid;
  final int? channel;
  final int? mtu;
  final String? helperSessionId;
  final String? sessionId;
  final String? connectionId;
  final String? addressKey;
  final String? stage;
  final String? stageCode;
  final String? stageDetail;
  final int? generation;

  String? get activeSessionId => sessionId ?? connectionId ?? helperSessionId;
  String? get errorDomain => domain;
  int? get errorCodeValue => nativeCode;

  @override
  String toString() => domain == null
      ? 'TuiNativeTransportException($code): $message'
      : 'TuiNativeTransportException($domain/$nativeCode $code): $message';
}

final class TuiTransportProtocolException implements Exception {
  const TuiTransportProtocolException(this.message);

  final String message;

  @override
  String toString() => 'TuiTransportProtocolException: $message';
}

String _requiredId(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, '不能为空');
  }
  return normalized;
}
