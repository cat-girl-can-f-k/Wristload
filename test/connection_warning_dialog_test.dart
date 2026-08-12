import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/domain/connection_issue.dart';
import 'package:wristload/presentation/connection_warning_dialog.dart';

void main() {
  group('ConnectionIssueTracker', () {
    test('连续两次端口绑定冲突后仅发布一次无法连接事件', () {
      final tracker = ConnectionIssueTracker()..selectTarget('AA:BB');

      expect(tracker.recordConnectionFailure('只允许使用一次'), isFalse);
      expect(tracker.consecutivePortConflicts, 1);
      expect(tracker.pending, isNull);

      expect(tracker.recordConnectionFailure('HRESULT 2147952448'), isTrue);
      expect(tracker.pending?.kind, ConnectionIssueKind.connectionUnavailable);
      expect(tracker.recordConnectionFailure('0x80072740'), isFalse);

      tracker.connectionSucceeded();
      expect(tracker.consecutivePortConflicts, 0);
    });

    test('非端口冲突失败会打断连续计数', () {
      final tracker = ConnectionIssueTracker();

      expect(tracker.recordConnectionFailure('HRESULT 2147952448'), isFalse);
      expect(tracker.recordConnectionFailure('普通超时'), isFalse);
      expect(tracker.recordConnectionFailure('HRESULT 2147952448'), isFalse);
      expect(tracker.pending, isNull);
    });

    test('同一鉴权会话的意外断开只发布一次', () {
      final tracker = ConnectionIssueTracker();

      expect(tracker.recordUnexpectedDisconnect(), isFalse);
      tracker.authenticated();
      expect(tracker.recordUnexpectedDisconnect(), isTrue);
      final first = tracker.pending!;
      expect(first.kind, ConnectionIssueKind.unexpectedDisconnect);
      expect(tracker.recordUnexpectedDisconnect(), isFalse);

      expect(tracker.acknowledge(first.id), isTrue);
      tracker.authenticated();
      expect(tracker.recordUnexpectedDisconnect(), isTrue);
    });
  });

  testWidgets('无法连接弹窗倒计时期间禁止按钮和 Esc 关闭', (tester) async {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(useMaterial3: true, colorScheme: scheme),
      home: const Scaffold(),
    ));

    final dialog = showCannotConnectWarning(
      context: tester.element(find.byType(Scaffold)),
    );
    await tester.pump();

    expect(find.text('您的设备无法被连接'), findsOneWidget);
    expect(
      find.textContaining('连接新手机', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('关闭（3）'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.bluetooth_disabled)).color,
      scheme.error,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('您的设备无法被连接'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.text('关闭'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('您的设备无法被连接'), findsNothing);
    await dialog;
  });

  testWidgets('意外断开弹窗重连期间显示 loading 并在完成后关闭', (tester) async {
    final reconnect = Completer<void>();
    var reconnectCalls = 0;
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));

    final dialog = showUnexpectedDisconnectWarning(
      context: tester.element(find.byType(Scaffold)),
      onReconnect: () {
        reconnectCalls++;
        return reconnect.future;
      },
    );
    await tester.pump();

    expect(find.text('您的设备似乎意外断开了'), findsOneWidget);
    expect(find.byIcon(Icons.link_off), findsOneWidget);
    await tester.tap(find.text('重新连接'));
    await tester.pump();
    expect(reconnectCalls, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<TextButton>(find.byType(TextButton)).onPressed,
      isNull,
    );

    reconnect.complete();
    await tester.pumpAndSettle();
    expect(find.text('您的设备似乎意外断开了'), findsNothing);
    await dialog;
  });
}
