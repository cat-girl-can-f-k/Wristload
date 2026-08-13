import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/application/device_controller.dart';
import 'package:wristload/domain/device_profile.dart';
import 'package:wristload/domain/install_models.dart';
import 'package:wristload/domain/install_task.dart';
import 'package:wristload/domain/install_preference_store.dart';
import 'package:wristload/presentation/install_task_card.dart';
import 'package:wristload/presentation/install_split_button.dart';
import 'package:wristload/presentation/install_request_preflight.dart';
import 'package:wristload/presentation/install_warning_dialog.dart';
import 'package:wristload/presentation/queue_page.dart';
import 'package:wristload/presentation/settings_page.dart';
import 'package:wristload/presentation/tools_page.dart';

void main() {
  test('known profile hints stay restricted to verified observations', () {
    final hints =
        DeviceProfile.recognized.expand((profile) => profile.modelHints);
    expect(hints, contains('miwear.watch.n66'));
    expect(hints, contains('miwear.watch.o63'));
    expect(hints, contains('hqbd3.watch.l67'));
    expect(hints, contains('lchz.watch.m67'));
    expect(hints, contains('lchz.watch.n65'));
  });

  test('设备名称按具体型号优先分类', () {
    expect(
      DeviceProfile.matchAdvertisementName('Xiaomi Smart Band 9Pro CCF2')
          ?.family,
      DeviceFamily.band9Pro,
    );
    expect(
      DeviceProfile.matchAdvertisementName('Xiaomi Smart Band 10 Pro')?.family,
      DeviceFamily.band10Pro,
    );
    expect(DeviceProfile.matchAdvertisementName('Xiaomi Watch S4')?.family,
        DeviceFamily.watchS4);
    expect(DeviceProfile.matchAdvertisementName('Xiaomi Watch S5')?.family,
        DeviceFamily.watchS5);
    expect(DeviceProfile.matchAdvertisementName('REDMI Watch5')?.family,
        DeviceFamily.redmiWatch5);
    expect(DeviceProfile.matchAdvertisementName('redmi watch 6')?.family,
        DeviceFamily.redmiWatch6);
    expect(DeviceProfile.matchAdvertisementName('REDMI Watch 4')?.family,
        DeviceFamily.redmiWatch4);
    expect(
        DeviceProfile.matchAdvertisementName('Xiaomi Smart Band 8 Pro')?.family,
        DeviceFamily.band8Pro);
    expect(
        DeviceProfile.matchAdvertisementName('Xiaomi Smart Band 7Pro')?.family,
        DeviceFamily.band7Pro);
  });

  test('Sport 名称不再单独拒绝且已知设备分辨率正确', () {
    expect(
        DeviceProfile.matchAdvertisementName('Xiaomi Watch S4 Sport')?.family,
        DeviceFamily.watchS4);
    expect(DeviceProfile.band9Pro.watchfaceResolution,
        const WatchfaceResolution(336, 480));
    expect(DeviceProfile.redmiWatch5.watchfaceResolution,
        const WatchfaceResolution(432, 514));
    expect(DeviceProfile.watchS5.watchfaceResolution,
        const WatchfaceResolution(464, 464));
    expect(DeviceProfile.band8Pro.generation, ProtocolGeneration.v1Vela);
    expect(DeviceProfile.band7Pro.generation, ProtocolGeneration.huamiZepp);
    expect(DeviceProfile.redmiWatch4.generation, ProtocolGeneration.unknown);
  });

  testWidgets('安装卡片显示 ACK 进度、KB 和速度', (tester) async {
    const task = InstallTask(
      kind: InstallKind.quickApp,
      fileName: 'demo.rpk',
      stage: InstallStage.transferring,
      message: '等待设备累计 ACK',
      targetDeviceName: 'Xiaomi Smart Band 9 Pro',
      md5Hex: '0123456789abcdef0123456789abcdef',
      packageName: 'com.example.demo',
      versionCode: 42,
      currentSegment: 25,
      totalSegments: 50,
      confirmedBytes: 1024,
      queuedSegment: 50,
      queuedBytes: 2048,
      totalBytes: 4096,
      bytesPerSecond: 2048,
      transferElapsed: Duration(seconds: 3),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InstallTaskCard(
          task: task,
          onCancel: () async {},
          onRetry: () async {},
        ),
      ),
    ));

    expect(find.text('demo.rpk'), findsOneWidget);
    expect(find.textContaining('1.0 KB/4.0 KB'), findsOneWidget);
    expect(find.textContaining('2.0 KB/s'), findsOneWidget);
    expect(find.text('25.0%'), findsOneWidget);
    expect(find.text('预计剩余 2 秒'), findsOneWidget);
    expect(find.textContaining('设备确认'), findsOneWidget);
    expect(find.text('已确认'), findsOneWidget);
    expect(find.text('已提交待确认'), findsOneWidget);
    final trackWidth = tester
        .getSize(find.byKey(const ValueKey('install-progress-track')))
        .width;
    final submittedWidth = tester
        .getSize(find.byKey(const ValueKey('install-progress-submitted')))
        .width;
    final confirmedWidth = tester
        .getSize(find.byKey(const ValueKey('install-progress-confirmed')))
        .width;
    expect(trackWidth, greaterThan(0));
    expect(confirmedWidth, closeTo(trackWidth * .25, .01));
    expect(submittedWidth, closeTo(trackWidth * .5, .01));
    expect(find.textContaining('com.example.demo'), findsOneWidget);
    expect(find.textContaining('版本：42'), findsOneWidget);
    expect(find.text('详情'), findsOneWidget);
    expect(find.textContaining('Xiaomi Smart Band 9 Pro'), findsNothing);
    expect(find.textContaining('0123456789abcdef'), findsNothing);
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Xiaomi Smart Band 9 Pro'), findsOneWidget);
    expect(find.textContaining('0123456789abcdef'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
  });

  testWidgets('安装卡片在传输不足两秒时不显示 ETA', (tester) async {
    const task = InstallTask(
      kind: InstallKind.watchface,
      fileName: 'demo.face',
      stage: InstallStage.transferring,
      message: '传输中',
      faceId: '1234',
      currentSegment: 1,
      totalSegments: 4,
      confirmedBytes: 1024,
      queuedSegment: 2,
      queuedBytes: 2048,
      totalBytes: 4096,
      bytesPerSecond: 2048,
      transferElapsed: Duration(milliseconds: 1999),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InstallTaskCard(
          task: task,
          onCancel: () async {},
          onRetry: () async {},
        ),
      ),
    ));

    expect(find.textContaining('2.0 KB/s'), findsOneWidget);
    expect(find.textContaining('预计剩余'), findsNothing);
  });

  testWidgets('安装卡片在窄窗口中不发生布局溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const task = InstallTask(
      kind: InstallKind.quickApp,
      fileName: 'a_very_long_quick_application_package_name.rpk',
      stage: InstallStage.transferring,
      message: '传输中',
      packageName: 'com.example.long.package.name',
      versionCode: 20260812,
      currentSegment: 1234,
      totalSegments: 9999,
      confirmedBytes: 4 * 1024 * 1024,
      queuedSegment: 1500,
      queuedBytes: 5 * 1024 * 1024,
      totalBytes: 12 * 1024 * 1024,
      bytesPerSecond: 2.5 * 1024 * 1024,
      transferElapsed: Duration(seconds: 3),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: InstallTaskCard(
            task: task,
            onCancel: () async {},
            onRetry: () async {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('已提交待确认'), findsOneWidget);
  });

  testWidgets('文件传输完成后隐藏取消按钮', (tester) async {
    const task = InstallTask(
      kind: InstallKind.watchface,
      fileName: 'demo.face',
      stage: InstallStage.awaitingDevice,
      message: '等待设备安装结果',
      currentSegment: 4,
      totalSegments: 4,
      confirmedBytes: 4096,
      queuedSegment: 4,
      queuedBytes: 4096,
      totalBytes: 4096,
      bytesPerSecond: 2048,
      transferElapsed: Duration(seconds: 2),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InstallTaskCard(
          task: task,
          onCancel: () async {},
          onRetry: () async {},
        ),
      ),
    ));

    expect(find.text('取消'), findsNothing);
    expect(find.text('100.0%'), findsOneWidget);
  });

  testWidgets('安装卡片确认后才取消传输', (tester) async {
    var cancelCalls = 0;
    const task = InstallTask(
      kind: InstallKind.watchface,
      fileName: 'demo.face',
      stage: InstallStage.transferring,
      message: '传输中',
      faceId: '1234',
      currentSegment: 1,
      totalSegments: 4,
      confirmedBytes: 1024,
      totalBytes: 4096,
      transferElapsed: Duration(seconds: 3),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InstallTaskCard(
          task: task,
          onCancel: () async => cancelCalls++,
          onRetry: () async {},
        ),
      ),
    ));

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('取消后已传输分片作废'), findsOneWidget);
    expect(cancelCalls, 0);
    await tester.tap(find.text('继续安装'));
    await tester.pumpAndSettle();
    expect(cancelCalls, 0);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认取消'));
    await tester.pumpAndSettle();
    expect(cancelCalls, 1);
  });

  testWidgets('安装卡片完成态保留完整结构并可清除', (tester) async {
    var clearCalls = 0;
    const task = InstallTask(
      kind: InstallKind.quickApp,
      fileName: 'demo.rpk',
      stage: InstallStage.succeeded,
      message: '安装完成',
      targetDeviceName: 'Xiaomi Smart Band 9 Pro',
      md5Hex: '0123456789abcdef0123456789abcdef',
      packageName: 'com.example.demo',
      versionCode: 42,
      currentSegment: 82,
      totalSegments: 82,
      confirmedBytes: 8192,
      queuedSegment: 82,
      queuedBytes: 8192,
      totalBytes: 8192,
      elapsed: Duration(seconds: 65),
      transferElapsed: Duration(seconds: 4),
      averageBytesPerSecond: 2048,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InstallTaskCard(
          task: task,
          onCancel: () async {},
          onRetry: () async {},
          onClear: () => clearCalls++,
        ),
      ),
    ));

    expect(find.text('demo.rpk'), findsOneWidget);
    expect(
      find.text('快应用 · com.example.demo · 版本：42'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('安装完成'), findsOneWidget);
    expect(find.text('用时 1 分 5 秒'), findsOneWidget);
    expect(find.text('平均 2.0 KB/s'), findsOneWidget);
    expect(find.textContaining('设备确认 82/82 片'), findsOneWidget);
    expect(find.textContaining('校验通过'), findsOneWidget);
    expect(find.text('全部确认'), findsOneWidget);
    final trackWidth = tester
        .getSize(find.byKey(const ValueKey('install-progress-track')))
        .width;
    final confirmedWidth = tester
        .getSize(find.byKey(const ValueKey('install-progress-confirmed')))
        .width;
    expect(trackWidth, greaterThan(0));
    expect(confirmedWidth, closeTo(trackWidth, .01));
    expect(find.text('详情'), findsOneWidget);
    expect(find.textContaining('Xiaomi Smart Band 9 Pro'), findsNothing);
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Xiaomi Smart Band 9 Pro'), findsOneWidget);
    expect(find.textContaining('0123456789abcdef'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
    await tester.tap(find.text('清除'));
    await tester.pump();
    expect(clearCalls, 1);
  });

  testWidgets('安装卡片失败态保留进度并提供断点重试和清除', (tester) async {
    var retryCalls = 0;
    var clearCalls = 0;
    const task = InstallTask(
      kind: InstallKind.watchface,
      fileName: 'broken.face',
      stage: InstallStage.failed,
      message: '设备 ACK 超时',
      targetDeviceName: 'REDMI Watch 5',
      md5Hex: 'fedcba9876543210fedcba9876543210',
      faceId: '1234',
      currentSegment: 50,
      totalSegments: 82,
      confirmedBytes: 50 * 1024,
      queuedSegment: 52,
      queuedBytes: 52 * 1024,
      totalBytes: 82 * 1024,
      elapsed: Duration(seconds: 9),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InstallTaskCard(
          task: task,
          onCancel: () async {},
          onRetry: () async => retryCalls++,
          onClear: () => clearCalls++,
        ),
      ),
    ));

    expect(find.text('broken.face'), findsOneWidget);
    expect(find.text('表盘 · ID 1234'), findsOneWidget);
    expect(find.byIcon(Icons.error), findsOneWidget);
    expect(find.text('安装失败'), findsOneWidget);
    expect(find.text('中断于 61.0%'), findsOneWidget);
    expect(find.text('已用时 9 秒'), findsOneWidget);
    expect(find.text('设备 ACK 超时'), findsOneWidget);
    expect(find.text('已传输分片保留，重试将从断点继续。'), findsOneWidget);
    expect(find.textContaining('设备确认 50/82 片'), findsOneWidget);
    expect(find.text('已确认'), findsOneWidget);
    expect(find.text('失败点'), findsOneWidget);
    final trackWidth = tester
        .getSize(find.byKey(const ValueKey('install-progress-track')))
        .width;
    final confirmedWidth = tester
        .getSize(find.byKey(const ValueKey('install-progress-confirmed')))
        .width;
    final failureWidth = tester
        .getSize(find.byKey(const ValueKey('install-progress-failure-marker')))
        .width;
    expect(trackWidth, greaterThan(0));
    expect(confirmedWidth, closeTo(trackWidth * 50 / 82, .01));
    expect(failureWidth, closeTo(trackWidth * .025, .01));
    expect(find.text('详情'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
    await tester.tap(find.text('详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('REDMI Watch 5'), findsOneWidget);
    expect(find.textContaining('fedcba9876543210'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(retryCalls, 1);
    await tester.tap(find.text('清除'));
    await tester.pump();
    expect(clearCalls, 1);
  });

  testWidgets('安装警告倒计时结束后才能确认，且可取消', (tester) async {
    Future<bool?> openDialog() async => showDialog<bool>(
          context: tester.element(find.byType(Scaffold)),
          barrierDismissible: false,
          builder: (_) => InstallWarningDialog(
            title: '表盘分辨率不匹配',
            message: '安装后可能无法正常显示或使用',
            rows: const [
              ('表盘分辨率', '336×480', false),
              ('设备分辨率', '432×514', true),
              ('文件名', 'demo.face', false),
            ],
            onConfirm: () {},
          ),
        );

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final cancelled = openDialog();
    await tester.pumpAndSettle();
    expect(find.text('表盘分辨率不匹配'), findsOneWidget);
    expect(find.text('仍然安装（3）'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await cancelled, isFalse);

    final continued = openDialog();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.tap(find.text('仍然安装'));
    await tester.pumpAndSettle();
    expect(await continued, isTrue);
  });

  testWidgets('安装警告零秒立即启用且 Esc 可取消', (tester) async {
    var confirmed = false;
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final result = showDialog<bool>(
      context: tester.element(find.byType(Scaffold)),
      barrierDismissible: false,
      builder: (_) => InstallWarningDialog(
        title: '警告',
        message: '请确认',
        rows: const [],
        countdownSeconds: 0,
        onConfirm: () => confirmed = true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('仍然安装'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(await result, isFalse);
    expect(confirmed, isFalse);
  });

  testWidgets('解锁码警示条使用浅色主题 errorContainer 角色', (tester) async {
    final controller = DeviceController();
    addTearDown(controller.dispose);
    final scheme = ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: Brightness.light,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme, useMaterial3: true),
        home: Scaffold(body: ToolsPage(controller: controller)),
      ),
    );

    final banner = tester.widget<Container>(
      find.byKey(const ValueKey('unlock-warning-banner')),
    );
    final decoration = banner.decoration as BoxDecoration;
    expect(decoration.color, scheme.errorContainer);
    final warningText = tester.widget<Text>(find.descendant(
      of: find.byKey(const ValueKey('unlock-warning-banner')),
      matching: find.byType(Text),
    ));
    expect(warningText.style?.color, scheme.onErrorContainer);
  });

  testWidgets('设置页显示发送窗口间隔与每窗口分片数', (tester) async {
    int? interval;
    int? windowSize;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TransferSettingsPage(
          connectionMode: ConnectionMode.modern,
          preferredInstallTarget: InstallPreference.watchface,
          connectionModeEnabled: true,
          segmentIntervalMs: 5,
          massWindowSize: 50,
          onConnectionModeChanged: (_) {},
          onSegmentIntervalChanged: (value) => interval = value,
          onMassWindowSizeChanged: (value) => windowSize = value,
          onPreferredInstallTargetChanged: (_) {},
        ),
      ),
    ));

    await tester.scrollUntilVisible(
      find.text('发送窗口间隔'),
      250,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('发送窗口间隔'), findsOneWidget);
    expect(find.text('5 ms'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('每窗口分片数'),
      250,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('每窗口分片数'), findsOneWidget);
    expect(find.text('50 片'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('值越小传输速度越慢'),
      250,
      scrollable: find.byType(Scrollable),
    );
    expect(find.text('值越小传输速度越慢'), findsOneWidget);
    expect(interval, isNull);
    expect(windowSize, isNull);
  });

  testWidgets('自动同步时间与时区默认关闭并可开启', (tester) async {
    bool? changedTo;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransferSettingsPage(
            connectionMode: ConnectionMode.modern,
            preferredInstallTarget: InstallPreference.watchface,
            connectionModeEnabled: true,
            segmentIntervalMs: 5,
            massWindowSize: 3,
            onConnectionModeChanged: (_) {},
            onSegmentIntervalChanged: (_) {},
            onMassWindowSizeChanged: (_) {},
            onAutoTimeSyncChanged: (value) => changedTo = value,
            onPreferredInstallTargetChanged: (_) {},
          ),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('自动同步时间与时区'),
      300,
      scrollable: find.byType(Scrollable),
    );
    await tester.ensureVisible(find.text('自动同步时间与时区'));
    await tester.pumpAndSettle();
    final tileFinder = find.ancestor(
      of: find.text('自动同步时间与时区'),
      matching: find.byType(SwitchListTile),
    );
    final tile = tester.widget<SwitchListTile>(tileFinder);
    expect(tile.value, isFalse);
    await tester.tap(find.text('自动同步时间与时区'));
    expect(changedTo, isTrue);
  });

  testWidgets('悬浮安装窗开关默认关闭并转发设置变更', (tester) async {
    bool? changedTo;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransferSettingsPage(
            connectionMode: ConnectionMode.modern,
            preferredInstallTarget: InstallPreference.watchface,
            connectionModeEnabled: true,
            segmentIntervalMs: 5,
            massWindowSize: 3,
            onConnectionModeChanged: (_) {},
            onSegmentIntervalChanged: (_) {},
            onMassWindowSizeChanged: (_) {},
            onFloatingInstallWindowEnabledChanged: (value) => changedTo = value,
            onPreferredInstallTargetChanged: (_) {},
          ),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('启用悬浮安装窗'),
      250,
      scrollable: find.byType(Scrollable),
    );
    final tileFinder = find.ancestor(
      of: find.text('启用悬浮安装窗'),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(tileFinder).value, isFalse);
    await tester.tap(find.text('启用悬浮安装窗'));
    expect(changedTo, isTrue);
  });

  testWidgets('设置页重新查看引导入口转发回调', (tester) async {
    var replayCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransferSettingsPage(
            connectionMode: ConnectionMode.modern,
            preferredInstallTarget: InstallPreference.watchface,
            connectionModeEnabled: true,
            segmentIntervalMs: 5,
            massWindowSize: 3,
            onConnectionModeChanged: (_) {},
            onSegmentIntervalChanged: (_) {},
            onMassWindowSizeChanged: (_) {},
            onPreferredInstallTargetChanged: (_) {},
            onReplayOobe: () => replayCalls++,
          ),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('重新查看使用引导'),
      300,
      scrollable: find.byType(Scrollable),
    );
    final replayTile = find.ancestor(
      of: find.text('重新查看使用引导'),
      matching: find.byType(ListTile),
    );
    await tester.ensureVisible(replayTile);
    await tester.pumpAndSettle();
    await tester.tap(replayTile);
    expect(replayCalls, 1);
  });

  testWidgets('桌面集成不可用时禁用悬浮安装窗', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TransferSettingsPage(
            connectionMode: ConnectionMode.modern,
            preferredInstallTarget: InstallPreference.watchface,
            connectionModeEnabled: true,
            segmentIntervalMs: 5,
            massWindowSize: 3,
            onConnectionModeChanged: (_) {},
            onSegmentIntervalChanged: (_) {},
            onMassWindowSizeChanged: (_) {},
            onPreferredInstallTargetChanged: (_) {},
          ),
        ),
      ),
    );

    await tester.scrollUntilVisible(
      find.text('启用悬浮安装窗'),
      250,
      scrollable: find.byType(Scrollable),
    );
    final tileFinder = find.ancestor(
      of: find.text('启用悬浮安装窗'),
      matching: find.byType(SwitchListTile),
    );
    expect(tester.widget<SwitchListTile>(tileFinder).onChanged, isNull);
    expect(find.text('悬浮安装窗目前仅支持 Windows。'), findsOneWidget);
  });

  testWidgets('Split Button 主区跟随偏好并复用安装回调', (tester) async {
    InstallKind? installed;

    Future<void> pump(InstallKind target) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: InstallSplitButton(
                preferredTarget: target == InstallKind.watchface
                    ? InstallPreference.watchface
                    : InstallPreference.quickApp,
                enabled: true,
                onInstall: (value) async => installed = value,
                onInstallFirmware: () async {},
              ),
            ),
          ),
        );

    await pump(InstallKind.watchface);
    expect(find.text('安装表盘 .bin / .face'), findsOneWidget);
    final popup = tester.widget(
      find.byKey(const ValueKey('install-menu-popup')),
    ) as dynamic;
    expect(
      popup.borderRadius,
      const BorderRadius.horizontal(
        left: Radius.circular(6),
        right: Radius.circular(28),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('preferred-install-button')));
    expect(installed, InstallKind.watchface);

    await tester.tap(find.byKey(const ValueKey('install-menu-popup')));
    await tester.pumpAndSettle();
    expect(find.text('安装快应用 .rpk'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('alternate-install-menu-item')));
    await tester.pumpAndSettle();
    expect(installed, InstallKind.quickApp);

    await pump(InstallKind.quickApp);
    expect(find.text('安装快应用 .rpk'), findsOneWidget);
  });

  testWidgets('Split Button 固件菜单使用独立回调', (tester) async {
    var installCalls = 0;
    var firmwareCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InstallSplitButton(
            preferredTarget: InstallPreference.watchface,
            enabled: true,
            onInstall: (_) async => installCalls++,
            onInstallFirmware: () async => firmwareCalls++,
          ),
        ),
      ),
    );

    final menuButtonBottom = tester
        .getRect(find.byKey(const ValueKey('install-menu-button')))
        .bottom;
    await tester.tap(find.byKey(const ValueKey('install-menu-popup')));
    await tester.pumpAndSettle();
    expect(find.text('安装固件 .zip / .bin（协议取证中）'), findsOneWidget);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('firmware-install-menu-item')))
          .top,
      greaterThan(menuButtonBottom),
    );
    await tester.tap(find.byKey(const ValueKey('firmware-install-menu-item')));
    await tester.pumpAndSettle();

    expect(firmwareCalls, 1);
    expect(installCalls, 0);
  });

  testWidgets('均有开发时右侧为快应用主区和固件下拉区', (tester) async {
    InstallKind? installed;
    var firmwareCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InstallSplitButton(
            preferredTarget: InstallPreference.both,
            enabled: true,
            onInstall: (kind) async => installed = kind,
            onInstallFirmware: () async => firmwareCalls++,
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('both-quick-app-install-button')),
    );
    expect(installed, InstallKind.quickApp);

    final menuButtonBottom = tester
        .getRect(find.byKey(const ValueKey('both-firmware-menu-button')))
        .bottom;
    await tester.tap(find.byKey(const ValueKey('both-firmware-menu-popup')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('both-firmware-install-menu-item')),
      findsOneWidget,
    );
    expect(
      tester
          .getRect(
            find.byKey(const ValueKey('both-firmware-install-menu-item')),
          )
          .top,
      greaterThan(menuButtonBottom),
    );
    await tester.tap(
      find.byKey(const ValueKey('both-firmware-install-menu-item')),
    );
    await tester.pumpAndSettle();
    expect(firmwareCalls, 1);
  });

  testWidgets('Split Button 未鉴权时两侧均禁用且副菜单不可打开', (tester) async {
    var installCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InstallSplitButton(
            preferredTarget: InstallPreference.watchface,
            enabled: false,
            onInstall: (_) async => installCalls++,
            onInstallFirmware: () async => installCalls++,
          ),
        ),
      ),
    );

    final preferredSegment = find.descendant(
      of: find.byKey(const ValueKey('preferred-install-button')),
      matching: find.byKey(const ValueKey('install-segment-material')),
    );
    final alternateSegment = find.descendant(
      of: find.byKey(const ValueKey('install-menu-button')),
      matching: find.byKey(const ValueKey('install-segment-material')),
    );
    final preferredMaterial = tester.widget<Material>(preferredSegment);
    final alternateMaterial = tester.widget<Material>(alternateSegment);
    final colors = Theme.of(
      tester.element(find.byKey(const ValueKey('preferred-install-button'))),
    ).colorScheme;
    final expectedBackground = colors.onSurface.withValues(alpha: 0.12);
    final expectedForeground = colors.onSurface.withValues(alpha: 0.38);
    expect(preferredMaterial.color, expectedBackground);
    expect(alternateMaterial.color, expectedBackground);

    final preferredIcon = tester.widget<Icon>(find.byIcon(Icons.watch));
    final alternateIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(const ValueKey('install-menu-chevron')),
        matching: find.byType(Icon),
      ),
    );
    expect(preferredIcon.color, expectedForeground);
    expect(alternateIcon.color, expectedForeground);

    await tester.tap(
      find.byKey(const ValueKey('preferred-install-button')),
      warnIfMissed: false,
    );

    await tester.tap(find.byKey(const ValueKey('install-menu-popup')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('alternate-install-menu-item')),
      findsNothing,
    );
    expect(installCalls, 0);
  });

  testWidgets('Split Button 菜单打开时切换页面不会触发生命周期断言', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InstallSplitButton(
            preferredTarget: InstallPreference.watchface,
            enabled: true,
            onInstall: (_) async {},
            onInstallFirmware: () async {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('install-menu-popup')));
    await tester.pump();
    expect(find.byKey(const ValueKey('alternate-install-menu-item')),
        findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('队列页面'))),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('队列页面'), findsOneWidget);
  });

  testWidgets('队列空态隐藏头部操作并显示文件投放入口', (tester) async {
    final controller = DeviceController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: QueuePage(controller: controller))),
    );

    expect(find.text('安装队列 · 0 项'), findsOneWidget);
    expect(find.text('队列为空'), findsOneWidget);
    expect(find.text('选择文件'), findsOneWidget);
    expect(find.text('添加文件'), findsNothing);
    expect(find.byKey(const ValueKey('queue-add-more')), findsNothing);
  });

  testWidgets('队列有项目时显示两个添加入口并用勾表示完成', (tester) async {
    final controller = DeviceController();
    addTearDown(controller.dispose);
    final metadata = InstallMetadata(
      fileName: 'demo.face',
      fileSize: 1024,
      md5Hex: '0123456789abcdef0123456789abcdef',
      sha256Hex: '0' * 64,
    );
    controller.enqueue(
      InstallRequest(
        kind: InstallKind.watchface,
        path: r'C:\packages\demo.face',
        metadata: metadata,
      ),
    );
    controller.installQueue.single.stage = QueueStage.done;

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: QueuePage(controller: controller))),
    );

    expect(find.text('添加文件'), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-add-more')), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('已完成'), findsNothing);
  });

  testWidgets('队列失败后始终保留重试入口', (tester) async {
    final controller = DeviceController();
    addTearDown(controller.dispose);
    controller.enqueue(
      InstallRequest(
        kind: InstallKind.watchface,
        path: r'C:\packages\broken.face',
        metadata: InstallMetadata(
          fileName: 'broken.face',
          fileSize: 1024,
          md5Hex: '0123456789abcdef0123456789abcdef',
          sha256Hex: '0' * 64,
          faceId: '1234',
        ),
      ),
    );
    controller.installQueue.single
      ..stage = QueueStage.failed
      ..failureAttempts = 2;

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: QueuePage(controller: controller))),
    );

    expect(find.text('失败 · 重试'), findsOneWidget);
    final chip = tester.widget<ActionChip>(find.byType(ActionChip));
    expect(chip.onPressed, isNotNull);
  });

  test('取消共享安装前确认时从队列移除条目且不计失败', () async {
    final controller = DeviceController();
    addTearDown(controller.dispose);
    controller.queueInstallPreparer = (_) async => null;
    controller.enqueue(
      InstallRequest(
        kind: InstallKind.quickApp,
        path: r'C:\packages\needs-version.rpk',
        metadata: InstallMetadata(
          fileName: 'needs-version.rpk',
          fileSize: 2048,
          md5Hex: '0123456789abcdef0123456789abcdef',
          sha256Hex: '0' * 64,
          packageName: 'com.example.demo',
        ),
      ),
    );

    await controller.runQueue();

    expect(controller.installQueue, isEmpty);
    expect(controller.latestTask, isNull);
  });

  test('失败项保留重试且不阻塞后续等待项', () async {
    final controller = DeviceController();
    addTearDown(controller.dispose);
    var prepareCalls = 0;
    controller.queueInstallPreparer = (request) async {
      prepareCalls++;
      return request;
    };
    final failed = QueueEntry(
      request: InstallRequest(
        kind: InstallKind.watchface,
        path: r'C:\packages\failed.face',
        metadata: InstallMetadata(
          fileName: 'failed.face',
          fileSize: 1024,
          md5Hex: '0123456789abcdef0123456789abcdef',
          sha256Hex: '0' * 64,
          faceId: '1234',
        ),
      ),
      stage: QueueStage.failed,
    )..failureAttempts = 1;
    controller.installQueue.add(failed);
    controller.enqueue(
      InstallRequest(
        kind: InstallKind.quickApp,
        path: r'C:\packages\next.rpk',
        metadata: InstallMetadata(
          fileName: 'next.rpk',
          fileSize: 2048,
          md5Hex: 'fedcba9876543210fedcba9876543210',
          sha256Hex: '1' * 64,
          packageName: 'com.example.next',
          versionCode: 1,
        ),
      ),
    );

    await controller.runQueue();

    expect(prepareCalls, 1);
    expect(failed.canRetry, isTrue);
    expect(controller.installQueue.last.stage, QueueStage.waiting);
  });

  test('共享安装前检查识别分辨率、Lua 与缺失 RPK 版本', () {
    const preflight = InstallRequestPreflight();
    final controller = DeviceController();
    addTearDown(controller.dispose);
    controller.connectedProfile = DeviceProfile.redmiWatch5;

    final watchface = InstallRequest(
      kind: InstallKind.watchface,
      path: r'C:\packages\demo.face',
      metadata: InstallMetadata(
        fileName: 'demo.face',
        fileSize: 1024,
        md5Hex: '0123456789abcdef0123456789abcdef',
        sha256Hex: '0' * 64,
        faceId: '1234',
        watchfaceResolutions: const [WatchfaceResolution(336, 480)],
        containsLua: true,
      ),
    );
    final quickApp = InstallRequest(
      kind: InstallKind.quickApp,
      path: r'C:\packages\demo.rpk',
      metadata: InstallMetadata(
        fileName: 'demo.rpk',
        fileSize: 2048,
        md5Hex: '0123456789abcdef0123456789abcdef',
        sha256Hex: '0' * 64,
        packageName: 'com.example.demo',
      ),
    );

    expect(preflight.requiresInteraction(controller, watchface), isTrue);
    expect(preflight.requiresInteraction(controller, quickApp), isTrue);
  });

  test('从队列页加入请求保持等待，直到显式开始安装', () {
    final controller = DeviceController();
    addTearDown(controller.dispose);
    controller.enqueue(
      InstallRequest(
        kind: InstallKind.quickApp,
        path: r'C:\packages\demo.rpk',
        metadata: InstallMetadata(
          fileName: 'demo.rpk',
          fileSize: 2048,
          md5Hex: '0123456789abcdef0123456789abcdef',
          sha256Hex: '0' * 64,
        ),
      ),
    );

    expect(controller.installQueue, hasLength(1));
    expect(controller.installQueue.single.stage, QueueStage.waiting);
    expect(controller.latestTask, isNull);
  });
}
