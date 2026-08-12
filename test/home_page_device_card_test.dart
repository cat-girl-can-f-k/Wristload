import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/application/device_controller.dart';
import 'package:wristload/domain/install_preference_store.dart';
import 'package:wristload/main.dart' as app;

void main() {
  testWidgets('已连接卡片只在统计块显示电量并放大设备名称', (tester) async {
    final deviceUuid = UUID.fromAddress('A1:B2:C3:D4:E5:F6');
    final controller = DeviceController()
      ..connectedDevice = _TestPeripheral(deviceUuid)
      ..connectedDeviceName = 'REDMI Watch 5'
      ..batteryPercent = 100;
    addTearDown(controller.dispose);

    final theme = ThemeData(
      textTheme: const TextTheme(
        titleMedium: TextStyle(fontSize: 16),
        titleLarge: TextStyle(fontSize: 24),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: app.HomePage(
            controller: controller,
            preferredInstallTarget: InstallPreference.watchface,
            onPreferredInstallTargetChanged: (_) {},
          ),
        ),
      ),
    );

    final title = tester.widget<Text>(find.text('已连接：REDMI Watch 5'));
    expect(title.style?.fontSize, 24);
    expect(find.text('已连接'), findsOneWidget);
    expect(find.text('电量 100%'), findsNothing);
    expect(find.text('电量'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.byIcon(Icons.battery_std), findsOneWidget);
    expect(find.text(deviceUuid.toString()), findsOneWidget);
  });
}

class _TestPeripheral implements Peripheral {
  const _TestPeripheral(this.uuid);

  @override
  final UUID uuid;
}
