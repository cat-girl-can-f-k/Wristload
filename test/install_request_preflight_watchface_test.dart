import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/application/device_controller.dart';
import 'package:wristload/domain/install_models.dart';
import 'package:wristload/domain/watchface.dart';
import 'package:wristload/presentation/install_request_preflight.dart';

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('同 ID 表盘仅在用户确认后先卸载旧表盘', (tester) async {
    final controller = _WatchfaceConflictController(const [
      WatchfaceItem(
        id: '42',
        name: '旧表盘',
        isCurrent: false,
        canRemove: true,
        versionCode: 1,
      ),
    ]);
    addTearDown(controller.dispose);
    final pageContext = await _pumpContext(tester);
    final preflight = InstallRequestPreflight();

    final result = preflight.prepare(pageContext, controller, _request());
    await tester.pump();
    await tester.pump();

    expect(find.text('检测到同 ID 表盘'), findsOneWidget);
    expect(controller.events, ['read']);
    expect(controller.uninstalledIds, isEmpty);

    await tester.tap(find.text('覆盖安装'));
    await tester.pumpAndSettle();

    expect(await result, isNotNull);
    expect(controller.events, ['read', 'uninstall']);
    expect(controller.uninstalledIds, ['42']);
  });

  testWidgets('取消覆盖不会卸载旧表盘', (tester) async {
    final controller = _WatchfaceConflictController(const [
      WatchfaceItem(
        id: '42',
        name: '旧表盘',
        isCurrent: false,
        canRemove: true,
        versionCode: 1,
      ),
    ]);
    addTearDown(controller.dispose);
    final pageContext = await _pumpContext(tester);

    final result = InstallRequestPreflight().prepare(
      pageContext,
      controller,
      _request(),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(await result, isNull);
    expect(controller.events, ['read']);
    expect(controller.uninstalledIds, isEmpty);
  });

  testWidgets('开启强制安装表盘后直接先卸载同 ID 旧表盘', (tester) async {
    final controller = _WatchfaceConflictController(const [
      WatchfaceItem(
        id: '42',
        name: '旧表盘',
        isCurrent: false,
        canRemove: true,
        versionCode: 1,
      ),
    ])..forceWatchfaceInstall = true;
    addTearDown(controller.dispose);
    final pageContext = await _pumpContext(tester);

    final result = InstallRequestPreflight().prepare(
      pageContext,
      controller,
      _request(),
    );
    await tester.pumpAndSettle();

    expect(find.text('检测到同 ID 表盘'), findsNothing);
    expect(await result, isNotNull);
    expect(controller.events, ['read', 'uninstall']);
    expect(controller.uninstalledIds, ['42']);
  });
}

Future<BuildContext> _pumpContext(WidgetTester tester) async {
  late BuildContext result;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            result = context;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return result;
}

InstallRequest _request() => const InstallRequest(
  kind: InstallKind.watchface,
  path: '/tmp/new.face',
  metadata: InstallMetadata(
    fileName: 'new.face',
    fileSize: 1,
    md5Hex: '00000000000000000000000000000000',
    sha256Hex:
        '0000000000000000000000000000000000000000000000000000000000000000',
    faceId: '42',
  ),
  targetDeviceIds: ['watch-1'],
);

class _WatchfaceConflictController extends DeviceController {
  _WatchfaceConflictController(List<WatchfaceItem> watchfaces) {
    installedWatchfaces = List<WatchfaceItem>.unmodifiable(watchfaces);
    sessionReady = true;
  }

  final List<String> events = [];
  final List<String> uninstalledIds = [];

  @override
  List<ResourceInstallDevice> get resourceInstallDevices => const [
    ResourceInstallDevice(id: 'watch-1', name: '测试设备'),
  ];

  @override
  DeviceController? sessionForDeviceId(String deviceId) =>
      deviceId == 'watch-1' ? this : null;

  @override
  Future<List<WatchfaceItem>> refreshInstalledWatchfaces() async {
    events.add('read');
    return installedWatchfaces;
  }

  @override
  Future<bool> uninstallWatchface(WatchfaceItem watchface) async {
    events.add('uninstall');
    uninstalledIds.add(watchface.id);
    installedWatchfaces = List<WatchfaceItem>.unmodifiable(
      installedWatchfaces.where((item) => item.id != watchface.id),
    );
    return true;
  }
}
