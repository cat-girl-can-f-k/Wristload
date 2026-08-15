import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/application/diagnostic_log_service.dart';
import 'package:wristload/application/diagnostic_log_window_coordinator.dart';

void main() {
  late Directory directory;
  late DiagnosticLogService logger;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('wristload-logs-');
    logger = DiagnosticLogService(
      maxEntries: 5,
      directoryProvider: () async => directory,
    );
  });

  tearDown(() async {
    await logger.flush();
    logger.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'records severity/category and redacts sensitive message and fields',
    () {
      final entry = logger.trace(
        'authkey=0123456789abcdef0123456789abcdef nonce=abcdef0123456789',
        category: DiagnosticLogCategory.communication,
        fields: <String, Object?>{
          'authkey': '0123456789abcdef0123456789abcdef',
          'payload': Uint8List.fromList([1, 2, 3]),
          'nonce': [4, 5, 6],
          'hasToken': true,
          'bookmarkBytes': 64,
          'nested': <String, Object?>{
            'sessionKey': 'private-session-key',
            'safe': 'kept',
          },
        },
      );

      expect(entry.level, DiagnosticLogLevel.trace);
      expect(entry.category, DiagnosticLogCategory.communication);
      expect(
        entry.message,
        isNot(contains('0123456789abcdef0123456789abcdef')),
      );
      expect(entry.fields['authkey'], '<redacted>');
      expect(entry.fields['payload'], '<redacted>');
      expect(entry.fields['nonce'], '<redacted>');
      expect(entry.fields['hasToken'], isTrue);
      expect(entry.fields['bookmarkBytes'], 64);
      expect((entry.fields['nested'] as Map)['sessionKey'], '<redacted>');
      expect((entry.fields['nested'] as Map)['safe'], 'kept');
      expect(entry.displayText, isNot(contains('private-session-key')));
    },
  );

  test('renders structured single-line format and supports legacy JSONL', () {
    final entry = logger.info(
      'bluetooth availability state: poweredOn',
      category: DiagnosticLogCategory.communication,
      scope: 'backend',
      component: 'wristload.BleGattDriver',
      event: 'bluetooth_state',
      fields: const <String, Object?>{'state': 'poweredOn', 'available': true},
    );

    expect(entry.scope, 'backend');
    expect(entry.component, 'wristload.BleGattDriver');
    expect(entry.event, 'bluetooth_state');
    expect(
      entry.displayText,
      contains(' INFO    [backend] wristload.BleGattDriver  '),
    );
    expect(entry.displayText, contains('state=poweredOn'));
    expect(entry.displayText, contains('available=true'));

    final legacy = DiagnosticLogEntry.fromJson(<String, Object?>{
      'timestamp': '2026-08-14T01:43:49.535290Z',
      'level': 'fatal',
      'category': 'communication',
      'message': 'connect failed',
    });
    expect(legacy.level, DiagnosticLogLevel.fatal);
    expect(legacy.scope, 'backend');
    expect(legacy.component, 'wristload.BluetoothPlatform');
    expect(legacy.event, 'connect failed');
    expect(legacy.displayText, contains('SEVERE  [backend]'));
  });

  test('keeps only the newest entries at maxEntries', () {
    for (var index = 0; index < 7; index++) {
      logger.info('entry-$index');
    }

    expect(logger.length, 5);
    expect(logger.entries.first.message, 'entry-2');
    expect(logger.entries.last.message, 'entry-6');
  });

  test('coalesces high-frequency trace listener notifications', () async {
    var notifications = 0;
    logger.addListener(() => notifications++);

    for (var index = 0; index < 100; index++) {
      logger.trace('wire-$index');
    }
    expect(notifications, 0);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(notifications, 1);
  });

  test('persists JSONL, restores it, flushes and clears it', () async {
    await logger.initializePersistence();
    logger.info(
      'saved token=not-written',
      category: DiagnosticLogCategory.storage,
      fields: <String, Object?>{'payload': 'not-written'},
    );
    await logger.flush();

    final files = Directory(
      '${directory.path}/logs',
    ).listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    final lines = await files.single.readAsLines();
    expect(lines, isNotEmpty);
    expect(lines.join('\n'), isNot(contains('not-written')));
    expect(jsonDecode(lines.last), isA<Map>());

    final restored = DiagnosticLogService(
      maxEntries: 5,
      directoryProvider: () async => directory,
    );
    addTearDown(() async {
      await restored.flush();
      restored.dispose();
    });
    await restored.initializePersistence();
    expect(
      restored.entries.any(
        (entry) => entry.category == DiagnosticLogCategory.storage,
      ),
      isTrue,
    );
    expect(
      restored.entries.map((entry) => entry.displayText).join('\n'),
      isNot(contains('not-written')),
    );

    restored.clear();
    await restored.flush();
    expect(await files.single.readAsString(), isEmpty);
  });

  test('reschedules persistence after flush', () async {
    await logger.initializePersistence();
    logger.info('first entry');
    await logger.flush();
    logger.info('second entry');
    await Future<void>.delayed(const Duration(milliseconds: 250));

    final file = Directory(
      '${directory.path}/logs',
    ).listSync().whereType<File>().single;
    final lines = await file.readAsLines();
    final messages = lines.map((line) => jsonDecode(line)['message']).toList();
    expect(messages, containsAll(<String>['first entry', 'second entry']));
  });

  test('plans incremental log window updates including ring truncation', () {
    DiagnosticLogEntry entry(String id) => DiagnosticLogEntry(
      id: id,
      timestamp: DateTime.utc(2026),
      level: DiagnosticLogLevel.trace,
      category: DiagnosticLogCategory.communication,
      message: id,
    );

    final appended = planDiagnosticLogWindowDelta(
      entries: <DiagnosticLogEntry>[entry('a'), entry('b'), entry('c')],
      hasSnapshot: true,
      publishedLength: 2,
      publishedLastId: 'b',
    );
    expect(appended.method, 'append');
    expect(appended.entries.map((value) => value.id), <String>['c']);
    expect(appended.removeFirst, 0);

    final truncated = planDiagnosticLogWindowDelta(
      entries: <DiagnosticLogEntry>[entry('b'), entry('c')],
      hasSnapshot: true,
      publishedLength: 2,
      publishedLastId: 'b',
    );
    expect(truncated.method, 'append');
    expect(truncated.entries.map((value) => value.id), <String>['c']);
    expect(truncated.removeFirst, 1);

    final cleared = planDiagnosticLogWindowDelta(
      entries: const <DiagnosticLogEntry>[],
      hasSnapshot: true,
      publishedLength: 2,
      publishedLastId: 'b',
    );
    expect(cleared.method, 'reset');
    expect(cleared.entries, isEmpty);
  });

  test('classifies common messages for the controller bridge', () {
    expect(
      classifyLogMessage('RFCOMM 写入完成'),
      DiagnosticLogCategory.communication,
    );
    expect(classifyLogMessage('安装检查点保存完成'), DiagnosticLogCategory.installation);
    expect(classifyLogMessage('系统时间信息读取完成'), DiagnosticLogCategory.runtime);
    expect(classifyLogLevel('未知设备'), DiagnosticLogLevel.warning);
    expect(classifyLogLevel('  DATA frame'), DiagnosticLogLevel.trace);
  });
}
