import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/presentation/home_widgets.dart';

void main() {
  testWidgets('主页诊断日志开关转发状态且平台不可用时禁用', (tester) async {
    bool? changed;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DiagnosticLogToggle(
          entryCount: 12,
          enabled: false,
          onChanged: (value) => changed = value,
        ),
      ),
    ));

    expect(find.text('独立诊断日志窗口'), findsOneWidget);
    expect(find.textContaining('当前 12 条'), findsOneWidget);
    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.value, isFalse);
    await tester.tap(find.text('独立诊断日志窗口'));
    expect(changed, isTrue);

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: DiagnosticLogToggle(
          entryCount: 12,
          enabled: true,
          onChanged: null,
        ),
      ),
    ));
    final unavailable =
        tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(unavailable.value, isFalse);
    expect(unavailable.onChanged, isNull);
    expect(find.text('当前平台不支持独立日志窗口'), findsOneWidget);
  });

  testWidgets('扫描结果按安装能力分组且其他设备可折叠', (tester) async {
    final installable = _discovery(
      address: 'A1:B2:C3:D4:E5:F6',
      name: 'Xiaomi Smart Band 9 Pro',
      rssi: -48,
    );
    final other = _discovery(
      address: '10:20:30:40:50:60',
      name: 'Wireless Speaker',
      rssi: -62,
    );
    DiscoveredEventArgs? connected;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScanResultsList(
          results: [installable, other],
          onConnect: (result) => connected = result,
        ),
      ),
    ));

    expect(find.text('可安装的设备 · 1'), findsOneWidget);
    expect(find.text('其他设备 · 1（不支持安装）'), findsOneWidget);
    expect(find.text('小米手环 9 Pro'), findsOneWidget);
    expect(find.text('✓ 可安装'), findsOneWidget);
    expect(find.text('非手环设备'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.textContaining('V2 传输'), findsNothing);
    expect(find.textContaining('RFCOMM'), findsNothing);

    await tester.tap(find.text('连接'));
    expect(connected, same(installable));

    await tester.tap(find.text('其他设备 · 1（不支持安装）'));
    await tester.pump();
    expect(find.text('Wireless Speaker'), findsNothing);
    expect(find.text('非手环设备'), findsNothing);
  });

  testWidgets('无效 RSSI 不显示且窄窗口不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ScanResultsList(
            results: [
              _discovery(
                address: 'A1:B2:C3:D4:E5:F6',
                name: 'Xiaomi Smart Band 10 Pro With A Very Long Name',
                rssi: 0,
              ),
              _discovery(
                address: '10:20:30:40:50:60',
                name: 'A Very Long Unsupported Bluetooth Device Name',
                rssi: -80,
              ),
            ],
            onConnect: (_) {},
          ),
        ),
      ),
    ));

    expect(find.textContaining('RSSI'), findsNothing);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('正数 RSSI 才按数据卫生规则显示', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ScanResultsList(
          results: [
            _discovery(
              address: 'A1:B2:C3:D4:E5:F6',
              name: 'Xiaomi Smart Band 9 Pro',
              rssi: 42,
            ),
          ],
          onConnect: (_) {},
        ),
      ),
    ));

    expect(find.text('RSSI 42'), findsOneWidget);
  });
}

DiscoveredEventArgs _discovery({
  required String address,
  required String name,
  required int rssi,
}) =>
    DiscoveredEventArgs(
      _TestPeripheral(UUID.fromAddress(address)),
      rssi,
      Advertisement(name: name),
    );

class _TestPeripheral implements Peripheral {
  const _TestPeripheral(this.uuid);

  @override
  final UUID uuid;
}
