import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wristload/application/theme_controller.dart';
import 'package:wristload/domain/device_profile.dart';
import 'package:wristload/domain/install_preference_store.dart';
import 'package:wristload/presentation/settings_page.dart';

void main() {
  test('theme seed defaults to MD3 purple and persists a selection', () async {
    SharedPreferences.setMockInitialValues({});
    final controller = await ThemeController.create();
    expect(controller.seedColor, ThemeController.defaultSeedColor);

    const selected = Color(0xFF0B57D0);
    await controller.setSeed(selected);
    final restored = await ThemeController.create();

    expect(restored.seedColor, selected);
    controller.dispose();
    restored.dispose();
  });

  testWidgets('theme preview keeps a visible full-width progress bar',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF018786),
            brightness: Brightness.light,
          ),
        ),
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

    final progress = find.byKey(
      const ValueKey('theme-preview-progress-track'),
    );
    await tester.scrollUntilVisible(
      progress,
      300,
      scrollable: find.byType(Scrollable),
    );
    final size = tester.getSize(progress);
    expect(size.width, greaterThan(0));
    expect(size.height, 8);
    expect(
        find.byKey(const ValueKey('theme-preview-confirmed')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('theme-preview-submitted')), findsOneWidget);
  });
}
