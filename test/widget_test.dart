import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:miwearable_install_tool/domain/device_profile.dart';
import 'package:miwearable_install_tool/domain/install_task.dart';
import 'package:miwearable_install_tool/domain/install_preference_store.dart';
import 'package:miwearable_install_tool/presentation/install_task_card.dart';
import 'package:miwearable_install_tool/presentation/home_widgets.dart';
import 'package:miwearable_install_tool/presentation/install_split_button.dart';
import 'package:miwearable_install_tool/presentation/settings_page.dart';

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
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InstallTaskCard(
          task: task,
          onCancel: () async {},
          onCheck: () async {},
          onRetry: () async {},
        ),
      ),
    ));

    expect(find.text('demo.rpk'), findsOneWidget);
    expect(find.textContaining('1.0 KB/4.0 KB'), findsOneWidget);
    expect(find.textContaining('2.0 KB/s'), findsOneWidget);
    expect(find.textContaining('com.example.demo'), findsOneWidget);
    expect(find.textContaining('版本：42'), findsOneWidget);
    expect(find.textContaining('Xiaomi Smart Band 9 Pro'), findsOneWidget);
    expect(find.textContaining('0123456789abcdef'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
  });

  testWidgets('分辨率不匹配弹窗允许取消或继续安装', (tester) async {
    Future<bool?> openDialog() async => showDialog<bool>(
          context: tester.element(find.byType(Scaffold)),
          builder: (_) => const WatchfaceResolutionDialog(),
        );

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final cancelled = openDialog();
    await tester.pumpAndSettle();
    expect(
      find.text('该表盘分辨率似乎和您的设备不匹配，请问是否要安装？'),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await cancelled, isFalse);

    final continued = openDialog();
    await tester.pumpAndSettle();
    await tester.tap(find.text('仍然安装'));
    await tester.pumpAndSettle();
    expect(await continued, isTrue);
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

    expect(find.text('发送窗口间隔'), findsOneWidget);
    expect(find.text('5 ms'), findsOneWidget);
    expect(find.text('每窗口分片数（实验）'), findsOneWidget);
    expect(find.text('50 片'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('已超过设备协商值 3'),
      250,
      scrollable: find.byType(Scrollable),
    );
    expect(find.textContaining('已超过设备协商值 3'), findsOneWidget);
    expect(interval, isNull);
    expect(windowSize, isNull);
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
              ),
            ),
          ),
        );

    await pump(InstallKind.watchface);
    expect(find.text('安装表盘 .bin'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('preferred-install-button')));
    expect(installed, InstallKind.watchface);

    await tester.tap(find.byKey(const ValueKey('install-menu-button')));
    await tester.pumpAndSettle();
    expect(find.text('安装快应用 .rpk'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('alternate-install-menu-item')));
    await tester.pumpAndSettle();
    expect(installed, InstallKind.quickApp);

    await pump(InstallKind.quickApp);
    expect(find.text('安装快应用 .rpk'), findsOneWidget);
  });

  testWidgets('Split Button 菜单打开时切换页面不会触发生命周期断言', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InstallSplitButton(
            preferredTarget: InstallPreference.watchface,
            enabled: true,
            onInstall: (_) async {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('install-menu-button')));
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
}
