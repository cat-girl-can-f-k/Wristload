import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wristload/application/theme_controller.dart';

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
}
