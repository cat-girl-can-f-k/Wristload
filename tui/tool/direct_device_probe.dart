import 'dart:async';
import 'dart:io';

import 'package:wristload_tui/src/backend_next/macos_tui_backend_adapter.dart';
import 'package:wristload_tui/src/backend_next/tui_json_line_transport.dart';
import 'package:wristload_tui/src/backend_next/tui_mac_bluetooth_transport.dart';
import 'package:wristload_tui/src/backend_next/tui_backend_port.dart';
import 'package:wristload_tui/src/backend_next/tui_protocol_backend.dart';
import 'package:wristload_tui/src/diagnostics/diagnostic_journal.dart';
import 'package:wristload_tui/src/domain/device_profile.dart';

/// Temporary, no-install probe for a user-authorized physical device test.
/// The authkey is read only from the process environment and is never
/// logged, persisted, or emitted by this program.
String _safeStatus(String? value) {
  if (value == null || value.isEmpty) {
    return '-';
  }
  return RegExp(r'^[a-zA-Z0-9._-]{1,80}$').hasMatch(value)
      ? value
      : 'unavailable';
}

Future<void> main() async {
  const address = '2C:0D:CF:70:5E:29';
  const name = 'Xiaomi Smart Band 10 Pro 5E29';
  const helperPath =
      'macos_bridge/build-bundle/stage/wearable_macos_bridge.app/Contents/MacOS/wearable_macos_bridge';
  final authKey = Platform.environment['WRISTLOAD_TEST_AUTHKEY']?.trim();
  if (authKey == null || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(authKey)) {
    stderr.writeln('PROBE_ERROR invalid_or_missing_authkey');
    exitCode = 64;
    return;
  }
  if (!File(helperPath).existsSync()) {
    stderr.writeln('PROBE_ERROR signed_helper_missing');
    exitCode = 66;
    return;
  }

  final directory =
      await Directory.systemTemp.createTemp('wristload-direct-probe-');
  final journal = DiagnosticJournal(File('${directory.path}/journal.jsonl'));
  // The authorized authkey is consumed by this Dart probe only. Do not let the
  // JSONL helper inherit it merely because it is present in this process.
  final helperEnvironment = Map<String, String>.from(Platform.environment)
    ..remove('WRISTLOAD_TEST_AUTHKEY');
  final transport = TuiJsonLineMacBluetoothTransport(
    executablePath: File(helperPath).absolute.path,
    diagnosticJournal: journal,
    processStarter: (executable) => Process.start(
      executable,
      const <String>[],
      environment: helperEnvironment,
      includeParentEnvironment: false,
    ),
  );
  final adapter = MacOsTuiBackendAdapter.withDependencies(
    transport: transport,
    backend: TuiProtocolBackend(
      transport: transport,
      diagnosticJournal: journal,
    ),
  );
  String? previousState;
  final subscription = adapter.snapshots.listen((snapshot) {
    final state = [
      snapshot.connection.name,
      snapshot.transportConnected ? 'transport_open' : 'transport_closed',
      snapshot.identityState?.name ?? 'identity_unknown',
      _safeStatus(snapshot.failureCode),
    ].join('|');
    if (state != previousState) {
      previousState = state;
      stdout.writeln('STATE $state');
    }
  });

  try {
    await adapter.initialize();
    final pairedDevices = await transport.listPairedDevices();
    TuiTransportDevice? pairedTarget;
    for (final device in pairedDevices) {
      if (device.addressKey == '2C0DCF705E29') {
        pairedTarget = device;
        break;
      }
    }
    final resolvedName = pairedTarget?.name ?? name;
    final nameState = pairedTarget?.name.trim().isNotEmpty == true
        ? 'present'
        : 'unavailable';
    stdout.writeln(
      'IDENTITY paired=${pairedTarget != null} name_state=$nameState',
    );
    await adapter.provideAuthKey(authKey);
    stdout.writeln('PROBE_START stage=directed_exact_address');
    await adapter.connectByAddress(
      address: address,
      name: resolvedName,
      profile: DeviceProfile.band10Pro,
      directedExactAddress: true,
      attemptGeneration: 1,
      bindingMaterial: null,
    );
    final deadline = DateTime.now().add(const Duration(seconds: 22));
    while (DateTime.now().isBefore(deadline)) {
      final connection = adapter.snapshot.connection;
      if (connection == TuiBackendConnectionState.ready ||
          connection == TuiBackendConnectionState.disconnected) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final snapshot = adapter.snapshot;
    stdout.writeln(
      'FINAL connection=${snapshot.connection.name} transport=${snapshot.transportConnected} authenticated=${snapshot.protocolAuthenticated} error_code=${_safeStatus(snapshot.failureCode)}',
    );
  } on Object catch (error) {
    stdout.writeln('PROBE_EXCEPTION type=${error.runtimeType}');
  } finally {
    try {
      await adapter.disconnect();
    } on Object {
      stdout.writeln('CLEANUP disconnect_unavailable');
    }
    await adapter.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final events = await journal.read();
    for (final event in events) {
      if (event.event == 'auth.f26.sent' ||
          event.event == 'auth.f26.response_received' ||
          event.event == 'auth.f27.sent' ||
          event.event == 'auth.success' ||
          event.event == 'session.ready' ||
          event.event == 'auth.failure' ||
          event.category == DiagnosticCategory.pairing ||
          event.category == DiagnosticCategory.rawTx ||
          event.category == DiagnosticCategory.rawRx ||
          event.category == DiagnosticCategory.sdp ||
          event.category == DiagnosticCategory.rfcomm) {
        stdout.writeln(
          'EVENT category=${event.categoryName} status=${_safeStatus(event.event)} stage=${_safeStatus(event.stage)} length=${event.byteCount ?? '-'} write_status=${_safeStatus(event.writeResult)} read_status=${_safeStatus(event.readResult)} native_code=${event.nativeCode ?? '-'}',
        );
      }
    }
    await subscription.cancel();
    await directory.delete(recursive: true);
  }
}
