import 'package:shared_preferences/shared_preferences.dart';

import 'install_task.dart';

enum InstallPreference { watchface, quickApp, both }

class InstallPreferenceStore {
  static const key = 'preferred_install_target';

  Future<InstallKind> read() async {
    return switch (await readPreference()) {
      InstallPreference.quickApp => InstallKind.quickApp,
      _ => InstallKind.watchface,
    };
  }

  Future<InstallPreference> readPreference() async {
    final preferences = await SharedPreferences.getInstance();
    return switch (preferences.getString(key)) {
      'quickapp' => InstallPreference.quickApp,
      'both' => InstallPreference.both,
      _ => InstallPreference.watchface,
    };
  }

  Future<void> write(InstallKind target) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      key,
      target == InstallKind.watchface ? 'watchface' : 'quickapp',
    );
  }

  Future<void> writePreference(InstallPreference target) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
        key,
        switch (target) {
          InstallPreference.watchface => 'watchface',
          InstallPreference.quickApp => 'quickapp',
          InstallPreference.both => 'both',
        });
  }
}
