import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/application/device_controller.dart';
import 'package:wristload/domain/watch_app.dart';
import 'package:wristload/presentation/pages/apps_page.dart';

void main() {
  testWidgets('快应用页在会话就绪后只自动读取一次，并在断开后为下一会话重置', (tester) async {
    final controller = _AppsPageController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppsPage(controller: controller)),
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
}

class _AppsPageController extends DeviceController {
  int refreshCalls = 0;

  void setSessionReady(bool value) {
    sessionReady = value;
    notifyListeners();
  }

  @override
  Future<List<WatchAppItem>> refreshInstalledWatchApps() async {
    refreshCalls++;
    return installedWatchApps;
  }
}
