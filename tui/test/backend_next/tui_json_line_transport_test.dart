import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wristload_tui/src/backend_next/tui_json_line_transport.dart';
import 'package:wristload_tui/src/backend_next/tui_mac_bluetooth_transport.dart';
import 'package:wristload_tui/src/diagnostics/diagnostic_journal.dart';

const _helperSource = r'''
import base64
import json
import sys
import time

mode = sys.argv[1]
connect_count = 0
write_count = 0
connections = {}
retired_connection = None

def emit(value):
    print(json.dumps(value), flush=True)

for line in sys.stdin:
    command = json.loads(line)
    name = command['command']
    request_id = command['requestId']
    if name == 'hello':
        emit({
            'event': 'hello.done',
            'requestId': request_id,
            'protocolVersion': 1,
            'helperSessionId': 'live-jsonl-test',
        })
    elif name == 'connect':
        assert 'directedExactAddress' not in command
        connect_count += 1
        connection_id = command['connectionId']
        address = command['address']
        address_key = command['addressKey']
        connections[connection_id] = (address, address_key, 7)
        if mode == 'retired-after-reconnect' and connect_count == 1:
            retired_connection = (connection_id, address, address_key, 7)
            emit({
                'event': 'error',
                'requestId': request_id,
                'connectionId': connection_id,
                'address': address,
                'addressKey': address_key,
                'generation': 7,
                'code': 'controlled_first_failure',
                'message': 'controlled first failure',
            })
            emit({
                'event': 'closed',
                'connectionId': connection_id,
                'address': address,
                'addressKey': address_key,
                'generation': 7,
                'reason': 'error',
            })
            continue
        if mode == 'pre-active-error':
            emit({
                'event': 'error',
                'requestId': request_id,
                'connectionId': connection_id,
                'code': 'connect_identity_required',
                'message': 'Classic identity required',
                'nativeDomain': 'WristloadBluetooth',
                'nativeCode': 4101,
            })
            emit({
                'event': 'closed',
                'connectionId': connection_id,
                'address': address,
                'addressKey': address_key,
                'generation': 7,
                'reason': 'error',
            })
            continue
        if mode == 'wrong-pre-active-error':
            emit({
                'event': 'error',
                'requestId': 'stale-request',
                'connectionId': connection_id,
                'code': 'must_be_ignored',
                'message': 'wrong request',
            })
            emit({
                'event': 'error',
                'requestId': request_id,
                'connectionId': connection_id + '-stale',
                'code': 'must_also_be_ignored',
                'message': 'wrong connection',
            })
        if mode == 'failed-open-stage':
            emit({
                'event': 'connection.stage',
                'stage': 'rfcomm.open.completed',
                'status': -536870212,
                'connectionId': connection_id,
                'address': address,
                'addressKey': address_key,
                'generation': 7,
            })
        if mode == 'mismatch':
            emit({
                'event': 'connect.done',
                'requestId': request_id,
                'connectionId': connection_id,
                'address': '11-22-33-44-55-66',
                'addressKey': '112233445566',
            })
            continue
        if mode == 'fail-first' and connect_count == 1:
            emit({
                'event': 'error',
                'requestId': request_id,
                'connectionId': connection_id,
                'address': address,
                'addressKey': address_key,
                'generation': 7,
                'code': 'sdp_query_failed',
                'message': 'controlled failure',
                'nativeDomain': 'IOReturn',
                'nativeCode': -536870212,
            })
            emit({
                'event': 'closed',
                'connectionId': connection_id,
                'address': address,
                'addressKey': address_key,
                'generation': 7,
                'reason': 'error',
            })
            # These callbacks arrive after the native generation was retired.
            for late in (
                {'event': 'connection.stage', 'stage': 'rfcomm.open.completed'},
                {'event': 'error', 'code': 'late_error', 'message': 'late'},
                {'event': 'data', 'base64': base64.b64encode(b'late').decode('ascii')},
                {'event': 'closed', 'reason': 'remote'},
            ):
                late.update({'connectionId': connection_id, 'address': address, 'addressKey': address_key, 'generation': 7})
                emit(late)
            continue
        emit({
            'event': 'connect.done',
            'requestId': request_id,
            'connectionId': connection_id,
            'address': address,
            'addressKey': address_key,
            'transport': 'classic-rfcomm',
            'endpoint': 'rfcomm:7',
            'channel': 7,
            'mtu': 127,
            'generation': 7,
        })
        if mode == 'unscoped-active-error':
            # Let the client apply connect.done before exercising the
            # helper-level error fence.
            time.sleep(0.05)
            emit({
                'event': 'error',
                'code': 'scan_observer_failed',
                'message': 'controlled helper-level scan error',
                'nativeDomain': 'IOBluetooth',
                'nativeCode': -1,
            })
        if mode == 'retired-after-reconnect' and connect_count == 2:
            old_id, old_address, old_key, old_generation = retired_connection
            for late in (
                {'event': 'connection.stage', 'stage': 'rfcomm.open.completed'},
                {'event': 'error', 'code': 'late_retired_error', 'message': 'late retired error'},
                {'event': 'data', 'base64': base64.b64encode(b'retired').decode('ascii')},
                {'event': 'closed', 'reason': 'remote'},
            ):
                late.update({
                    'connectionId': old_id,
                    'address': old_address,
                    'addressKey': old_key,
                    'generation': old_generation,
                })
                emit(late)
    elif name == 'identity.resolve':
        if command['candidateId'] == 'ble-candidate-directed':
            assert command.get('directedExactAddress') is True
        else:
            assert 'directedExactAddress' not in command
        emit({'event': 'identity.resolve.done', 'requestId': request_id, 'candidateId': command['candidateId'], 'resolution': 'directClassic', 'identityState': 'provisional', 'address': command.get('address', 'AA-BB-CC-DD-EE-09'), 'addressKey': command.get('addressKey', 'AABBCCDDEE09'), 'name': command['advertisedName'], 'paired': False, 'source': 'manual'})
    elif name == 'pair.start':
        assert 'directedExactAddress' not in command
        assert command['address'] == 'AA-BB-CC-DD-EE-09'
        assert command['addressKey'] == 'AABBCCDDEE09'
        for stage in ('resolving', 'pairingStarted', 'waitingConfirmation', 'completed'):
            emit({'event': 'pairing.stage', 'pairingId': command['pairingId'], 'candidateId': command['candidateId'], 'stage': stage, 'generation': 4, 'timestampMs': 1786723200222})
        emit({'event': 'pair.done', 'requestId': request_id, 'pairingId': command['pairingId'], 'candidateId': command['candidateId'], 'identityState': 'provisional', 'address': 'AA-BB-CC-DD-EE-09', 'addressKey': 'AABBCCDDEE09', 'name': command['advertisedName'], 'paired': True, 'source': 'paired', 'generation': 4})
    elif name == 'pair.cancel':
        emit({'event': 'pair.cancel.done', 'requestId': request_id, 'pairingId': command.get('pairingId')})
    elif name == 'identity.confirm':
        emit({'event': 'identity.confirm.done', 'requestId': request_id, 'candidateId': command['candidateId'], 'connectionId': command['connectionId'], 'generation': command.get('generation', 7), 'resolution': 'confirmed', 'identityState': 'confirmed', 'address': command['address'], 'addressKey': command['addressKey'], 'name': command['advertisedName'], 'paired': True, 'source': 'paired'})
    elif name == 'identity.forget':
        emit({'event': 'identity.forget.done', 'requestId': request_id, 'candidateId': command['candidateId'], 'forgotten': True, 'unpaired': False, 'disconnected': False})
    elif name == 'write':
        write_count += 1
        data = base64.b64decode(command['base64'])
        connection_id = command['connectionId']
        address, address_key, generation = connections[connection_id]
        if mode == 'write-fail-first' and write_count == 1:
            emit({
                'event': 'error',
                'requestId': request_id,
                'connectionId': connection_id,
                'address': address,
                'addressKey': address_key,
                'generation': generation,
                'code': 'write_failed',
                'message': 'controlled write failure',
                'nativeDomain': 'IOReturn',
                'nativeCode': -536870212,
            })
            emit({
                'event': 'closed',
                'connectionId': connection_id,
                'address': address,
                'addressKey': address_key,
                'generation': generation,
                'reason': 'error',
            })
            # A cancelled write acknowledgement must not revive the request.
            emit({
                'event': 'write.done',
                'requestId': request_id,
                'connectionId': connection_id,
                'address': address,
                'addressKey': address_key,
                'generation': generation,
                'byteCount': len(data),
                'length': len(data),
                'writeResult': 'success',
            })
            continue
        if mode == 'late-current':
            for late in (
                {'event': 'connection.stage', 'stage': 'rfcomm.open.completed'},
                {'event': 'error', 'code': 'unknown_connection', 'message': 'unknown'},
                {'event': 'data', 'base64': base64.b64encode(b'wrong').decode('ascii')},
                {'event': 'closed', 'reason': 'remote'},
            ):
                late.update({'connectionId': 'unknown-c999', 'address': 'AA-BB-CC-DD-EE-FF', 'addressKey': 'AABBCCDDEEFF', 'generation': 999})
                emit(late)
            for late in (
                {'event': 'connection.stage', 'stage': 'rfcomm.open.completed'},
                {'event': 'error', 'code': 'wrong_generation', 'message': 'wrong generation'},
                {'event': 'data', 'base64': base64.b64encode(b'wrong-generation').decode('ascii')},
                {'event': 'closed', 'reason': 'remote'},
            ):
                late.update({
                    'connectionId': connection_id,
                    'address': address,
                    'addressKey': address_key,
                    'generation': 999,
                })
                emit(late)
        emit({
            'event': 'write.done',
            'requestId': request_id,
            'connectionId': connection_id,
            'address': address,
            'addressKey': address_key,
            'generation': generation,
            'timestampMs': 1786723200123,
            'transport': 'classic-rfcomm',
            'endpoint': 'rfcomm:7',
            'channel': 7,
            'byteCount': len(data),
            'length': len(data),
            'hex': data.hex(' '),
            'writeResult': 'success',
            'nativeDomain': 'IOReturn',
            'nativeCode': 0,
        })
        emit({
            'event': 'data',
            'connectionId': connection_id,
            'address': address,
            'addressKey': address_key,
            'generation': generation,
            'timestampMs': 1786723200456,
            'transport': 'classic-rfcomm',
            'endpoint': 'rfcomm:7',
            'channel': 7,
            'length': len(data),
            'hex': data.hex(' '),
            'readResult': 'success',
            'nativeDomain': 'IOReturn',
            'nativeCode': 0,
            'nativeStatusHex': '0x00000000',
            'base64': base64.b64encode(data).decode('ascii'),
        })
    elif name == 'disconnect':
        address, address_key, generation = connections[command['connectionId']]
        if mode == 'stale-disconnect':
            emit({
                'event': 'disconnect.done',
                'requestId': request_id,
                'connectionId': command['connectionId'] + '-stale',
                'address': 'AA-BB-CC-DD-EE-FF',
                'addressKey': 'AABBCCDDEEFF',
                'generation': 999,
                'reason': 'local',
            })
            time.sleep(0.15)
        emit({
            'event': 'closed',
            'connectionId': command['connectionId'],
            'address': address,
            'addressKey': address_key,
            'generation': generation,
            'reason': 'local',
        })
        emit({
            'event': 'disconnect.done',
            'requestId': request_id,
            'connectionId': command['connectionId'],
            'address': address,
            'addressKey': address_key,
            'generation': generation,
            'reason': 'local',
        })
''';

