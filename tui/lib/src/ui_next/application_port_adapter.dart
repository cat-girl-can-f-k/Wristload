/// UI adapter for the standalone TUI application layer.
///
/// This is the only replacement-frontend dependency on application DTOs. It
/// translates immutable application state into terminal state and translates
/// user intent back into application actions; it never touches Bluetooth,
/// protocol, persistence files, or native APIs directly.
library;

import '../application/tui_application.dart';
import '../application/tui_application_snapshot.dart';
import 'port.dart';

final class TuiApplicationUiPortAdapter implements UiNextPort {
  TuiApplicationUiPortAdapter({required TuiApplicationPort application})
      : _application = application;

  final TuiApplicationPort _application;

  @override
  UiSnapshot get snapshot => _mapSnapshot(_application.snapshot);

  @override
  Stream<UiSnapshot> get snapshots => _application.snapshots.map(_mapSnapshot);

  @override
  Future<UiActionResult> initialize() => _mapAction(_application.initialize());

  @override
  Future<UiActionResult> scan() {
    return _mapAction(
      _application.snapshot.scanning
          ? _application.stopScan()
          : _application.startScan(),
    );
  }

  @override
  Future<UiActionResult> connect(String macAddress) =>
      _mapAction(_application.connectSelectedScannedDevice(macAddress));

  @override
  Future<UiActionResult> connectDirectedExactAddress() =>
      _mapAction(_application.connectDirectedExactAddress());

  @override
  Future<UiActionResult> disconnect() => _mapAction(_application.disconnect());

  @override
  Future<UiActionResult> saveDevice(String macAddress) =>
      _mapAction(_application.saveDevice(macAddress));

  @override
  Future<UiActionResult> removeSavedDevice(String macAddress) =>
      _mapAction(_application.removeSavedDevice(macAddress));

  @override
  Future<UiActionResult> submitAuthKey(String macAddress, String authKey) =>
      _mapAction(_application.submitAuthKey(macAddress, authKey));

  @override
  Future<UiActionResult> installResource(String macAddress, String path) =>
      _mapAction(_application.installResource(macAddress, path));

  @override
  Future<UiActionResult> cancelInstall() =>
      _mapAction(_application.cancelInstall());

  @override
  Future<UiActionResult> setAutoConnect(bool enabled) =>
      _mapAction(_application.setAutoConnect(enabled));

  @override
  Future<UiActionResult> setThemeId(String themeId) =>
      _mapAction(_application.setThemeId(themeId));

  @override
  Future<void> dispose() => _application.dispose();

  Future<UiActionResult> _mapAction(
    Future<TuiApplicationActionResult> action,
  ) async {
    final result = await action;
    return result.accepted
        ? UiActionResult.accepted(result.message)
        : UiActionResult.rejected(result.message);
  }

  UiSnapshot _mapSnapshot(TuiApplicationSnapshot source) {
    return UiSnapshot(
      revision: source.revision,
      devices: source.devices.map(_mapDevice).toList(growable: false),
      connectionPhase: switch (source.connection) {
        TuiApplicationConnectionState.idle ||
        TuiApplicationConnectionState.scanning ||
        TuiApplicationConnectionState.selected =>
          UiConnectionPhase.disconnected,
        TuiApplicationConnectionState.waitingAuthkey =>
          UiConnectionPhase.awaitingAuthKey,
        TuiApplicationConnectionState.connecting =>
          UiConnectionPhase.connecting,
        // The current UI port has no raw-transport-only phase. Preserve the
        // critical invariant by mapping it to connecting, never ready.
        TuiApplicationConnectionState.connected => UiConnectionPhase.connecting,
        TuiApplicationConnectionState.authenticating =>
          UiConnectionPhase.authenticating,
        TuiApplicationConnectionState.ready ||
        TuiApplicationConnectionState.installing =>
          UiConnectionPhase.ready,
        TuiApplicationConnectionState.disconnecting =>
          UiConnectionPhase.disconnecting,
        TuiApplicationConnectionState.failed => UiConnectionPhase.failed,
      },
      connectedDeviceId: source.activeDeviceId,
      pendingAuthDeviceId: source.pendingAuthDeviceId,
      connectionGeneration: source.connectionGeneration,
      scanning: source.scanning,
      autoConnect: source.autoConnectEnabled,
      autoConnectState: switch (source.autoConnectState) {
        TuiApplicationAutoConnectState.disabled => UiAutoConnectState.disabled,
        TuiApplicationAutoConnectState.idle => UiAutoConnectState.idle,
        TuiApplicationAutoConnectState.connecting =>
          UiAutoConnectState.connecting,
        TuiApplicationAutoConnectState.ready => UiAutoConnectState.ready,
        TuiApplicationAutoConnectState.noSavedDevice =>
          UiAutoConnectState.noSavedDevice,
        TuiApplicationAutoConnectState.missingAuthKey =>
          UiAutoConnectState.missingAuthKey,
        TuiApplicationAutoConnectState.failed => UiAutoConnectState.failed,
        TuiApplicationAutoConnectState.suppressedAfterDisconnect =>
          UiAutoConnectState.suppressedAfterDisconnect,
      },
      themeId: source.themeId,
      install: UiInstallStatus(
        phase: switch (source.installation.phase) {
          TuiApplicationInstallPhase.idle => UiInstallPhase.idle,
          TuiApplicationInstallPhase.preparing => UiInstallPhase.preparing,
          TuiApplicationInstallPhase.transferring =>
            UiInstallPhase.transferring,
          TuiApplicationInstallPhase.awaitingDevice =>
            UiInstallPhase.awaitingDevice,
          TuiApplicationInstallPhase.succeeded => UiInstallPhase.succeeded,
          TuiApplicationInstallPhase.failed => UiInstallPhase.failed,
          TuiApplicationInstallPhase.unknown => UiInstallPhase.unknown,
        },
        fileName: source.installation.fileName,
        confirmedBytes: source.installation.confirmedBytes,
        totalBytes: source.installation.totalBytes,
        message: source.installation.message,
        successVerifiedByDeviceBusinessEvent:
            source.installation.successVerifiedByDeviceBusinessEvent,
      ),
      notice: source.notice,
      error: source.error,
    );
  }

  UiDevice _mapDevice(TuiApplicationDevice source) {
    return UiDevice(
      name: source.name,
      macAddress: source.macAddress,
      support: switch (source.support) {
        TuiApplicationDeviceSupport.supported => UiDeviceSupport.supported,
        TuiApplicationDeviceSupport.unsupported => UiDeviceSupport.unsupported,
        TuiApplicationDeviceSupport.unknown => UiDeviceSupport.unknown,
      },
      saved: source.saved,
      savedAuthKey: source.savedAuthKey,
      connected: source.connected,
      isDirectedSessionTarget: source.isDirectedSessionTarget,
    );
  }
}
