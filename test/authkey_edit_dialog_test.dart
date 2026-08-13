import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/domain/auth_key_binding.dart';
import 'package:wristload/main.dart';

void main() {
  testWidgets('authkey editor keeps normal selection behavior and saves replacement',
      (tester) async {
    const initialKey = '0123456789abcdef0123456789abcdef';
    const replacementKey = 'fedcba9876543210fedcba9876543210';
    Future<String?>? dialogResult;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                dialogResult = showDialog<String>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => buildAuthKeyEditDialogForTesting(
                    deviceName: '测试设备',
                    initialValue: initialKey,
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final fieldFinder = find.byType(TextFormField);
    expect(fieldFinder, findsOneWidget);
    final field = tester.widget<TextFormField>(fieldFinder);
    expect(field.controller!.text, initialKey);

    await tester.tap(fieldFinder);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.enterText(fieldFinder, replacementKey);

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(await dialogResult, replacementKey);
  });

  testWidgets('history binding picker keeps selected device until modification',
      (tester) async {
    final bindings = [
      AuthKeyBinding(
        id: 'device-a',
        name: '设备 A',
        uuid: 'device-a',
        updatedAt: DateTime(2026, 1, 1),
      ),
      AuthKeyBinding(
        id: 'device-b',
        name: '设备 B',
        uuid: 'device-b',
        updatedAt: DateTime(2026, 1, 2),
      ),
    ];
    Future<AuthKeyBinding?>? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                result = showDialog<AuthKeyBinding>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => buildAuthKeyBindingPickerForTesting(
                    bindings: bindings,
                  ),
                );
              },
              child: const Text('打开列表'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设备 B'));
    await tester.pump();

    final radio = tester.widget<Radio<AuthKeyBinding>>(
      find.byWidgetPredicate(
        (widget) => widget is Radio<AuthKeyBinding> &&
            widget.value?.id == 'device-b',
      ),
    );
    expect(radio.groupValue?.id, 'device-b');
    expect(find.widgetWithText(FilledButton, '修改'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, '修改'));
    await tester.pumpAndSettle();
    expect((await result)?.id, 'device-b');
  });

  testWidgets('empty history still opens the authkey editor', (tester) async {
    Future<String?>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                result = showDialog<String>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => buildAuthKeyEditDialogForTesting(
                    initialValue: '0123456789abcdef0123456789abcdef',
                  ),
                );
              },
              child: const Text('修改 authkey'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('修改 authkey'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsOneWidget);
    expect(find.text('0123456789abcdef0123456789abcdef'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets('selected history binding can be deleted without closing picker',
      (tester) async {
    final bindings = [
      AuthKeyBinding(
        id: 'device-a',
        name: '设备 A',
        uuid: 'device-a',
        updatedAt: DateTime(2026, 1, 1),
      ),
      AuthKeyBinding(
        id: 'device-b',
        name: '设备 B',
        uuid: 'device-b',
        updatedAt: DateTime(2026, 1, 2),
      ),
    ];
    String? deletedId;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () {
                showDialog<AuthKeyBinding>(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => buildAuthKeyBindingPickerForTesting(
                    bindings: bindings,
                    onDelete: (id) async => deletedId = id,
                  ),
                );
              },
              child: const Text('打开列表'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设备 B'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除历史绑定？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(deletedId, 'device-b');
    expect(find.text('设备 A'), findsOneWidget);
    expect(find.text('设备 B'), findsNothing);
    expect(find.text('历史绑定设备'), findsOneWidget);
  });
}
