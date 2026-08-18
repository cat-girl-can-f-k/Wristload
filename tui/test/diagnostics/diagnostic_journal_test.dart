import 'dart:io';

import 'package:test/test.dart';
import 'package:wristload_tui/src/diagnostics/diagnostic_journal.dart';

void main() {
  late Directory directory;
  late DiagnosticJournal journal;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wristload-diagnostics-');
    journal = DiagnosticJournal(
      File(directory.path + '/events.jsonl'),
      pollInterval: const Duration(milliseconds: 10),
    );
  });

  tearDown(() async => directory.delete(recursive: true));

  test('writes schema and redacts auth/session secrets', () async {
    await journal.append(DiagnosticEvent(
      timestamp: DateTime.utc(2026, 8, 15),
      severity: DiagnosticSeverity.error,
      category: DiagnosticCategory.rawTx,
      message: 'authkey: abc123 session_secret=xyz',
      deviceId: 'AA:BB',
      sessionId: 'session-1',
      nativeDomain: 'IOBluetooth',
      nativeCode: 7,
      timeoutMs: 5000,
      retry: 2,
      direction: 'tx',
      byteCount: 3,
      endpoint: 'rfcomm:7',
      fields: const {
        'authkey': 'never',
        'opcode': 12,
        'connectionId': 'connection-1',
        'generation': 3,
        'transport': 'classic-rfcomm',
        'serviceUuid': '1101',
        'channel': 7,
        'stage': 'rfcomm.write.completed',
        'hex': 'ba dc fe',
        'writeResult': 'success',
      },
    ));
    final raw = await File(directory.path + '/events.jsonl').readAsString();
    expect(raw, contains('\"category\":\"raw_tx\"'));
    expect(raw, contains('[REDACTED]'));
    expect(raw, isNot(contains('abc123')));
    expect(raw, isNot(contains('never')));
    final event = (await journal.read()).single;
    expect(event.retry, 2);
    expect(event.nativeCode, 7);
    expect(event.connectionId, 'connection-1');
    expect(event.generation, 3);
    expect(event.transport, 'classic-rfcomm');
    expect(event.serviceUuid, '1101');
    expect(event.channel, 7);
    expect(event.stage, 'rfcomm.write.completed');
    expect(event.hex, 'ba dc fe');
    expect(event.writeResult, 'success');
    expect(event.displayText, contains('endpoint=rfcomm:7'));
    final json = event.toJson();
    expect(json['severity'], 'error');
    expect(json['level'], 'error');
    expect(json['scope'], 'backend');
    expect(json['component'], 'wristload.TuiBackend');
    expect(json['event'], isNotEmpty);
  });

  test('reads GUI-compatible level and structured identity fields', () {
    final event = DiagnosticEvent.fromJson(const <String, Object?>{
      'id': 'gui-1',
      'timestamp': '2026-08-15T08:00:00Z',
      'level': 'fatal',
      'category': 'rfcomm',
      'scope': 'backend',
      'component': 'wristload.RfcommDriver',
      'event': 'rfcomm_open_failed',
      'message': 'RFCOMM open failed',
      'deviceId': 'AA:BB:CC:DD:EE:FF',
      'sessionId': 'session-9',
      'connectionId': 'connection-9',
      'nativeDomain': 'IOBluetooth',
      'nativeCode': 4,
      'disconnectReason': 'open_failed',
      'timeoutMs': 15000,
      'retry': 1,
    });

    expect(event.id, 'gui-1');
    expect(event.severity, DiagnosticSeverity.fatal);
    expect(event.component, 'wristload.RfcommDriver');
    expect(event.event, 'rfcomm_open_failed');
    expect(event.displayText, contains('nativeDomain=IOBluetooth'));
    expect(event.displayText, contains('disconnect=open_failed'));
  });

  test('recursively redacts binding, nonce, HMAC, and key material', () async {
    const appDeviceId = 'private-app-device-id';
    const oob = 'private-oob';
    const sessionKey = 'private-session-key';
    const nonceByte = 137;
    await journal.append(DiagnosticEvent(
      timestamp: DateTime.utc(2026, 8, 15),
      severity: DiagnosticSeverity.info,
      category: DiagnosticCategory.auth,
      message: 'appDeviceId=$appDeviceId oob=$oob',
      fields: const <String, Object?>{
        'appDeviceId': appDeviceId,
        'oob': oob,
        'phoneNonce': <int>[nonceByte, 1, 2],
        'nested': <String, Object?>{
          'sessionKey': sessionKey,
          'values': <Object?>[
            <String, Object?>{'hmac': 'private-hmac'},
          ],
        },
      },
    ));

    final raw = await journal.file.readAsString();
    expect(raw, isNot(contains(appDeviceId)));
    expect(raw, isNot(contains(oob)));
    expect(raw, isNot(contains(sessionKey)));
    expect(raw, isNot(contains(nonceByte.toString())));
    expect(raw, isNot(contains('private-hmac')));
  });

  test('redacts unknown raw hex but preserves safe correlation evidence', () {
    const plaintextPb = 'a5 a5 03 01 02 00 00 00 01 01';
    final event = DiagnosticEvent(
      timestamp: DateTime.utc(2026, 8, 15),
      severity: DiagnosticSeverity.info,
      category: DiagnosticCategory.rawTx,
      message: 'RFCOMM write acknowledged.',
      direction: 'tx',
      byteCount: 10,
      hex: plaintextPb,
      fields: const <String, Object?>{
        'hex': plaintextPb,
        'nativeHex': plaintextPb,
        'writeResult': 'success',
      },
    );

    expect(event.hex, '[REDACTED]');
    expect(event.fields['hex'], '[REDACTED]');
    expect(event.fields['nativeHex'], '[REDACTED]');
    expect(event.byteCount, 10);
    expect(event.direction, 'tx');
    expect(event.writeResult, 'success');
  });

  test('concurrent writers produce parseable JSONL lines', () async {
    await Future.wait(List.generate(
        20,
        (i) => journal.append(DiagnosticEvent(
              timestamp: DateTime.utc(2026, 8, 15),
              severity: DiagnosticSeverity.info,
              category: DiagnosticCategory.scan,
              message: 'event-' + i.toString(),
            ))));
    expect(await journal.read(), hasLength(20));
  });

  test('follow emits existing and newly appended events', () async {
    await journal.append(DiagnosticEvent(
        timestamp: DateTime.now(),
        severity: DiagnosticSeverity.info,
        category: DiagnosticCategory.scan,
        message: 'old'));
    final values = <DiagnosticEvent>[];
    final subscription = journal.follow(initialLimit: 10).listen(values.add);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await journal.append(DiagnosticEvent(
        timestamp: DateTime.now(),
        severity: DiagnosticSeverity.info,
        category: DiagnosticCategory.install,
        message: 'new'));
    for (var i = 0; i < 100 && values.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await subscription.cancel();
    expect(values.map((event) => event.message),
        containsAllInOrder(['old', 'new']));
  });
}
