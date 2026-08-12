import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miwearable_install_tool/domain/floating_install_snapshot.dart';
import 'package:miwearable_install_tool/domain/install_task.dart';
import 'package:miwearable_install_tool/presentation/floating_install_window.dart';

void main() {
  Future<void> pumpFloatingWindow(
    WidgetTester tester,
    FloatingInstallSnapshot snapshot,
  ) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(264, 148);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: FloatingInstallWindow(
          snapshot: snapshot,
          onFilesDropped: (_) {},
          onOpenMainWindow: () {},
          onHideWindow: () {},
          onRetry: () {},
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('264x148 idle state renders without overflow', (tester) async {
    await pumpFloatingWindow(
      tester,
      const FloatingInstallSnapshot.idle(
        connected: true,
        authenticated: true,
        deviceName: 'REDMI Watch 5 with an intentionally long device name',
      ),
    );

    expect(find.text('拖入文件即安装'), findsOneWidget);
    expect(find.text('支持 .bin / .face / .rpk'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('264x148 installing state renders without overflow',
      (tester) async {
    await pumpFloatingWindow(
      tester,
      const FloatingInstallSnapshot(
        phase: FloatingInstallPhase.installing,
        connected: true,
        authenticated: true,
        deviceName: 'REDMI Watch 5',
        kind: InstallKind.watchface,
        fileName:
            'an_intentionally_very_long_watchface_file_name_for_ellipsis.face',
        confirmedBytes: 1536,
        totalBytes: 4096,
        bytesPerSecond: 2048,
        queuePosition: 2,
        queueLength: 12,
      ),
    );

    expect(find.text('38%'), findsOneWidget);
    expect(find.text('2.0 KB/s · 队列 2/12'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('264x148 done state renders without overflow', (tester) async {
    await pumpFloatingWindow(
      tester,
      const FloatingInstallSnapshot(
        phase: FloatingInstallPhase.done,
        connected: true,
        authenticated: true,
        deviceName: 'REDMI Watch 5',
        kind: InstallKind.quickApp,
        fileName:
            'an_intentionally_very_long_quick_app_file_name_for_ellipsis.rpk',
        confirmedBytes: 4096,
        totalBytes: 4096,
        queuePosition: 1,
        queueLength: 1,
      ),
    );

    expect(find.text('安装成功'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('264x148 failed state renders without overflow', (tester) async {
    await pumpFloatingWindow(
      tester,
      const FloatingInstallSnapshot(
        phase: FloatingInstallPhase.failed,
        connected: true,
        authenticated: true,
        deviceName: 'REDMI Watch 5',
        kind: InstallKind.watchface,
        fileName: 'failed.face',
        queuePosition: 1,
        queueLength: 2,
        message: '握手超时，这是一段用于验证紧凑窗口会正确省略显示的很长失败原因',
        canRetry: true,
      ),
    );

    expect(find.text('安装失败 · 点击重试'), findsOneWidget);
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
