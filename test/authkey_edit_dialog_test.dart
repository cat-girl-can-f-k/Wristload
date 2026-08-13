import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
