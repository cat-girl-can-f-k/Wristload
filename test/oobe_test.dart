import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:wristload/domain/install_preference_store.dart';
import 'package:wristload/domain/oobe_store.dart';
import 'package:wristload/main.dart';
import 'package:wristload/presentation/oobe_install_preview.dart';
import 'package:wristload/presentation/oobe_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('OOBE 完成状态默认 false 并可持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final store = OobeStore();

    expect(await store.readCompleted(), isFalse);
    await store.markCompleted();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(OobeStore.key), isTrue);
    expect(await store.readCompleted(), isTrue);

    await store.markNotCompleted();
    expect(preferences.getBool(OobeStore.key), isFalse);
    expect(await store.readCompleted(), isFalse);
  });

  testWidgets('OOBE 只能通过底部按钮翻页并保存安装偏好', (tester) async {
    var preference = InstallPreference.watchface;
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: OobePage(
          installPreference: preference,
          onInstallPreferenceChanged: (value) => preference = value,
          onCompleted: () async => completed = true,
        ),
      ),
    );

    expect(find.text('欢迎使用 Wristload'), findsOneWidget);
    expect(find.text('上一步'), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('oobe-dot-0'))),
      const Size(24, 8),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('oobe-dot-1'))),
      const Size(8, 8),
    );

    await tester.drag(find.byType(PageView), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('欢迎使用 Wristload'), findsOneWidget);

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('你的开发偏好'), findsOneWidget);
    expect(find.text('上一步'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('oobe-dot-0'))),
      const Size(8, 8),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('oobe-dot-1'))),
      const Size(24, 8),
    );

    await tester.tap(find.text('均有开发'));
    await tester.pumpAndSettle();
    expect(preference, InstallPreference.both);
    expect(find.text('安装表盘'), findsOneWidget);
    expect(find.text('安装快应用 .rpk'), findsOneWidget);

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('一切就绪'), findsOneWidget);
    expect(find.text('开始使用'), findsOneWidget);

    await tester.tap(find.text('开始使用'));
    await tester.pump();
    expect(completed, isTrue);
  });

  testWidgets('首次启动只进入 OOBE，已完成时直接进入主页', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const WristloadApp(
        initialOobeCompleted: false,
        initialPreference: InstallPreference.quickApp,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OobePage), findsOneWidget);
    expect(find.text('欢迎使用 Wristload'), findsOneWidget);
    expect(find.text('主页'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      const WristloadApp(
        initialOobeCompleted: true,
        initialPreference: InstallPreference.quickApp,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OobePage), findsNothing);
    expect(find.text('Wristload'), findsOneWidget);
    expect(find.text('主页'), findsOneWidget);
  });

  testWidgets('完成 OOBE 持久化偏好并清除引导路由', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const WristloadApp(
        initialOobeCompleted: false,
        initialPreference: InstallPreference.watchface,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('oobe-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('均有开发'));
    await tester.pumpAndSettle();

    var preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(InstallPreferenceStore.key),
      'both',
    );

    await tester.tap(find.byKey(const ValueKey('oobe-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('oobe-next')));
    await tester.pumpAndSettle();

    preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(OobeStore.key), isTrue);
    expect(
      preferences.getString(InstallPreferenceStore.key),
      'both',
    );
    expect(find.byType(OobePage), findsNothing);
    expect(find.text('Wristload'), findsOneWidget);

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(OobePage), findsNothing);
  });

  testWidgets('设置页可重置完成状态并重新进入 OOBE', (tester) async {
    SharedPreferences.setMockInitialValues({
      OobeStore.key: true,
      InstallPreferenceStore.key: 'both',
    });
    await tester.pumpWidget(
      const WristloadApp(
        initialOobeCompleted: true,
        initialPreference: InstallPreference.both,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('重新查看使用引导'),
      250,
      scrollable: find.byType(Scrollable),
    );
    await tester.tap(find.text('重新查看使用引导'));
    await tester.pumpAndSettle();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getBool(OobeStore.key), isFalse);
    expect(
      preferences.getString(InstallPreferenceStore.key),
      'both',
    );
    expect(find.byType(OobePage), findsOneWidget);
    expect(find.text('欢迎使用 Wristload'), findsOneWidget);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isFalse);
  });

  testWidgets('预览第二段平滑伸出且两组间距正确', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> pump(InstallPreference preference) => tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(useMaterial3: true),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 760,
                  child: OobeInstallPreview(preference: preference),
                ),
              ),
            ),
          ),
        );

    await pump(InstallPreference.watchface);
    await tester.pumpAndSettle();
    var primary = tester.getRect(
      find.byKey(const ValueKey('oobe-primary-segment')),
    );
    var secondary = tester.getRect(
      find.byKey(const ValueKey('oobe-secondary-segment')),
    );
    var menu = tester.getRect(
      find.byKey(const ValueKey('oobe-menu-segment')),
    );
    expect(secondary.width, 0);
    expect(menu.left - primary.right, moreOrLessEquals(2, epsilon: .1));
    expect(
      tester
          .widget<IgnorePointer>(
            find.byKey(const ValueKey('oobe-secondary-hit-region')),
          )
          .ignoring,
      isTrue,
    );

    await pump(InstallPreference.both);
    await tester.pump(const Duration(milliseconds: 250));
    secondary = tester.getRect(
      find.byKey(const ValueKey('oobe-secondary-segment')),
    );
    expect(secondary.width, greaterThan(0));
    await tester.pumpAndSettle();

    primary = tester.getRect(
      find.byKey(const ValueKey('oobe-primary-segment')),
    );
    secondary = tester.getRect(
      find.byKey(const ValueKey('oobe-secondary-segment')),
    );
    menu = tester.getRect(find.byKey(const ValueKey('oobe-menu-segment')));
    expect(secondary.left - primary.right, moreOrLessEquals(10, epsilon: .1));
    expect(menu.left - secondary.right, moreOrLessEquals(2, epsilon: .1));
    expect(
      tester
          .widget<IgnorePointer>(
            find.byKey(const ValueKey('oobe-secondary-hit-region')),
          )
          .ignoring,
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('oobe-menu-segment')));
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsOneWidget);
    expect(find.text('安装固件（协议取证中）'), findsOneWidget);
  });

  testWidgets('预览菜单从菜单按钮下方展开', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: OobePage(
          installPreference: InstallPreference.watchface,
          onInstallPreferenceChanged: (_) {},
          onCompleted: () async {},
        ),
      ),
    );

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    final chevron = find.byIcon(Icons.keyboard_arrow_down);
    final buttonBottom = tester.getBottomRight(chevron).dy;

    await tester.tap(chevron);
    await tester.pumpAndSettle();

    final firmware = find.text('安装固件 .zip / .bin（协议取证中）');
    expect(firmware, findsOneWidget);
    expect(tester.getTopLeft(firmware).dy, greaterThan(buttonBottom));
  });
}
