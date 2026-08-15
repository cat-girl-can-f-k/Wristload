/// Immutable UI-neutral state published by the standalone TUI application.
library;

import 'persistence/saved_tui_device.dart';

/// Whether the TUI can use the known installation protocol for a device.
enum TuiApplicationDeviceSupport { supported, unsupported, unknown }

/// Connection state intentionally expressed without native transport details.
enum TuiApplicationConnectionState {
  disconnected,
  connecting,
  awaitingAuthKey,
  authenticating,
  ready,
  disconnecting,
  failed,
}

/// Auto-connect outcome for the current TUI process lifetime.
enum TuiApplicationAutoConnectState {
  disabled,
  idle,
  connecting,
  ready,
  noSavedDevice,
  missingAuthKey,
  failed,
  suppressedAfterDisconnect,
}

/// Installation stages the TUI needs to render without interpreting packets.
enum TuiApplicationInstallPhase {
  idle,
  preparing,
  transferring,
  awaitingDevice,
  succeeded,
  failed,
  unknown,
}

/// A device record rendered by the TUI. Its identity is always [macAddress].
final class TuiApplicationDevice {
  TuiApplicationDevice({
    required this.name,
    required String macAddress,
    required this.support,
    required this.saved,
    required this.connected,
    this.savedAuthKey,
    this.profileId,
    this.profileName,
    this.paired = false,
    this.rssi,
  }) : macAddress = SavedTuiDevice.normalizeMacAddress(macAddress);

  /// Complete display name. Renderers may wrap it but must not lose access.
  final String name;
  final String macAddress;
  final TuiApplicationDeviceSupport support;
  final bool saved;
  final bool connected;

  /// The complete key is intentionally exposed to the TUI only because the
  /// product requires it to be visibly inspectable for a saved device. It must
  /// never be added to logs, notices, errors, or `toString()` output.
  final String? savedAuthKey;
  final String? profileId;
  final String? profileName;
  final bool paired;
  final int? rssi;

  String get id => macAddress;
  String get authKeyLabel =>
      savedAuthKey == null || savedAuthKey!.isEmpty ? '-' : savedAuthKey!;

  TuiApplicationDevice copyWith({
    String? name,
    String? macAddress,
    TuiApplicationDeviceSupport? support,
    bool? saved,
    bool? connected,
    String? savedAuthKey,
    bool clearSavedAuthKey = false,
    String? profileId,
    bool clearProfileId = false,
    String? profileName,
    bool clearProfileName = false,
    bool? paired,
    int? rssi,
    bool clearRssi = false,
  }) {
    return TuiApplicationDevice(
      name: name ?? this.name,
      macAddress: macAddress ?? this.macAddress,
      support: support ?? this.support,
      saved: saved ?? this.saved,
      connected: connected ?? this.connected,
      savedAuthKey:
          clearSavedAuthKey ? null : (savedAuthKey ?? this.savedAuthKey),
      profileId: clearProfileId ? null : (profileId ?? this.profileId),
      profileName: clearProfileName ? null : (profileName ?? this.profileName),
      paired: paired ?? this.paired,
      rssi: clearRssi ? null : (rssi ?? this.rssi),
    );
  }
}

/// Installation progress is controlled by the backend, not the renderer.
final class TuiApplicationInstallStatus {
  const TuiApplicationInstallStatus({
    this.phase = TuiApplicationInstallPhase.idle,
    this.fileName,
    this.confirmedBytes = 0,
    this.totalBytes = 0,
    this.message,
    this.successVerifiedByDeviceBusinessEvent = false,
  });

  final TuiApplicationInstallPhase phase;
  final String? fileName;
  final int confirmedBytes;
  final int totalBytes;
  final String? message;

  /// `true` only after a device business-completion event, never merely after
  /// bytes were submitted or an RFCOMM ACK was received.
  final bool successVerifiedByDeviceBusinessEvent;

  int get percent => totalBytes <= 0
      ? 0
      : ((confirmedBytes.clamp(0, totalBytes) * 100) ~/ totalBytes);
}

/// Last action result. It holds only safe user-facing diagnostics.
final class TuiApplicationActionResult {
  const TuiApplicationActionResult({
    required this.accepted,
    required this.code,
    required this.message,
  });

  const TuiApplicationActionResult.success(
    String message, {
    String code = 'ok',
  }) : this(accepted: true, code: code, message: message);

  const TuiApplicationActionResult.failure(
    String code,
    String message,
  ) : this(accepted: false, code: code, message: message);

  final bool accepted;
  final String code;
  final String message;

  @override
  String toString() =>
      'TuiApplicationActionResult(accepted: $accepted, code: $code)';
}

/// The sole snapshot vocabulary consumed by the new TUI frontend.
final class TuiApplicationSnapshot {
  TuiApplicationSnapshot({
    required this.revision,
    required List<TuiApplicationDevice> devices,
    required this.connection,
    required this.scanning,
    required this.autoConnectEnabled,
    required this.autoConnectState,
    required this.themeId,
    required this.installation,
    this.activeDeviceId,
    this.notice,
    this.error,
  }) : devices = List.unmodifiable(devices);

  final int revision;
  final List<TuiApplicationDevice> devices;
  final TuiApplicationConnectionState connection;
  final String? activeDeviceId;
  final bool scanning;
  final bool autoConnectEnabled;
  final TuiApplicationAutoConnectState autoConnectState;
  final String themeId;
  final TuiApplicationInstallStatus installation;
  final String? notice;
  final String? error;

  bool get ready => connection == TuiApplicationConnectionState.ready;
}
