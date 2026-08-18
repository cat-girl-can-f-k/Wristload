import 'dart:async';

import 'package:test/test.dart';
import 'package:wristload_tui/src/application/tui_application.dart';
import 'package:wristload_tui/src/application/tui_application_snapshot.dart';
import 'package:wristload_tui/src/ui_next/application_port_adapter.dart';
import 'package:wristload_tui/src/ui_next/port.dart';

void main() {
  group('TuiApplicationUiPortAdapter lifecycle mapping', () {
    final rows = <({
      TuiApplicationConnectionState application,
      UiConnectionPhase ui,
    })>[
      (
        application: TuiApplicationConnectionState.idle,
        ui: UiConnectionPhase.disconnected,
      ),
      (
        application: TuiApplicationConnectionState.scanning,
        ui: UiConnectionPhase.disconnected,
      ),
      (
        application: TuiApplicationConnectionState.selected,
        ui: UiConnectionPhase.disconnected,
      ),
      (
        application: TuiApplicationConnectionState.waitingAuthkey,
        ui: UiConnectionPhase.awaitingAuthKey,
      ),
      (
        application: TuiApplicationConnectionState.connecting,
        ui: UiConnectionPhase.connecting,
      ),
      (
        application: TuiApplicationConnectionState.connected,
        ui: UiConnectionPhase.connecting,
      ),
      (
        application: TuiApplicationConnectionState.authenticating,
        ui: UiConnectionPhase.authenticating,
      ),
      (
        application: TuiApplicationConnectionState.ready,
        ui: UiConnectionPhase.ready,
      ),
      (
        application: TuiApplicationConnectionState.installing,
        ui: UiConnectionPhase.ready,
      ),
      (
        application: TuiApplicationConnectionState.disconnecting,
        ui: UiConnectionPhase.disconnecting,
      ),
      (
        application: TuiApplicationConnectionState.failed,
        ui: UiConnectionPhase.failed,
      ),
    ];

    for (final row in rows) {
      test('${row.application.name} maps to ${row.ui.name}', () {
        final application = _FakeApplication(_snapshot(row.application));
        final adapter = TuiApplicationUiPortAdapter(application: application);

        expect(adapter.snapshot.connectionPhase, row.ui);
      });
    }

    test('raw transport connected is never exposed as ready', () {
      final application = _FakeApplication(
        _snapshot(TuiApplicationConnectionState.connected),
      );
      final adapter = TuiApplicationUiPortAdapter(application: application);

      expect(adapter.snapshot.connectionPhase, isNot(UiConnectionPhase.ready));
    });

    test('preserves pending auth target and connection generation', () {
      const pendingAuthDeviceId = 'AA:BB:CC:DD:EE:01';
      final application = _FakeApplication(
        _snapshot(
          TuiApplicationConnectionState.waitingAuthkey,
          pendingAuthDeviceId: pendingAuthDeviceId,
          connectionGeneration: 42,
        ),
      );
      final adapter = TuiApplicationUiPortAdapter(application: application);

      expect(adapter.snapshot.pendingAuthDeviceId, pendingAuthDeviceId);
      expect(adapter.snapshot.connectionGeneration, 42);
    });

    test('ordinary UI connect uses the selected current Classic row', () async {
      final application = _FakeApplication(
        _snapshot(TuiApplicationConnectionState.selected),
      );
      final adapter = TuiApplicationUiPortAdapter(application: application);

      await adapter.connect('AA:BB:CC:DD:EE:01');

      expect(application.lastSelectedScannedMacAddress, 'AA:BB:CC:DD:EE:01');
      expect(application.lastConnectionIntent, isNull);
    });

    test('directed UI connect calls the dedicated application operation',
        () async {
      final application = _FakeApplication(
        _snapshot(TuiApplicationConnectionState.selected),
      );
      final adapter = TuiApplicationUiPortAdapter(application: application);

      await adapter.connectDirectedExactAddress();

      expect(application.directedConnectCount, 1);
      expect(application.lastConnectionIntent, isNull);
    });
  });
}

TuiApplicationSnapshot _snapshot(
  TuiApplicationConnectionState connection, {
  String? pendingAuthDeviceId,
  int connectionGeneration = 0,
}) =>
    TuiApplicationSnapshot(
      revision: 1,
      devices: const [],
      connection: connection,
      scanning: connection == TuiApplicationConnectionState.scanning,
      autoConnectEnabled: false,
      autoConnectState: TuiApplicationAutoConnectState.idle,
      themeId: 'black-blue',
      pendingAuthDeviceId: pendingAuthDeviceId,
      connectionGeneration: connectionGeneration,
      installation: TuiApplicationInstallStatus(
        phase: connection == TuiApplicationConnectionState.installing
            ? TuiApplicationInstallPhase.transferring
            : TuiApplicationInstallPhase.idle,
      ),
    );

final class _FakeApplication implements TuiApplicationPort {
  _FakeApplication(this._snapshot);

  final TuiApplicationSnapshot _snapshot;
  TuiApplicationConnectionIntent? lastConnectionIntent;
  String? lastSelectedScannedMacAddress;
  int directedConnectCount = 0;

  @override
  TuiApplicationSnapshot get snapshot => _snapshot;

  @override
  Stream<TuiApplicationSnapshot> get snapshots => Stream.value(_snapshot);

  @override
  Future<TuiApplicationActionResult> initialize() => _success();

  @override
  Future<TuiApplicationActionResult> startScan() => _success();

  @override
  Future<TuiApplicationActionResult> stopScan() => _success();

  @override
  Future<TuiApplicationActionResult> connectDevice(
    String macAddress, {
    TuiApplicationConnectionIntent intent =
        TuiApplicationConnectionIntent.strict,
  }) {
    lastConnectionIntent = intent;
    return _success();
  }

  @override
  Future<TuiApplicationActionResult> connectSelectedScannedDevice(
    String macAddress,
  ) {
    lastSelectedScannedMacAddress = macAddress;
    return _success();
  }

  @override
  Future<TuiApplicationActionResult> connectDirectedExactAddress() {
    directedConnectCount++;
    return _success();
  }

  @override
  Future<TuiApplicationActionResult> disconnect() => _success();

  @override
  Future<TuiApplicationActionResult> saveDevice(String macAddress) =>
      _success();

  @override
  Future<TuiApplicationActionResult> removeSavedDevice(String macAddress) =>
      _success();

  @override
  Future<TuiApplicationActionResult> submitAuthKey(
    String macAddress,
    String authKey,
  ) =>
      _success();

  @override
  Future<TuiApplicationActionResult> installResource(
    String macAddress,
    String literalPath,
  ) =>
      _success();

  @override
  Future<TuiApplicationActionResult> cancelInstall() => _success();

  @override
  Future<TuiApplicationActionResult> setAutoConnect(bool enabled) => _success();

  @override
  Future<TuiApplicationActionResult> setThemeId(String themeId) => _success();

  @override
  Future<void> dispose() async {}

  Future<TuiApplicationActionResult> _success() async =>
      const TuiApplicationActionResult.success('ok');
}
