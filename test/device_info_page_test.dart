import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wristload/application/device_controller.dart';
import 'package:wristload/main.dart' show openVerifiedDeviceInfo;
import 'package:wristload/presentation/device_info_page.dart';

void main() {
  const secureStoreChannel = MethodChannel('wristload/secure_store');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStoreChannel, (call) async {
      switch (call.method) {
        case 'read':
        case 'readFor':
          return null;
        case 'write':
        case 'writeFor':
        case 'delete':
        case 'deleteFor':
          return null;
      }
      throw MissingPluginException('Unexpected secure store call: ${call.method}');
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStoreChannel, null);
  });

  testWidgets('详情页删除已保存设备但保持当前连接', (tester) async {
    final controller = DeviceController()
      ..connectedDevice = _TestPeripheral(
        UUID.fromAddress('A1:B2:C3:D4:E5:F6'),
      )
      ..connectedDeviceName = 'Xiaomi Smart Band 10'
      ..authKey = '0123456789abcdef0123456789abcdef'
      ..sessionReady = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: DeviceInfoPage(controller: controller)),
    );

    expect(
      find.byKey(const ValueKey('delete-saved-device-button')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('delete-saved-device-button')));
    await tester.pumpAndSettle();

    expect(find.text('删除已保存设备？'), findsOneWidget);
    expect(find.textContaining('当前连接不会断开'), findsOneWidget);
    expect(find.textContaining('不会删除系统蓝牙配对'), findsOneWidget);
    expect(find.textContaining('下次连接时必须手动输入 authkey'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除设备'));
    await tester.pumpAndSettle();

    expect(controller.authKey, isNull);
    expect(controller.hasAuthKey, isFalse);
    expect(controller.connectedDevice, isNotNull);
    expect(controller.sessionReady, isTrue);
    expect(find.text('未设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('delete-saved-device-button')), findsOneWidget);
    expect(find.textContaining('已删除已保存设备'), findsOneWidget);
  });

  testWidgets('未完成 authkey 鉴权时不展示设备详情或删除入口', (tester) async {
    final controller = DeviceController()
      ..connectedDevice = _TestPeripheral(
        UUID.fromAddress('A1:B2:C3:D4:E5:F6'),
      )
      ..connectedDeviceName = 'Xiaomi Smart Band 10'
      ..authKey = '0123456789abcdef0123456789abcdef'
      ..sessionReady = false;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(home: DeviceInfoPage(controller: controller)),
    );
    await tester.pump();

    expect(
      find.text('设备未处于已验证连接状态，无法查看设备详情。'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('delete-saved-device-button')),
      findsNothing,
    );
    expect(find.text('Xiaomi Smart Band 10'), findsNothing);
  });

  testWidgets('认证状态在点击前失效时不会进入设备详情', (tester) async {
    final controller = DeviceController()
      ..connectedDevice = _TestPeripheral(
        UUID.fromAddress('A1:B2:C3:D4:E5:F6'),
      )
      ..connectedDeviceName = 'Xiaomi Smart Band 10'
      ..authKey = '0123456789abcdef0123456789abcdef'
      ..sessionReady = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => openVerifiedDeviceInfo(context, controller),
              child: const Text('打开详情'),
            ),
          ),
        ),
      ),
    );

    // This intentionally leaves the already-built button in place to cover
    // the tap/rebuild race that previously allowed the phantom page.
    controller.sessionReady = false;
    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();

    expect(find.byType(DeviceInfoPage), findsNothing);
    expect(find.text('打开详情'), findsOneWidget);
  });

  testWidgets('已打开的详情页在连接失效后自动返回上一页', (tester) async {
    final controller = DeviceController()
      ..connectedDevice = _TestPeripheral(
        UUID.fromAddress('A1:B2:C3:D4:E5:F6'),
      )
      ..connectedDeviceName = 'Xiaomi Smart Band 10'
      ..authKey = '0123456789abcdef0123456789abcdef'
      ..sessionReady = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => DeviceInfoPage(controller: controller),
                ),
              ),
              child: const Text('打开详情'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('delete-saved-device-button')), findsOneWidget);

    controller.sessionReady = false;
    controller.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('打开详情'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('delete-saved-device-button')),
      findsNothing,
    );
  });

  testWidgets('详情页在确认删除对话框打开时断开也会返回主页', (tester) async {
    final controller = DeviceController()
      ..connectedDevice = _TestPeripheral(
        UUID.fromAddress('A1:B2:C3:D4:E5:F6'),
      )
      ..connectedDeviceName = 'Xiaomi Smart Band 10'
      ..authKey = '0123456789abcdef0123456789abcdef'
      ..sessionReady = true;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => DeviceInfoPage(controller: controller),
                ),
              ),
              child: const Text('打开详情'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-saved-device-button')));
    await tester.pumpAndSettle();
    expect(find.text('删除已保存设备？'), findsOneWidget);

    controller.sessionReady = false;
    controller.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('打开详情'), findsOneWidget);
    expect(find.text('删除已保存设备？'), findsNothing);
    expect(find.byType(DeviceInfoPage), findsNothing);
  });
}

class _TestPeripheral implements Peripheral {
  const _TestPeripheral(this.uuid);

  @override
  final UUID uuid;
}