void main() {
  late Directory directory;
  final transports = <TuiJsonLineMacBluetoothTransport>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wristload-live-jsonl-');
  });

  tearDown(() async {
    for (final transport in transports.reversed) {
      await transport.dispose();
    }
    await directory.delete(recursive: true);
  });

  TuiJsonLineMacBluetoothTransport createTransport(
    String mode, {
    DiagnosticJournal? journal,
  }) {
    final transport = TuiJsonLineMacBluetoothTransport(
      executablePath: 'controlled-live-helper',
      diagnosticJournal: journal,
      processStarter: (_) => Process.start(
        '/usr/bin/python3',
        ['-u', '-c', _helperSource, mode],
        runInShell: false,
      ),
    );
    transports.add(transport);
    return transport;
  }

  test('accepts native RFCOMM data and preserves TX/RX evidence', () async {
    final journal = DiagnosticJournal(File('${directory.path}/events.jsonl'));
    final transport = createTransport('evidence', journal: journal);
    final received = Completer<List<int>>();
    final subscription = transport.input.listen((bytes) {
      if (!received.isCompleted) received.complete(bytes);
    });
    addTearDown(subscription.cancel);

    await transport.connect(
      TuiTransportDevice(address: 'AA-BB-CC-DD-EE-01', name: 'evidence'),
    );
    await transport.write([0xba, 0xdc, 0xfe]);
    expect(await received.future, [0xba, 0xdc, 0xfe]);

    final records = await _waitForRawEvidence(journal);
    final tx = records.singleWhere(
      (event) => event.category == DiagnosticCategory.rawTx,
    );
    final rx = records.singleWhere(
      (event) => event.category == DiagnosticCategory.rawRx,
    );

    expect(
        tx.timestamp,
        DateTime.fromMillisecondsSinceEpoch(
          1786723200123,
          isUtc: true,
        ));
    expect(tx.deviceId, 'AABBCCDDEE01');
    expect(tx.endpoint, 'rfcomm:7');
    expect(tx.byteCount, 3);
    expect(tx.nativeDomain, 'IOReturn');
    expect(tx.nativeCode, 0);
    expect(tx.fields['transport'], 'classic-rfcomm');
    expect(tx.fields['length'], 3);
    expect(tx.fields['hex'], 'ba dc fe');
    expect(tx.fields['writeResult'], 'success');

    expect(
        rx.timestamp,
        DateTime.fromMillisecondsSinceEpoch(
          1786723200456,
          isUtc: true,
        ));
    expect(rx.deviceId, 'AABBCCDDEE01');
    expect(rx.endpoint, 'rfcomm:7');
    expect(rx.byteCount, 3);
    expect(rx.nativeDomain, 'IOReturn');
    expect(rx.nativeCode, 0);
    expect(rx.fields['transport'], 'classic-rfcomm');
    expect(rx.fields['length'], 3);
    expect(rx.fields['hex'], 'ba dc fe');
    expect(rx.fields['readResult'], 'success');
  });

  test('error then closed releases the retired generation for reconnect',
      () async {
    final transport = createTransport('fail-first');
    final first = TuiTransportDevice(
      address: 'AA-BB-CC-DD-EE-02',
      name: 'first',
    );
    final second = TuiTransportDevice(
      address: 'AA-BB-CC-DD-EE-03',
      name: 'second',
    );

    await expectLater(
      transport.connect(first),
      throwsA(
        isA<TuiNativeTransportException>()
            .having((error) => error.code, 'code', 'sdp_query_failed')
            .having((error) => error.addressKey, 'addressKey', first.addressKey)
            .having((error) => error.domain, 'domain', 'IOReturn')
            .having((error) => error.nativeCode, 'nativeCode', -536870212),
      ),
    );
    await transport.connect(second);

    expect(transport.snapshot.connected, isTrue);
    expect(transport.snapshot.addressKey, second.addressKey);
    expect(transport.snapshot.connectionId, contains('-c2'));
  });

  test('current pre-active connect error immediately preserves native code',
      () async {
    final transport = createTransport('pre-active-error');
    final stopwatch = Stopwatch()..start();

    await expectLater(
      transport.connect(TuiTransportDevice(
        address: 'AA-BB-CC-DD-EE-10',
        name: 'identity required',
      )),
      throwsA(
        isA<TuiNativeTransportException>()
            .having((error) => error.code, 'code', 'connect_identity_required')
            .having((error) => error.nativeCode, 'nativeCode', 4101),
      ),
    );

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('wrong request or connection cannot authorize pre-active error',
      () async {
    final transport = createTransport('wrong-pre-active-error');

    await transport.connect(TuiTransportDevice(
      address: 'AA-BB-CC-DD-EE-11',
      name: 'strict pending identity',
    ));

    expect(transport.snapshot.connected, isTrue);
    expect(transport.snapshot.addressKey, 'AABBCCDDEE11');
  });

  test('failed RFCOMM open callback never marks snapshot connected', () async {
    final transport = createTransport('failed-open-stage');
    final snapshots = <TuiMacTransportSnapshot>[];
    final subscription = transport.snapshots.listen(snapshots.add);
    addTearDown(subscription.cancel);

    await transport.connect(TuiTransportDevice(
      address: 'AA-BB-CC-DD-EE-12',
      name: 'failed open',
    ));

    final failedOpen = snapshots.singleWhere(
      (snapshot) => snapshot.stage == 'rfcomm.open.completed',
    );
    expect(failedOpen.connected, isFalse);
  });

  test('unscoped helper error cannot clear an active RFCOMM snapshot',
      () async {
    final transport = createTransport('unscoped-active-error');
    final errors = <Object>[];
    final subscription = transport.errors.listen(errors.add);
    addTearDown(subscription.cancel);

    await transport.connect(TuiTransportDevice(
      address: 'AA-BB-CC-DD-EE-16',
      name: 'unscoped helper error fence',
    ));
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (errors.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(transport.snapshot.connected, isTrue);
    expect(transport.snapshot.connectionId, contains('-c1'));
    expect(transport.snapshot.addressKey, 'AABBCCDDEE16');
    expect(transport.snapshot.message, 'controlled helper-level scan error');
    expect(
      errors,
      contains(isA<TuiNativeTransportException>()
          .having((error) => error.code, 'code', 'scan_observer_failed')
          .having((error) => error.connectionId, 'connectionId', isNull)),
    );
  });

  test('stale disconnect.done cannot complete the current request', () async {
    final transport = createTransport('stale-disconnect');
    await transport.connect(TuiTransportDevice(
      address: 'AA-BB-CC-DD-EE-13',
      name: 'disconnect fence',
    ));
    final stopwatch = Stopwatch()..start();

    await transport.disconnect();

    expect(stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 100)));
    expect(transport.snapshot.connected, isFalse);
  });

  test('rejects a scoped event whose addressKey belongs to another device',
      () async {
    final transport = createTransport('mismatch');

    await expectLater(
      transport.connect(
        TuiTransportDevice(
          address: 'AA-BB-CC-DD-EE-04',
          name: 'identity mismatch',
        ),
      ),
      throwsA(
        isA<TuiTransportProtocolException>().having(
          (error) => error.message,
          'message',
          contains('addressKey'),
        ),
      ),
    );
    expect(transport.snapshot.helperState, TuiMacHelperState.failed);
    expect(transport.snapshot.connected, isFalse);
  });

  test('ignores unknown and wrong-generation connection callbacks', () async {
    final transport = createTransport('late-current');
    final received = <List<int>>[];
    final errors = <Object>[];
    final inputSubscription = transport.input.listen(received.add);
    final errorSubscription = transport.errors.listen(errors.add);
    addTearDown(inputSubscription.cancel);
    addTearDown(errorSubscription.cancel);

    final device = TuiTransportDevice(
      address: 'AA-BB-CC-DD-EE-01',
      name: 'late callbacks',
    );
    await transport.connect(device);
    final before = transport.snapshot;
    await transport.write([1, 2, 3]);
    final deadline = DateTime.now().add(const Duration(seconds: 1));
    while (received.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(transport.snapshot.connectionId, before.connectionId);
    expect(transport.snapshot.connectionGeneration, 7);
    expect(transport.snapshot.connected, isTrue);
    expect(transport.snapshot.stage, before.stage);
    expect(received, <List<int>>[
      <int>[1, 2, 3]
    ]);
    expect(errors, isEmpty);
  });

  test('retired callbacks cannot mutate a replacement connection', () async {
    final transport = createTransport('retired-after-reconnect');
    final received = <List<int>>[];
    final errors = <Object>[];
    final inputSubscription = transport.input.listen(received.add);
    final errorSubscription = transport.errors.listen(errors.add);
    addTearDown(inputSubscription.cancel);
    addTearDown(errorSubscription.cancel);

    await expectLater(
      transport.connect(TuiTransportDevice(
        address: 'AA-BB-CC-DD-EE-14',
        name: 'retired',
      )),
      throwsA(
        isA<TuiNativeTransportException>().having(
          (error) => error.code,
          'code',
          'controlled_first_failure',
        ),
      ),
    );

    final replacement = TuiTransportDevice(
      address: 'AA-BB-CC-DD-EE-15',
      name: 'replacement',
    );
    await transport.connect(replacement);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(transport.snapshot.connected, isTrue);
    expect(transport.snapshot.addressKey, replacement.addressKey);
    expect(transport.snapshot.connectionId, contains('-c2'));
    expect(transport.snapshot.connectionGeneration, 7);
    expect(transport.snapshot.stage, 'connect.done');
    expect(received, isEmpty);
    expect(errors, isEmpty);
  });

  test('terminal write error cancels the write and permits reconnect',
      () async {
    final transport = createTransport('write-fail-first');
    final first = TuiTransportDevice(
      address: 'AA-BB-CC-DD-EE-05',
      name: 'write failure',
    );
    final second = TuiTransportDevice(
      address: 'AA-BB-CC-DD-EE-06',
      name: 'replacement',
    );

    await transport.connect(first);
    await expectLater(
      transport.write([0xba, 0xdc]),
      throwsA(
        isA<TuiNativeTransportException>()
            .having((error) => error.code, 'code', 'write_failed')
            .having((error) => error.connectionId, 'connectionId', isNotNull)
            .having(
                (error) => error.addressKey, 'addressKey', first.addressKey),
      ),
    );
    await transport.connect(second);
    await transport.write([0xfe]);

    expect(transport.snapshot.connected, isTrue);
    expect(transport.snapshot.addressKey, second.addressKey);
  });

  test('binds resolve, pairing, confirmation, and forget to stable ids',
      () async {
    final transport = createTransport('identity');
    final stages = <TuiPairingStage>[];
    final subscription = transport.pairingStages.listen(stages.add);
    addTearDown(subscription.cancel);
    final candidate = TuiIdentityCandidate(
      candidateId: 'ble-candidate-1',
      advertisedName: 'Xiaomi Smart Band 10',
    );

    final resolved = await transport.resolveIdentity(candidate);
    expect(resolved.resolution, TuiIdentityResolution.directClassic);
    expect(resolved.identityState, TuiIdentityState.provisional);
    expect(resolved.device?.addressKey, 'AABBCCDDEE09');

    final paired = await transport.startPairing(candidate);
    expect(paired.candidateId, candidate.candidateId);
    expect(paired.device.paired, isTrue);
    expect(paired.identityState, TuiIdentityState.provisional);
    expect(stages.map((stage) => stage.stage), [
      TuiPairingStageKind.resolving,
      TuiPairingStageKind.pairingStarted,
      TuiPairingStageKind.waitingConfirmation,
      TuiPairingStageKind.completed,
    ]);
    expect(stages.every((stage) => stage.generation == 4), isTrue);

    await transport.connect(paired.device);
    final confirmed = await transport.confirmIdentity(TuiIdentityConfirmation(
      candidateId: candidate.candidateId,
      advertisedName: candidate.advertisedName,
      address: paired.device.address,
      connectionId: transport.snapshot.connectionId!,
      generation: 7,
    ));
    expect(confirmed.identityState, TuiIdentityState.confirmed);
    expect(confirmed.resolution, TuiIdentityResolution.confirmed);

    final forgotten = await transport.forgetIdentity(candidate.candidateId);
    expect(forgotten.forgotten, isTrue);
    expect(forgotten.unpaired, isFalse);
    expect(forgotten.disconnected, isFalse);
  });

  test('requires an exact resolved Classic binding before direct pairing',
      () async {
    final transport = createTransport('identity');
    final candidate = TuiIdentityCandidate(
      candidateId: 'unresolved-candidate',
      advertisedName: 'Xiaomi Smart Band 10',
      address: 'AA-BB-CC-DD-EE-09',
    );

    await expectLater(
      transport.startPairing(candidate),
      throwsA(
        isA<TuiTransportProtocolException>().having(
          (error) => error.message,
          'message',
          contains('identity.resolve'),
        ),
      ),
    );
  });

  test('sends directed exact-address intent only when explicitly requested',
      () async {
    final transport = createTransport('identity');
    final strict = TuiIdentityCandidate(
      candidateId: 'ble-candidate-strict',
      advertisedName: 'Xiaomi Smart Band 10',
      address: 'AA-BB-CC-DD-EE-09',
    );
    final directed = TuiIdentityCandidate(
      candidateId: 'ble-candidate-directed',
      advertisedName: 'Xiaomi Smart Band 10',
      address: 'AA-BB-CC-DD-EE-09',
      directedExactAddress: true,
    );

    expect(strict.directedExactAddress, isFalse);
    await transport.resolveIdentity(strict);
    final resolved = await transport.resolveIdentity(directed);
    expect(resolved.device?.addressKey, 'AABBCCDDEE09');
    final paired = await transport.startPairing(directed);
    expect(paired.device.addressKey, 'AABBCCDDEE09');
  });

  test('pairing cannot upgrade a strict resolved binding to directed intent',
      () async {
    final transport = createTransport('identity');
    final strict = TuiIdentityCandidate(
      candidateId: 'ble-candidate-strict',
      advertisedName: 'Xiaomi Smart Band 10',
      address: 'AA-BB-CC-DD-EE-09',
    );
    final upgraded = TuiIdentityCandidate(
      candidateId: strict.candidateId,
      advertisedName: strict.advertisedName,
      address: strict.address,
      directedExactAddress: true,
    );

    await transport.resolveIdentity(strict);
    await expectLater(
      transport.startPairing(upgraded),
      throwsA(isA<TuiTransportProtocolException>()),
    );
  });

  test('rejects confirmation for a stale native connection generation',
      () async {
    final transport = createTransport('identity');
    final device = TuiTransportDevice(
      address: 'AA-BB-CC-DD-EE-09',
      name: 'Xiaomi Smart Band 10',
    );
    await transport.connect(device);

    await expectLater(
      transport.confirmIdentity(TuiIdentityConfirmation(
        candidateId: 'ble-candidate-1',
        advertisedName: device.name,
        address: device.address,
        connectionId: transport.snapshot.connectionId!,
        generation: 8,
      )),
      throwsA(isA<StateError>()),
    );
  });
}

Future<List<DiagnosticEvent>> _waitForRawEvidence(
  DiagnosticJournal journal,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    final events = await journal.read();
    final rawCount = events
        .where((event) =>
            event.category == DiagnosticCategory.rawTx ||
            event.category == DiagnosticCategory.rawRx)
        .length;
    if (rawCount >= 2) return events;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for TX/RX diagnostic evidence.');
}
