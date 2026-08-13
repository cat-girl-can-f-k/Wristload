import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:wristload_tui/src/transport/json_line_mac_bluetooth_transport.dart';
import 'package:wristload_tui/src/transport/mac_bluetooth_transport.dart';

const _helperSource = r'''
import json
import os
import sys
import time

log_path, gate_path, fail_cleanup_path = sys.argv[1:4]

def emit(value):
    print(json.dumps(value), flush=True)

for line in sys.stdin:
    command = json.loads(line)
    with open(log_path, 'a', encoding='utf-8') as log:
        log.write(json.dumps(command) + '\n')
    name = command['command']
    request_id = command['requestId']
    if name == 'hello':
        emit({
            'event': 'hello.done',
            'requestId': request_id,
            'protocolVersion': 1,
            'helperSessionId': 'test-helper',
        })
    elif name == 'connect':
        emit({
            'event': 'connect.done',
            'requestId': request_id,
            'connectionId': command['connectionId'],
        })
    elif name == 'disconnect':
        while not os.path.exists(gate_path):
            time.sleep(0.01)
        if os.path.exists(fail_cleanup_path):
            emit({
                'event': 'error',
                'requestId': request_id,
                'connectionId': command['connectionId'],
                'code': 'disconnect_failed',
                'message': 'controlled failure',
            })
        else:
            emit({
                'event': 'disconnect.done',
                'requestId': request_id,
                'connectionId': command['connectionId'],
            })
    elif name == 'write':
        emit({
            'event': 'error',
            'requestId': request_id,
            'connectionId': command['connectionId'],
            'code': 'write_failed',
            'message': 'controlled failure',
        })
''';

void main() {
  late Directory directory;
  late File commandLog;
  late File disconnectGate;
  late File failCleanup;
  late JsonLineMacBluetoothTransport transport;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wristload-jsonl-test-');
    commandLog = File('${directory.path}/commands.jsonl');
    disconnectGate = File('${directory.path}/disconnect.gate');
    failCleanup = File('${directory.path}/fail-cleanup');
    transport = JsonLineMacBluetoothTransport(
      executablePath: 'controlled-test-helper',
      processStarter: (_) => Process.start(
        '/usr/bin/python3',
        [
          '-u',
          '-c',
          _helperSource,
          commandLog.path,
          disconnectGate.path,
          failCleanup.path,
        ],
        runInShell: false,
      ),
    );
  });

  tearDown(() async {
    await disconnectGate.writeAsString('release');
    await transport.dispose();
    await directory.delete(recursive: true);
  });

  test('concurrent disconnect shares one native request and blocks reconnect',
      () async {
    final firstDevice = MacBluetoothDevice(
      address: 'AA-BB-CC-DD-EE-01',
      name: 'first',
    );
    final secondDevice = MacBluetoothDevice(
      address: 'AA-BB-CC-DD-EE-02',
      name: 'second',
    );
    await transport.connect(firstDevice);

    final firstDisconnect = transport.disconnect();
    final secondDisconnect = transport.disconnect();
    await _waitForCommandCount(commandLog, 'disconnect', 1);

    final reconnect = transport.connect(secondDevice);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(await _commandCount(commandLog, 'disconnect'), 1);
    expect(await _commandCount(commandLog, 'connect'), 1);

    await disconnectGate.writeAsString('release');
    await Future.wait([firstDisconnect, secondDisconnect]);
    await reconnect;

    expect(await _commandCount(commandLog, 'disconnect'), 1);
    expect(await _commandCount(commandLog, 'connect'), 2);
  });

  test('failed cleanup keeps the connection id and fails reconnect closed',
      () async {
    final device = MacBluetoothDevice(
      address: 'AA-BB-CC-DD-EE-03',
      name: 'failure',
    );
    await transport.connect(device);
    await failCleanup.writeAsString('fail');
    await disconnectGate.writeAsString('release');

    await expectLater(transport.write([1]), throwsA(isA<Object>()));
    await _waitForCommandCount(commandLog, 'disconnect', 1);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await expectLater(transport.connect(device), throwsA(isA<StateError>()));
    expect(await _commandCount(commandLog, 'connect'), 1);
  });
}

Future<void> _waitForCommandCount(File log, String command, int expected) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    if (await _commandCount(log, command) >= expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for $expected $command command(s).');
}

Future<int> _commandCount(File log, String command) async {
  if (!await log.exists()) return 0;
  final lines = await log.readAsLines();
  return lines.where((line) {
    if (line.trim().isEmpty) return false;
    final value = jsonDecode(line);
    return value is Map && value['command'] == command;
  }).length;
}
