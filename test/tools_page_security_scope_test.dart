import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/application/device_controller.dart';
import 'package:wristload/presentation/tools_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const scopeChannel = MethodChannel('wristload/security_scope');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(scopeChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'authkey ZIP reads the resolved path, retains its replacement bookmark, and closes each lease',
      (tester) async {
    final directory = await Directory.systemTemp.createTemp('wristload-tools-');
    addTearDown(() => directory.delete(recursive: true));
    final resolved = File('${directory.path}${Platform.pathSeparator}resolved.zip');
    await resolved.writeAsBytes(_zipWithAuthKey());

    final startBookmarks = <Uint8List>[];
    final stoppedTokens = <String>[];
    messenger.setMockMethodCallHandler(scopeChannel, (call) async {
      switch (call.method) {
        case 'pickFiles':
          return <Object>[
            <String, Object>{
              'path': '${directory.path}${Platform.pathSeparator}stale.zip',
              'bookmark': Uint8List.fromList([1]),
            },
          ];
        case 'startAccess':
          final arguments = call.arguments as Map<Object?, Object?>;
          startBookmarks.add(arguments['bookmark']! as Uint8List);
          final number = startBookmarks.length;
          return <String, Object>{
            'started': true,
            'token': 'lease-$number',
            'path': resolved.path,
            'bookmark': Uint8List.fromList([2]),
          };
        case 'stopAccess':
          final arguments = call.arguments as Map<Object?, Object?>;
          stoppedTokens.add(arguments['token']! as String);
          return null;
      }
      return null;
    });

    final controller = DeviceController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ToolsPage(controller: controller))),
    );

    await tester.tap(find.text('点击选择 .zip 日志文件'));
    await tester.pumpAndSettle();
    expect(find.text('stale.zip'), findsOneWidget);

    final extract = find.widgetWithText(FilledButton, '提取 authkey');
    await tester.tap(extract);
    await tester.pumpAndSettle();
    expect(find.text('aaaa******aaaa'), findsOneWidget);

    // A second extraction must acquire using the bookmark refreshed by macOS.
    await tester.tap(extract);
    await tester.pumpAndSettle();

    expect(startBookmarks, [
      Uint8List.fromList([1]),
      Uint8List.fromList([2]),
    ]);
    expect(stoppedTokens, ['lease-1', 'lease-2']);
  });

  testWidgets('authkey ZIP closes its lease when reading the resolved path fails',
      (tester) async {
    final directory = await Directory.systemTemp.createTemp('wristload-tools-');
    addTearDown(() => directory.delete(recursive: true));
    final missing = '${directory.path}${Platform.pathSeparator}missing.zip';
    final calls = <String>[];
    messenger.setMockMethodCallHandler(scopeChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'pickFiles':
          return <Object>[
            <String, Object>{
              'path': '${directory.path}${Platform.pathSeparator}selected.zip',
              'bookmark': Uint8List.fromList([3]),
            },
          ];
        case 'startAccess':
          return <String, Object>{
            'started': true,
            'token': 'failed-read',
            'path': missing,
          };
        case 'stopAccess':
          return null;
      }
      return null;
    });

    final controller = DeviceController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ToolsPage(controller: controller))),
    );

    await tester.tap(find.text('点击选择 .zip 日志文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '提取 authkey'));
    await tester.pumpAndSettle();

    expect(find.textContaining('文件无效或未找到 authkey'), findsOneWidget);
    expect(calls, ['pickFiles', 'startAccess', 'stopAccess']);
  });
}

List<int> _zipWithAuthKey() {
  const key = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final data = utf8.encode('authkey=$key');
  final archive = Archive()
    ..addFile(ArchiveFile('XiaomiFit.main.log', data.length, data));
  return ZipEncoder().encode(archive)!;
}
