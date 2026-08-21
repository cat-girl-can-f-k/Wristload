import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/domain/device_profile.dart';
import 'package:wristload/domain/install_preference_store.dart';
import 'package:wristload/domain/resource_install_target_policy.dart';
import 'package:wristload/presentation/pages/settings_page.dart';

void main() {
  const allConnectedLabel = '为所有已连接的设备安装(可能会出现奇奇怪怪的bug)';
  const primaryWarning = '开启后，拖入资源将会给所有已连接的设备安装。这可能会导致兼容性问题。';

  testWidgets('所有设备安装需在五秒警告后确认才会保存', (tester) async {
    ResourceInstallTargetPolicy? changed;
    await tester.pumpWidget(
      _settingsPage(
        onResourceInstallTargetPolicyChanged: (value) => changed = value,
      ),
    );

    expect(find.text(allConnectedLabel), findsOneWidget);
    await tester.tap(find.text(allConnectedLabel));
    await tester.pump();

    expect(find.text(primaryWarning), findsOneWidget);
    expect(
      find.text('经过测试，启用了该功能会触发各式各样的bug。该功能不建议开启。如需开启，等到5秒后则可开启'),
      findsOneWidget,
    );
    final countdownWarning = tester.widget<Text>(
      find.byKey(const ValueKey('all-connected-install-warning')),
    );
    expect(
      countdownWarning.style?.color,
      Theme.of(tester.element(find.byType(AlertDialog))).colorScheme.error,
    );
    final initialConfirm = find.widgetWithText(FilledButton, '确认开启（5）');
    expect(tester.widget<FilledButton>(initialConfirm).onPressed, isNull);
    expect(changed, isNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(changed, isNull);

    await tester.tap(find.text(allConnectedLabel));
    await tester.pump();
    for (var secondsLeft = 4; secondsLeft > 0; secondsLeft--) {
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('确认开启（$secondsLeft）'), findsOneWidget);
      expect(
        find.text('经过测试，启用了该功能会触发各式各样的bug。该功能不建议开启。如需开启，等到$secondsLeft秒后则可开启'),
        findsOneWidget,
      );
    }

    await tester.pump(const Duration(seconds: 1));
    final enabledConfirm = find.widgetWithText(FilledButton, '确认开启');
    expect(tester.widget<FilledButton>(enabledConfirm).onPressed, isNotNull);
    expect(
      find.text('经过测试，启用了该功能会触发各式各样的bug。该功能不建议开启。如需开启，等到0秒后则可开启'),
      findsOneWidget,
    );

    await tester.tap(enabledConfirm);
    await tester.pumpAndSettle();
    expect(changed?.mode, ResourceInstallTargetMode.allConnected);
  });

  testWidgets('关闭所有设备安装警告不会更改当前策略', (tester) async {
    ResourceInstallTargetPolicy? changed;
    await tester.pumpWidget(
      _settingsPage(
        onResourceInstallTargetPolicyChanged: (value) => changed = value,
      ),
    );

    await tester.tap(find.text(allConnectedLabel));
    await tester.pump();
    await tester.tapAt(const Offset(1, 1));
    await tester.pumpAndSettle();

    expect(find.text('确认开启多设备安装？'), findsNothing);
    expect(changed, isNull);
  });

  testWidgets('macOS 显示强制安装表盘开关并转发变更', (tester) async {
    bool? changed;
    await tester.pumpWidget(
      _settingsPage(
        showForceWatchfaceInstall: true,
        onForceWatchfaceInstallChanged: (value) => changed = value,
      ),
    );

    await tester.scrollUntilVisible(
      find.text('强制安装表盘'),
      250,
      scrollable: find.byType(Scrollable),
    );
    final tileFinder = find.ancestor(
      of: find.text('强制安装表盘'),
      matching: find.byType(SwitchListTile),
    );
    final tile = tester.widget<SwitchListTile>(tileFinder);
    expect(tile.value, isFalse);
    expect(find.text('安装之前删除同id表盘，然后安装新的表盘'), findsOneWidget);

    await tester.tap(tileFinder);
    expect(changed, isTrue);
  });
}

Widget _settingsPage({
  ValueChanged<ResourceInstallTargetPolicy>?
  onResourceInstallTargetPolicyChanged,
  bool showForceWatchfaceInstall = false,
  ValueChanged<bool>? onForceWatchfaceInstallChanged,
}) => MaterialApp(
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
      onResourceInstallTargetPolicyChanged:
          onResourceInstallTargetPolicyChanged,
      showForceWatchfaceInstall: showForceWatchfaceInstall,
      onForceWatchfaceInstallChanged: onForceWatchfaceInstallChanged,
    ),
  ),
);
