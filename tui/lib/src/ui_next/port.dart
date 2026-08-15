import 'dart:async';

import 'cell_width.dart';

enum UiDeviceSupport { supported, unsupported, unknown }

enum UiConnectionPhase {
  disconnected,
  connecting,
  awaitingAuthKey,
  authenticating,
  ready,
  disconnecting,
  failed,
}

enum UiInstallPhase {
  idle,
  preparing,
  transferring,
  awaitingDevice,
  succeeded,
  failed,
  unknown,
}

enum UiAutoConnectState {
  disabled,
  idle,
  connecting,
  ready,
  noSavedDevice,
  missingAuthKey,
  failed,
  suppressedAfterDisconnect,
}

class UiDevice {
  UiDevice({
    required String name,
    required String macAddress,
    required this.support,
    this.saved = false,
    this.savedAuthKey,
    this.connected = false,
  })  : name = _displayName(name),
        macAddress = normalizeMac(macAddress);

  final String name;
  final String macAddress;
  final UiDeviceSupport support;
  final bool saved;
  final String? savedAuthKey;
  final bool connected;

  String get id => macAddress;
  String get authKeyLabel =>
      savedAuthKey?.isNotEmpty == true ? savedAuthKey! : '-';

  static String normalizeMac(String value) {
    final compact = value.trim().replaceAll(RegExp(r'[:-]'), '');
    if (!RegExp(r'^[0-9a-fA-F]{12}$').hasMatch(compact)) {
      throw const FormatException(
          'MAC address must contain 12 hexadecimal digits.');
    }
    final upper = compact.toUpperCase();
    return List.generate(
      6,
      (index) => upper.substring(index * 2, index * 2 + 2),
    ).join(':');
  }

  static String _displayName(String value) {
    final normalized = UiCellWidth.sanitizeText(value).trim();
    return normalized.isEmpty ? '未知设备' : normalized;
  }

  UiDevice copyWith({
    String? name,
    String? macAddress,
    UiDeviceSupport? support,
    bool? saved,
    String? savedAuthKey,
    bool clearSavedAuthKey = false,
    bool? connected,
  }) {
    return UiDevice(
      name: name ?? this.name,
      macAddress: macAddress ?? this.macAddress,
      support: support ?? this.support,
      saved: saved ?? this.saved,
      savedAuthKey:
          clearSavedAuthKey ? null : (savedAuthKey ?? this.savedAuthKey),
      connected: connected ?? this.connected,
    );
  }
}

class UiInstallStatus {
  const UiInstallStatus({
    this.phase = UiInstallPhase.idle,
    this.fileName,
    this.confirmedBytes = 0,
    this.totalBytes = 0,
    this.message,
    this.successVerifiedByDeviceBusinessEvent = false,
  });

  final UiInstallPhase phase;
  final String? fileName;
  final int confirmedBytes;
  final int totalBytes;
  final String? message;

  /// `true` only after the device has emitted the matching business-complete
  /// event. A completed byte stream alone is not an installation success.
  final bool successVerifiedByDeviceBusinessEvent;

  int get percent => totalBytes <= 0
      ? 0
      : ((confirmedBytes.clamp(0, totalBytes) * 100) ~/ totalBytes);

  UiInstallStatus copyWith({
    UiInstallPhase? phase,
    String? fileName,
    bool clearFileName = false,
    int? confirmedBytes,
    int? totalBytes,
    String? message,
    bool clearMessage = false,
    bool? successVerifiedByDeviceBusinessEvent,
  }) {
    return UiInstallStatus(
      phase: phase ?? this.phase,
      fileName: clearFileName ? null : (fileName ?? this.fileName),
      confirmedBytes: confirmedBytes ?? this.confirmedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      message: clearMessage ? null : (message ?? this.message),
      successVerifiedByDeviceBusinessEvent:
          successVerifiedByDeviceBusinessEvent ??
              this.successVerifiedByDeviceBusinessEvent,
    );
  }
}

class UiSnapshot {
  UiSnapshot({
    this.revision = 0,
    List<UiDevice> devices = const [],
    this.connectionPhase = UiConnectionPhase.disconnected,
    this.connectedDeviceId,
    this.scanning = false,
    this.autoConnect = false,
    this.autoConnectState = UiAutoConnectState.idle,
    this.themeId = 'black-blue',
    this.install = const UiInstallStatus(),
    this.notice,
    this.error,
  }) : devices = List.unmodifiable(devices);

  final int revision;
  final List<UiDevice> devices;
  final UiConnectionPhase connectionPhase;
  final String? connectedDeviceId;
  final bool scanning;
  final bool autoConnect;
  final UiAutoConnectState autoConnectState;
  final String themeId;
  final UiInstallStatus install;
  final String? notice;
  final String? error;

  UiSnapshot copyWith({
    int? revision,
    List<UiDevice>? devices,
    UiConnectionPhase? connectionPhase,
    String? connectedDeviceId,
    bool clearConnectedDeviceId = false,
    bool? scanning,
    bool? autoConnect,
    UiAutoConnectState? autoConnectState,
    String? themeId,
    UiInstallStatus? install,
    String? notice,
    bool clearNotice = false,
    String? error,
    bool clearError = false,
  }) {
    return UiSnapshot(
      revision: revision ?? this.revision,
      devices: devices ?? this.devices,
      connectionPhase: connectionPhase ?? this.connectionPhase,
      connectedDeviceId: clearConnectedDeviceId
          ? null
          : (connectedDeviceId ?? this.connectedDeviceId),
      scanning: scanning ?? this.scanning,
      autoConnect: autoConnect ?? this.autoConnect,
      autoConnectState: autoConnectState ?? this.autoConnectState,
      themeId: themeId ?? this.themeId,
      install: install ?? this.install,
      notice: clearNotice ? null : (notice ?? this.notice),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class UiActionResult {
  const UiActionResult._(this.accepted, this.message);

  const UiActionResult.accepted([String? message]) : this._(true, message);
  const UiActionResult.rejected(String message) : this._(false, message);

  final bool accepted;
  final String? message;
}

/// UI-facing boundary. Implementations translate intent into application
/// events; the render loop never calls Bluetooth or native APIs directly.
abstract interface class UiNextPort {
  UiSnapshot get snapshot;
  Stream<UiSnapshot> get snapshots;

  Future<UiActionResult> initialize();
  Future<UiActionResult> scan();
  Future<UiActionResult> connect(String macAddress);
  Future<UiActionResult> disconnect();
  Future<UiActionResult> saveDevice(String macAddress);
  Future<UiActionResult> removeSavedDevice(String macAddress);
  Future<UiActionResult> submitAuthKey(String macAddress, String authKey);
  Future<UiActionResult> installResource(String macAddress, String path);
  Future<UiActionResult> cancelInstall();
  Future<UiActionResult> setAutoConnect(bool enabled);
  Future<UiActionResult> setThemeId(String themeId);
  Future<void> dispose();
}
