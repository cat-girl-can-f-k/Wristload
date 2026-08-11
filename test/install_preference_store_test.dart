import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:miwearable_install_tool/domain/install_preference_store.dart';
import 'package:miwearable_install_tool/domain/install_task.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('安装偏好默认表盘并使用稳定存储值', () async {
    SharedPreferences.setMockInitialValues({});
    final store = InstallPreferenceStore();

    expect(await store.read(), InstallKind.watchface);
    await store.write(InstallKind.quickApp);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString(InstallPreferenceStore.key),
      'quickapp',
    );
    expect(await store.read(), InstallKind.quickApp);
  });

  test('安装偏好遇到无效值时回退到表盘', () async {
    SharedPreferences.setMockInitialValues({
      InstallPreferenceStore.key: 'unsupported',
    });

    expect(await InstallPreferenceStore().read(), InstallKind.watchface);
  });
}
