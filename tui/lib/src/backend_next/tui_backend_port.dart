/// Minimal backend boundary owned by the standalone Wristload TUI.
///
/// This contract intentionally has no dependency on terminal widgets, Flutter,
/// or the legacy frontend DTOs. Bluetooth and installation work is performed by
/// the implementation and reported as immutable snapshots.
library;

import '../domain/device_profile.dart';
import '../domain/install_models.dart';

enum TuiBackendHelperState { stopped, starting, ready, failed, disposed }

enum TuiBackendConnectionState {
  disconnected,
  connecting,
  awaitingAuthKey,
  authenticating,
  ready,
}

enum TuiBackendInstallState {
  idle,
  validating,
  waitingForProtocol,
  transferring,
  awaitingDevice,
  succeeded,
  cancelled,
  stateUnknown,
  failed,
}

enum TuiBackendDeviceSource { inquiry, paired, manual }

enum TuiBackendIdentityState { unresolved, provisional, confirmed }

final class TuiBackendDevice {
  const TuiBackendDevice({
    required this.address,
    required this.addressKey,
    required this.name,
    required this.paired,
    required this.sources,
    this.profile,
    this.rssi,
  });

  final String address;
  final String addressKey;
  final String name;
  final DeviceProfile? profile;
  final bool paired;
  final int? rssi;
  final Set<TuiBackendDeviceSource> sources;

  bool get supported => profile?.generation == ProtocolGeneration.v2Vela;
}

/// Explicit Xiaomi WearAuthV2 binding material for one connection attempt.
/// This DTO never derives values from a Bluetooth address or authkey.
final class TuiBackendBindingMaterial {
  TuiBackendBindingMaterial({required this.appDeviceId, this.oob}) {
    if (appDeviceId.trim().isEmpty) {
      throw ArgumentError.value(appDeviceId, 'appDeviceId');
    }
    if (oob != null && oob!.trim().isEmpty) {
      throw ArgumentError.value(oob, 'oob');
    }
  }

  final String appDeviceId;
  final String? oob;

  bool get hasOob => oob != null;
}

final class TuiBackendInstallation {
  const TuiBackendInstallation({
    required this.state,
    required this.fileName,
    required this.message,
    this.confirmedBytes,
    this.queuedBytes,
    this.totalBytes,
    this.bytesPerSecond,
    this.successVerifiedByDeviceBusinessEvent = false,
  });

  final TuiBackendInstallState state;
  final String fileName;
  final String message;
  final int? confirmedBytes;
  final int? queuedBytes;
  final int? totalBytes;
  final double? bytesPerSecond;

  /// True only after the matching device-side business completion event.
  final bool successVerifiedByDeviceBusinessEvent;
}

final class TuiBackendSnapshot {
  const TuiBackendSnapshot({
    required this.revision,
    required this.helperState,
    required this.scanning,
    required this.transportConnected,
    required this.connection,
    required this.devices,
    required this.authKeyLoaded,
    this.activeDeviceAddress,
    this.identityCandidateId,
    this.identityState,
    this.identityGeneration,
    this.connectionId,
    this.connectionGeneration,
    this.applicationAttemptGeneration,
    this.protocolAuthenticated = false,
    this.message,
    this.failureCode,
    this.installation,
  });

  final int revision;
  final TuiBackendHelperState helperState;
  final bool scanning;
  final bool transportConnected;
  final TuiBackendConnectionState connection;
  final List<TuiBackendDevice> devices;
  final String? activeDeviceAddress;
  final String? identityCandidateId;
  final TuiBackendIdentityState? identityState;
  final int? identityGeneration;
  final String? connectionId;

  /// Logical application connection-attempt generation. This fences stale
  /// UI/application work and is intentionally separate from the native
  /// RFCOMM [connectionGeneration].
  final int? connectionGeneration;
  final int? applicationAttemptGeneration;
  final bool protocolAuthenticated;
  final String? message;
  final String? failureCode;
  final TuiBackendInstallation? installation;

  /// Indicates only whether the protocol backend has a key in memory.
  /// The key itself must never cross this boundary.
  final bool authKeyLoaded;
}

abstract interface class TuiBackendPort {
  TuiBackendSnapshot get snapshot;
  Stream<TuiBackendSnapshot> get snapshots;

  Future<void> initialize();
  Future<void> refreshPairedDevices();
  Future<void> startScan({Duration duration = const Duration(seconds: 10)});
  Future<void> stopScan();

  /// Connects directly by classic Bluetooth MAC address without requiring a
  /// current inquiry result. This is the path used by saved-device reconnect.
  Future<void> connectByAddress({
    required String address,
    required String name,
    DeviceProfile? profile,
    bool requireConfirmedIdentity = false,

    /// True only when the user explicitly selected this exact Classic address
    /// from a current Classic discovery row, or supplied it as a temporary
    /// launch target. Saved-device reconnect and auto-connect leave this
    /// false.
    bool directedExactAddress = false,
    int? attemptGeneration,

    /// Optional explicit Xiaomi material for this device. A null value uses
    /// the official Classic nonce-only f=26 branch; callers must never derive
    /// a replacement from the address or authkey.
    required TuiBackendBindingMaterial? bindingMaterial,
  });

  Future<void> confirmActiveIdentity({required int attemptGeneration});

  /// Loads a key into protocol memory. Implementations must not log or publish
  /// the value. This may be called before connectByAddress for auto-connect.
  Future<void> provideAuthKey(String authKey);
  Future<void> clearAuthKey();
  Future<void> disconnect();
  Future<void> install(InstallRequest request);
  Future<void> cancelInstall();
  Future<void> dispose();
}
