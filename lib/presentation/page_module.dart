import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../application/device_controller.dart';
import '../domain/install_models.dart';
import '../domain/install_preference_store.dart';

/// Shared dependencies provided to every primary navigation page.
///
/// Page modules only declare presentation metadata and a builder. The shell
/// retains ownership of application lifecycle, connection recovery and state.
class WristloadPageContext {
  const WristloadPageContext({
    required this.controller,
    required this.preferredInstallTarget,
    required this.onPreferredInstallTargetChanged,
    required this.floatingInstallWindowEnabled,
    required this.onFloatingInstallWindowEnabledChanged,
    required this.autoOpenDiagnosticLog,
    required this.onAutoOpenDiagnosticLogChanged,
    required this.diagnosticLogWindowOpen,
    required this.onDiagnosticLogWindowChanged,
    required this.themeSeedColor,
    required this.onThemeSeedChanged,
    required this.onReplayOobe,
    required this.onEditAuthKey,
  });

  final DeviceController controller;
  final InstallPreference preferredInstallTarget;
  final ValueChanged<InstallPreference> onPreferredInstallTargetChanged;
  final bool floatingInstallWindowEnabled;
  final ValueChanged<bool>? onFloatingInstallWindowEnabledChanged;
  final bool autoOpenDiagnosticLog;
  final ValueChanged<bool>? onAutoOpenDiagnosticLogChanged;
  final bool diagnosticLogWindowOpen;
  final ValueChanged<bool>? onDiagnosticLogWindowChanged;
  final Color themeSeedColor;
  final ValueChanged<Color> onThemeSeedChanged;
  final VoidCallback onReplayOobe;
  final VoidCallback onEditAuthKey;
}

typedef WristloadPageBuilder = Widget Function(WristloadPageContext context);

/// Self-registration metadata for a primary page.
///
/// The registry is generated from files that declare one of these values. A
/// page file can therefore be added or removed without editing the app shell.
class WristloadPageModule {
  const WristloadPageModule({
    required this.id,
    required this.route,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.order,
    required this.build,
    this.supportedPlatforms = const <TargetPlatform>{},
  });

  final String id;
  final String route;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final int order;
  final WristloadPageBuilder build;

  /// An empty set preserves the existing all-platform behavior. A page can
  /// opt into a specific desktop platform without adding page-specific
  /// navigation conditions to the application shell.
  final Set<TargetPlatform> supportedPlatforms;

  bool get isAvailableOnCurrentPlatform =>
      supportedPlatforms.isEmpty ||
      supportedPlatforms.contains(defaultTargetPlatform);
}
