import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/application/device_controller.dart';
import 'package:wristload/domain/watchface.dart';
import 'package:wristload/presentation/pages/watchfaces_page.dart';

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('表盘页在会话就绪后只自动读取一次，并在断开后为下一会话重置', (tester) async {
    final controller = _WatchfacesPageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WatchfacesPage(controller: controller)),
      ),
    );
    await tester.pump();
    expect(controller.refreshCalls, 0);

    controller.setSessionReady(true);
    await tester.pump();
    await tester.pump();
    expect(controller.refreshCalls, 1);

    controller.notifyListeners();
    await tester.pump();
    expect(controller.refreshCalls, 1);

    controller.setSessionReady(false);
    await tester.pump();
    controller.setSessionReady(true);
    await tester.pump();
    await tester.pump();
    expect(controller.refreshCalls, 2);
  });

  testWidgets('macOS 表盘卡片会切换对应的设备表盘', (tester) async {
    final controller = _WatchfacesPageController()
      ..installedWatchfaces = const <WatchfaceItem>[
        WatchfaceItem(
          id: '42',
          name: 'Classic',
          isCurrent: false,
          canRemove: true,
          versionCode: 1,
        ),
      ]
      ..setSessionReady(true);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: WatchfacesPage(controller: controller)),
      ),
    );
    await tester.pump();

    expect(find.text('切换'), findsOneWidget);
    await tester.tap(find.text('切换'));
    await tester.pump();

    expect(controller.activationCalls, 1);
    expect(controller.lastActivated?.id, '42');
  });
}

class _WatchfacesPageController extends DeviceController {
  int refreshCalls = 0;
  int activationCalls = 0;
  WatchfaceItem? lastActivated;

  void setSessionReady(bool value) {
    sessionReady = value;
    notifyListeners();
  }

  @override
  Future<List<WatchfaceItem>> refreshInstalledWatchfaces() async {
    refreshCalls++;
    return installedWatchfaces;
  }

  @override
  Future<bool> activateWatchface(WatchfaceItem watchface) async {
    activationCalls++;
    lastActivated = watchface;
    return true;
  }
}
