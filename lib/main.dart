import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:window_manager/window_manager.dart';

import 'application/device_controller.dart';
import 'application/diagnostic_log_service.dart';
import 'application/diagnostic_log_window_coordinator.dart';
import 'application/floating_window_coordinator.dart';
import 'application/theme_controller.dart';
import 'domain/auth_key_binding.dart';
import 'domain/connection_issue.dart';
import 'domain/diagnostic_log_preferences.dart';
import 'domain/firmware_package_inspector.dart';
import 'domain/install_models.dart';
import 'domain/install_preference_store.dart';
import 'domain/install_task.dart';
import 'domain/oobe_store.dart';
import 'domain/queue_file_importer.dart';
import 'presentation/device_info_page.dart';
import 'presentation/apps_page.dart';
import 'presentation/debug_page.dart';
import 'presentation/diagnostic_log_window_app.dart';
import 'presentation/connection_warning_dialog.dart';
import 'presentation/firmware_inspection_dialog.dart';
import 'presentation/floating_install_window_app.dart';
import 'presentation/home_widgets.dart';
import 'presentation/install_split_button.dart';
import 'presentation/install_task_card.dart';
import 'presentation/install_warning_dialog.dart';
import 'presentation/install_request_preflight.dart';
import 'presentation/oobe_page.dart';
import 'presentation/queue_page.dart';
import 'presentation/settings_page.dart';
import 'presentation/tools_page.dart';
import 'platform/scoped_file_picker.dart';
import 'platform/security_scoped_file_access.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  _installGlobalErrorHandlers();
  await appLogger.initializePersistence();
  if (Platform.isWindows || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    final currentWindow = await WindowController.fromCurrentEngine();
    if (currentWindow.arguments == diagnosticLogWindowArgument) {
      appLogger.info(
        '诊断日志窗口引擎启动',
        category: DiagnosticLogCategory.runtime,
        fields: <String, Object?>{'platform': Platform.operatingSystem},
      );
      runApp(const DiagnosticLogWindowApp());
      return;
    }
    if (Platform.isWindows) {
      await windowManager.setPreventClose(true);
    }
    if (Platform.isWindows &&
        currentWindow.arguments == floatingInstallWindowArgument) {
      appLogger.info(
        '浮动安装窗口引擎启动',
        category: DiagnosticLogCategory.runtime,
        fields: <String, Object?>{'platform': Platform.operatingSystem},
      );
      runApp(const FloatingInstallWindowApp());
      return;
    }
  }
  appLogger.info(
    '应用启动',
    category: DiagnosticLogCategory.runtime,
    fields: <String, Object?>{
      'platform': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dartVersion': Platform.version.split(' ').first,
      'flutterMode': kReleaseMode
          ? 'release'
          : (kProfileMode ? 'profile' : 'debug'),
      'locale': Platform.localeName,
      'argumentsCount': args.length,
    },
  );
  final startupValues = await Future.wait([
    OobeStore().readCompleted(),
    InstallPreferenceStore().readPreference(),
    ThemeController.create(),
    DiagnosticLogPreferences().readAutoOpen(),
  ]);
  final initialThemeController = startupValues[2] as ThemeController;
  final initialThemeSeedColor = initialThemeController.seedColor;
  initialThemeController.dispose();
  appLogger.debug(
    '应用启动配置加载完成',
    category: DiagnosticLogCategory.runtime,
    fields: <String, Object?>{
      'oobeCompleted': startupValues[0] as bool,
      'installPreference': (startupValues[1] as InstallPreference).name,
    },
  );
  runApp(
    WristloadApp(
      desktopIntegrationEnabled: Platform.isWindows,
      initialOobeCompleted: startupValues[0] as bool,
      initialPreference: startupValues[1] as InstallPreference,
      initialThemeSeedColor: initialThemeSeedColor,
      initialAutoOpenDiagnosticLog: startupValues[3] as bool,
    ),
  );
}

void _installGlobalErrorHandlers() {
  FlutterError.onError = (details) {
    appLogger.error(
      'Flutter 未处理异常',
      category: DiagnosticLogCategory.runtime,
      fields: <String, Object?>{
        'errorType': details.exception.runtimeType.toString(),
        'exception': details.exceptionAsString(),
        'stackTrace': details.stack?.toString(),
      },
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    appLogger.fatal(
      '平台未处理异常',
      category: DiagnosticLogCategory.runtime,
      fields: <String, Object?>{
        'errorType': error.runtimeType.toString(),
        'exception': error.toString(),
        'stackTrace': stackTrace.toString(),
      },
    );
    return true;
  };
}

class WristloadApp extends StatefulWidget {
  const WristloadApp({
    this.desktopIntegrationEnabled = false,
    this.initialOobeCompleted = false,
    this.initialPreference = InstallPreference.watchface,
    this.initialThemeSeedColor = ThemeController.defaultSeedColor,
    this.initialAutoOpenDiagnosticLog = false,
    super.key,
  });

  final bool desktopIntegrationEnabled;
  final bool initialOobeCompleted;
  final InstallPreference initialPreference;
  final Color initialThemeSeedColor;
  final bool initialAutoOpenDiagnosticLog;

  @override
  State<WristloadApp> createState() => _WristloadAppState();
}

class _WristloadAppState extends State<WristloadApp> {
  final controller = DeviceController(logger: appLogger);
  final _appShellKey = GlobalKey<_AppShellState>();
  final _installRequestPreflight = const InstallRequestPreflight();
  final _installPreferenceStore = InstallPreferenceStore();
  final _oobeStore = OobeStore();
  final _diagnosticLogPreferences = DiagnosticLogPreferences();
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final FloatingWindowCoordinator _floatingWindowCoordinator;
  late final DiagnosticLogWindowCoordinator _diagnosticLogWindowCoordinator;
  bool _floatingInstallWindowEnabled = false;
  bool _diagnosticLogWindowOpen = false;
  late bool _autoOpenDiagnosticLog;
  late bool _oobeCompleted;
  late InstallPreference _preferredInstallTarget;
  late final ThemeController _themeController;
  Future<void> _preferenceWrites = Future.value();
  bool _floatingInitialized = false;

  @override
  void initState() {
    super.initState();
    _oobeCompleted = widget.initialOobeCompleted;
    _preferredInstallTarget = widget.initialPreference;
    _autoOpenDiagnosticLog = widget.initialAutoOpenDiagnosticLog;
    _themeController = ThemeController(widget.initialThemeSeedColor);
    _diagnosticLogWindowCoordinator = DiagnosticLogWindowCoordinator(
      logger: appLogger,
      onClear: controller.clearLogs,
      onClosed: _handleDiagnosticWindowClosed,
      themeSeedProvider: () => _themeController.seedColor,
    );
    controller.queueInstallPreparer = _prepareQueuedRequest;
    _floatingWindowCoordinator = FloatingWindowCoordinator(
      controller: controller,
      onOpenMainWindow: () => _appShellKey.currentState?.showHome(),
      themeSeedProvider: () => _themeController.seedColor,
    );
    if (widget.desktopIntegrationEnabled && _oobeCompleted) {
      unawaited(_initializeFloatingWindow());
    }
    if ((Platform.isWindows || Platform.isMacOS) && _autoOpenDiagnosticLog) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_setDiagnosticLogWindowOpen(true));
      });
    }
  }

  void _setOobePreference(InstallPreference preference) {
    if (_preferredInstallTarget == preference) return;
    setState(() => _preferredInstallTarget = preference);
    _preferenceWrites = _preferenceWrites.then(
      (_) => _installPreferenceStore.writePreference(preference),
    );
  }

  Future<void> _completeOobe() async {
    await _preferenceWrites;
    await _installPreferenceStore.writePreference(_preferredInstallTarget);
    await _oobeStore.markCompleted();
    if (!mounted) return;
    setState(() => _oobeCompleted = true);
    _navigatorKey.currentState?.pushNamedAndRemoveUntil('/', (_) => false);
    if (widget.desktopIntegrationEnabled) {
      unawaited(_initializeFloatingWindow());
    }
  }

  Future<void> _replayOobe() async {
    await _oobeStore.markNotCompleted();
    if (!mounted) return;
    setState(() => _oobeCompleted = false);
    _navigatorKey.currentState?.pushNamedAndRemoveUntil('/oobe', (_) => false);
  }

  Widget _buildOobePage() => OobePage(
    installPreference: _preferredInstallTarget,
    onInstallPreferenceChanged: _setOobePreference,
    onCompleted: _completeOobe,
  );

  Widget _buildAppShell() => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => AppShell(
      key: _appShellKey,
      controller: controller,
      preferredInstallTarget: _preferredInstallTarget,
      onPreferredInstallTargetChanged: _setOobePreference,
      onReplayOobe: _replayOobe,
      floatingInstallWindowEnabled: _floatingInstallWindowEnabled,
      themeSeedColor: _themeController.seedColor,
      onThemeSeedChanged: (color) {
        unawaited(_themeController.setSeed(color));
        unawaited(_floatingWindowCoordinator.updateTheme());
        unawaited(_diagnosticLogWindowCoordinator.updateTheme());
      },
      onFloatingInstallWindowEnabledChanged: widget.desktopIntegrationEnabled
          ? (enabled) {
              unawaited(_setFloatingInstallWindowEnabled(enabled));
            }
          : null,
      diagnosticLogWindowOpen: _diagnosticLogWindowOpen,
      autoOpenDiagnosticLog: _autoOpenDiagnosticLog,
      onDiagnosticLogWindowChanged: (Platform.isWindows || Platform.isMacOS)
          ? _setDiagnosticLogWindowOpen
          : null,
      onAutoOpenDiagnosticLogChanged: (Platform.isWindows || Platform.isMacOS)
          ? _setAutoOpenDiagnosticLog
          : null,
    ),
  );

  Future<void> _setDiagnosticLogWindowOpen(bool open) async {
    try {
      if (open) {
        await _diagnosticLogWindowCoordinator.show();
      } else {
        await _diagnosticLogWindowCoordinator.hide();
      }
      if (!mounted) return;
      if (mounted) setState(() => _diagnosticLogWindowOpen = open);
      appLogger.info(
        open ? '诊断日志窗口已打开' : '诊断日志窗口已隐藏',
        category: DiagnosticLogCategory.ui,
      );
    } on Object catch (error, stackTrace) {
      appLogger.error(
        '诊断日志窗口操作失败',
        category: DiagnosticLogCategory.ui,
        fields: <String, Object?>{
          'operation': open ? 'show' : 'hide',
          'errorType': error.runtimeType.toString(),
          'exception': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
      if (mounted) setState(() => _diagnosticLogWindowOpen = false);
    }
  }

  Future<void> _setAutoOpenDiagnosticLog(bool enabled) async {
    try {
      await _diagnosticLogPreferences.writeAutoOpen(enabled);
      if (!mounted) return;
      setState(() => _autoOpenDiagnosticLog = enabled);
      appLogger.info(
        enabled ? '已启用启动时自动打开诊断日志' : '已关闭启动时自动打开诊断日志',
        category: DiagnosticLogCategory.ui,
      );
    } on Object catch (error, stackTrace) {
      appLogger.error(
        '启动日志偏好保存失败',
        category: DiagnosticLogCategory.ui,
        fields: <String, Object?>{
          'enabled': enabled,
          'errorType': error.runtimeType.toString(),
          'exception': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
    }
  }

  void _handleDiagnosticWindowClosed() {
    if (!mounted || !_diagnosticLogWindowOpen) return;
    setState(() => _diagnosticLogWindowOpen = false);
    appLogger.info('诊断日志窗口已关闭', category: DiagnosticLogCategory.ui);
  }

  Future<InstallRequest?> _prepareQueuedRequest(InstallRequest request) async {
    var context = _appShellKey.currentContext;
    if (context == null || !context.mounted) return null;
    if (widget.desktopIntegrationEnabled &&
        _installRequestPreflight.requiresInteraction(controller, request)) {
      await _floatingWindowCoordinator.showMainWindow();
      context = _appShellKey.currentContext;
      if (context == null || !context.mounted) return null;
    }
    return _installRequestPreflight.prepare(context, controller, request);
  }

  Future<void> _initializeFloatingWindow() async {
    if (_floatingInitialized) return;
    _floatingInitialized = true;
    try {
      await _floatingWindowCoordinator.initialize();
      if (!mounted) return;
      setState(() {
        _floatingInstallWindowEnabled = _floatingWindowCoordinator.enabled;
      });
    } on Object catch (error, stackTrace) {
      _floatingInitialized = false;
      appLogger.error(
        'Floating window initialization failed: $error',
        category: DiagnosticLogCategory.ui,
        fields: <String, Object?>{
          'errorType': error.runtimeType.toString(),
          'exception': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
    }
  }

  Future<void> _setFloatingInstallWindowEnabled(bool enabled) async {
    try {
      await _floatingWindowCoordinator.setEnabled(enabled);
      if (!mounted) return;
      setState(() {
        _floatingInstallWindowEnabled = _floatingWindowCoordinator.enabled;
      });
    } on Object catch (error, stackTrace) {
      appLogger.error(
        'Floating window setting failed: $error',
        category: DiagnosticLogCategory.ui,
        fields: <String, Object?>{
          'errorType': error.runtimeType.toString(),
          'exception': error.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
    }
  }

  @override
  void dispose() {
    controller.queueInstallPreparer = null;
    unawaited(_floatingWindowCoordinator.dispose());
    unawaited(_diagnosticLogWindowCoordinator.dispose());
    controller.dispose();
    _themeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _themeController,
    builder: (context, _) => MaterialApp(
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _themeController.seedColor,
          brightness: Brightness.light,
        ),
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _themeController.seedColor,
          brightness: Brightness.dark,
        ),
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      initialRoute: _oobeCompleted ? '/' : '/oobe',
      onGenerateInitialRoutes: (initialRouteName) => [
        MaterialPageRoute<void>(
          settings: RouteSettings(name: initialRouteName),
          builder: (_) =>
              initialRouteName == '/oobe' ? _buildOobePage() : _buildAppShell(),
        ),
      ],
      routes: {
        '/': (context) => _buildAppShell(),
        '/oobe': (context) => _buildOobePage(),
        '/apps': (context) => AppsPage(controller: controller),
        '/queue': (context) => QueuePage(controller: controller),
        '/tools': (context) => ToolsPage(controller: controller),
        '/debug': (context) => DebugPage(controller: controller),
      },
    ),
  );
}

class AppShell extends StatefulWidget {
  const AppShell({
    required this.controller,
    required this.preferredInstallTarget,
    required this.onPreferredInstallTargetChanged,
    required this.onReplayOobe,
    required this.floatingInstallWindowEnabled,
    required this.onFloatingInstallWindowEnabledChanged,
    required this.themeSeedColor,
    required this.onThemeSeedChanged,
    this.diagnosticLogWindowOpen = false,
    this.autoOpenDiagnosticLog = false,
    this.onDiagnosticLogWindowChanged,
    this.onAutoOpenDiagnosticLogChanged,
    super.key,
  });

  final DeviceController controller;
  final InstallPreference preferredInstallTarget;
  final ValueChanged<InstallPreference> onPreferredInstallTargetChanged;
  final Future<void> Function() onReplayOobe;
  final bool floatingInstallWindowEnabled;
  final Color themeSeedColor;
  final ValueChanged<Color> onThemeSeedChanged;
  final ValueChanged<bool>? onFloatingInstallWindowEnabledChanged;
  final bool diagnosticLogWindowOpen;
  final bool autoOpenDiagnosticLog;
  final ValueChanged<bool>? onDiagnosticLogWindowChanged;
  final ValueChanged<bool>? onAutoOpenDiagnosticLogChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  int? _scheduledConnectionIssueId;
  int? _visibleConnectionIssueId;
  bool _initialScanScheduled = false;
  bool _pairingScanScheduled = false;
  late bool _wasConnectionActive;

  bool get _connectionActive =>
      widget.controller.isConnected || widget.controller.isConnectionBusy;

  @override
  void initState() {
    super.initState();
    _wasConnectionActive = _connectionActive;
    widget.controller.addListener(_handleControllerChanged);
    _handleControllerChanged();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _initialScanScheduled) return;
      _initialScanScheduled = true;
      if (_selectedIndex != 0 ||
          widget.controller.isConnected ||
          widget.controller.isConnectionBusy) {
        return;
      }
      final autoConnectStarted = await widget.controller
          .autoConnectLastDevice();
      if (!mounted ||
          autoConnectStarted ||
          widget.controller.isConnected ||
          widget.controller.isConnectionBusy ||
          widget.controller.isScanning ||
          !widget.controller.canScan) {
        return;
      }
      await widget.controller.beginStartupScan();
    });
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChanged);
    _wasConnectionActive = _connectionActive;
    widget.controller.addListener(_handleControllerChanged);
    _scheduledConnectionIssueId = null;
    _visibleConnectionIssueId = null;
    _handleControllerChanged();
  }

  void _handleControllerChanged() {
    _handleConnectionIssue();
    final active = _connectionActive;
    // V2 devices can briefly replace their first RFCOMM socket immediately
    // after f=27.  A connection is only over once it has left the verified,
    // connecting, and native-teardown states, not merely when sessionReady
    // changes for that transport transition.
    if (_wasConnectionActive && !active) {
      _wasConnectionActive = false;
      showHome();
      // Failed classic pairing and RFCOMM setup must remain visible for
      // diagnosis. Only an explicit user disconnect requests scan recovery.
      if (widget.controller.shouldResumeScanningAfterConnectionEnd) {
        _schedulePairingScan();
      }
      return;
    }
    _wasConnectionActive = active;
  }

  void _schedulePairingScan() {
    if (_pairingScanScheduled) return;
    _pairingScanScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _pairingScanScheduled = false;
      if (!mounted ||
          widget.controller.isConnected ||
          widget.controller.isConnectionBusy ||
          widget.controller.isScanning ||
          !widget.controller.shouldResumeScanningAfterConnectionEnd ||
          !widget.controller.canScan) {
        return;
      }
      await widget.controller.beginScan();
    });
  }

  void _handleConnectionIssue() {
    final issue = widget.controller.pendingConnectionIssue;
    if (!mounted ||
        issue == null ||
        issue.id == _scheduledConnectionIssueId ||
        issue.id == _visibleConnectionIssueId) {
      return;
    }
    _scheduledConnectionIssueId = issue.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_showPendingConnectionIssue(issue.id));
    });
  }

  Future<void> _showPendingConnectionIssue(int issueId) async {
    if (_visibleConnectionIssueId != null) return;
    final issue = widget.controller.pendingConnectionIssue;
    if (issue == null || issue.id != issueId) {
      if (_scheduledConnectionIssueId == issueId) {
        _scheduledConnectionIssueId = null;
      }
      _handleConnectionIssue();
      return;
    }
    _scheduledConnectionIssueId = null;
    _visibleConnectionIssueId = issueId;
    try {
      if (issue.kind == ConnectionIssueKind.authKeyMismatch) {
        await _editAuthKey(
          showHistory: false,
          deviceId: issue.targetId,
          deviceName: issue.targetName,
        );
        return;
      }
      await showConnectionIssueWarning(
        context: context,
        issue: issue,
        onReconnect: widget.controller.reconnect,
        onChangeAuthKey: () => _editAuthKey(showHistory: false),
      );
    } finally {
      widget.controller.dismissConnectionIssue(issueId);
      _visibleConnectionIssueId = null;
      _handleConnectionIssue();
    }
  }

  void showHome() {
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
    }
    if (_selectedIndex != 0) {
      setState(() => _selectedIndex = 0);
    }
  }

  Future<void> _editAuthKey({
    bool showHistory = true,
    String? deviceId,
    String? deviceName,
  }) async {
    if (!mounted) return;
    final controller = widget.controller;
    AuthKeyBinding? selectedBinding;
    if (showHistory) {
      try {
        await controller.authKeyBindingsReady.timeout(
          const Duration(milliseconds: 800),
        );
      } on Object {
        // Opening the editor must not be blocked by a slow preference read.
      }
      if (!mounted) return;
    }
    if (showHistory && controller.authKeyBindings.isNotEmpty) {
      selectedBinding = await showDialog<AuthKeyBinding>(
        context: context,
        builder: (_) => _AuthKeyBindingPicker(
          bindings: controller.authKeyBindings,
          onDelete: (binding) => controller.deleteSavedDeviceById(binding.id),
          onConnect: controller.connectSavedDevice,
        ),
      );
      if (selectedBinding == null) return;
    }
    final selectedId =
        selectedBinding?.id ??
        deviceId ??
        controller.connectedDevice?.uuid.toString();
    if (!mounted) return;
    String? selectedName = selectedBinding?.name ?? deviceName;
    if (selectedName == null) {
      for (final binding in controller.authKeyBindings) {
        if (binding.id == selectedId) {
          selectedName = binding.name;
          break;
        }
      }
    }
    final selectedActiveDevice = controller.connectedDevice?.uuid.toString();
    final editsActiveDevice =
        selectedId != null &&
        selectedActiveDevice != null &&
        selectedActiveDevice.toLowerCase() == selectedId.toLowerCase();
    final initial = !showHistory || selectedId == null || editsActiveDevice
        ? controller.authKey
        : await _readAuthKeyForEditor(controller, selectedId);
    if (!mounted) return;
    final value = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _AuthKeyEditDialog(deviceName: selectedName, initialValue: initial),
    );
    if (value == null) return;
    // Editing a historical binding must never replace the live device's
    // in-memory key or trigger a reconnect of that other device. It is only
    // an explicit update to the selected device's saved credential.
    if (selectedBinding != null && !editsActiveDevice) {
      final name = selectedName ?? '已保存设备';
      await controller.rememberAuthKeyBinding(
        id: selectedBinding.id,
        name: name,
        key: value,
      );
      return;
    }
    if (!await controller.setAuthKey(value, deviceId: selectedId)) return;
    // An edit for the current authenticated device is an explicit persistence
    // action. First-time connection input is persisted only after f=27.
    if (selectedBinding != null) {
      await controller.rememberAuthKeyBinding(
        id: selectedBinding.id,
        name: selectedName ?? '已保存设备',
        key: value,
      );
    }
    if (editsActiveDevice && controller.isConnected) {
      await controller.reconnect();
    }
  }

  Future<String?> _readAuthKeyForEditor(
    DeviceController controller,
    String id,
  ) async {
    try {
      return await controller
          .readAuthKeyFor(id)
          .timeout(const Duration(milliseconds: 600));
    } on Object {
      // Opening the editor must not depend on a platform secure-store call.
      return controller.authKey;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: _GlobalConnectionStatus(controller: widget.controller),
    ),
    body: SafeArea(
      child: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (index) =>
                setState(() => _selectedIndex = index),
            destinations: [
              const NavigationRailDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: Text('主页'),
              ),
              NavigationRailDestination(
                icon: Badge.count(
                  count: widget.controller.pendingCount,
                  isLabelVisible: widget.controller.pendingCount > 0,
                  child: const Icon(Icons.queue_outlined),
                ),
                selectedIcon: Badge.count(
                  count: widget.controller.pendingCount,
                  isLabelVisible: widget.controller.pendingCount > 0,
                  child: const Icon(Icons.queue),
                ),
                label: const Text('队列'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.apps_outlined),
                selectedIcon: Icon(Icons.apps),
                label: Text('快应用'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.build_outlined),
                selectedIcon: Icon(Icons.build),
                label: Text('工具'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.bug_report_outlined),
                selectedIcon: Icon(Icons.bug_report),
                label: Text('调试'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('设置'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: switch (_selectedIndex) {
              0 => HomePage(
                controller: widget.controller,
                preferredInstallTarget: widget.preferredInstallTarget,
                onPreferredInstallTargetChanged:
                    widget.onPreferredInstallTargetChanged,
                diagnosticLogWindowOpen: widget.diagnosticLogWindowOpen,
                onDiagnosticLogWindowChanged:
                    widget.onDiagnosticLogWindowChanged,
              ),
              1 => QueuePage(controller: widget.controller),
              2 => AppsPage(controller: widget.controller),
              3 => ToolsPage(controller: widget.controller),
              4 => DebugPage(controller: widget.controller),
              _ => TransferSettingsPage(
                preferredInstallTarget: widget.preferredInstallTarget,
                connectionMode: widget.controller.connectionMode,
                connectionModeEnabled:
                    !widget.controller.isConnected &&
                    !widget.controller.isConnectionBusy,
                segmentIntervalMs: widget.controller.segmentIntervalMs,
                massWindowSize: widget.controller.massWindowSize,
                autoTimeSync: widget.controller.autoTimeSync,
                autoConnectLastDevice:
                    widget.controller.autoConnectLastDeviceEnabled,
                floatingInstallWindowEnabled:
                    widget.floatingInstallWindowEnabled,
                autoOpenDiagnosticLog: widget.autoOpenDiagnosticLog,
                themeSeedColor: widget.themeSeedColor,
                onThemeSeedChanged: widget.onThemeSeedChanged,
                onConnectionModeChanged: widget.controller.setConnectionMode,
                onSegmentIntervalChanged:
                    widget.controller.setSegmentIntervalMs,
                onMassWindowSizeChanged: widget.controller.setMassWindowSize,
                onAutoTimeSyncChanged: widget.controller.setAutoTimeSync,
                onAutoConnectLastDeviceChanged:
                    widget.controller.setAutoConnectLastDeviceEnabled,
                onFloatingInstallWindowEnabledChanged:
                    widget.onFloatingInstallWindowEnabledChanged,
                onAutoOpenDiagnosticLogChanged:
                    widget.onAutoOpenDiagnosticLogChanged,
                onPreferredInstallTargetChanged:
                    widget.onPreferredInstallTargetChanged,
                onReplayOobe: widget.onReplayOobe,
                onEditAuthKey: _editAuthKey,
              ),
            },
          ),
        ],
      ),
    ),
  );
}

class _AuthKeyBindingPicker extends StatefulWidget {
  const _AuthKeyBindingPicker({
    required this.bindings,
    this.onDelete,
    this.onConnect,
  });

  final List<AuthKeyBinding> bindings;
  final Future<bool> Function(AuthKeyBinding binding)? onDelete;
  final Future<bool> Function(AuthKeyBinding binding)? onConnect;

  @override
  State<_AuthKeyBindingPicker> createState() => _AuthKeyBindingPickerState();
}

class _AuthKeyBindingPickerState extends State<_AuthKeyBindingPicker> {
  AuthKeyBinding? _selected;
  late List<AuthKeyBinding> _bindings;
  String? _deletingBindingId;
  String? _connectingBindingId;

  @override
  void initState() {
    super.initState();
    _bindings = List<AuthKeyBinding>.of(widget.bindings);
  }

  @override
  void didUpdateWidget(covariant _AuthKeyBindingPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bindings, widget.bindings)) {
      _bindings = List<AuthKeyBinding>.of(widget.bindings);
      if (_selected != null &&
          !_bindings.any((binding) => binding.id == _selected!.id)) {
        _selected = null;
      }
    }
  }

  Future<void> _deleteBinding(AuthKeyBinding binding) async {
    final onDelete = widget.onDelete;
    if (onDelete == null || _deletingBindingId != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除已保存设备？'),
        content: Text(
          '将删除' +
              binding.name +
              '在 Wristload 本机保存的 authkey、历史绑定和经典蓝牙身份映射。'
                  '不会删除系统蓝牙配对。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.delete_outline),
            label: const Text('删除设备'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deletingBindingId = binding.id);
    final deleted = await onDelete(binding);
    if (!mounted) return;
    setState(() {
      _deletingBindingId = null;
      if (deleted) {
        _bindings = _bindings
            .where((candidate) => candidate.id != binding.id)
            .toList(growable: false);
        if (_selected?.id == binding.id) _selected = null;
      }
    });
    if (!deleted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已保存设备未能完全删除，请查看诊断日志。')));
    }
  }

  Future<void> _connectBinding(AuthKeyBinding binding) async {
    final onConnect = widget.onConnect;
    if (onConnect == null ||
        _connectingBindingId != null ||
        _deletingBindingId != null) {
      return;
    }
    setState(() => _connectingBindingId = binding.id);
    final started = await onConnect(binding);
    if (!mounted) return;
    if (started) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _connectingBindingId = null);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法开始连接，请确认蓝牙可用且设备在附近。')));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('历史绑定设备'),
    content: SizedBox(
      width: 420,
      child: _bindings.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Text('没有已保存设备')),
            )
          : ListView(
              shrinkWrap: true,
              children: _bindings
                  .map(
                    (binding) => ListTile(
                      leading: Radio<AuthKeyBinding>(
                        value: binding,
                        groupValue: _selected,
                        onChanged: (value) => setState(() => _selected = value),
                      ),
                      title: Text(binding.name),
                      subtitle: Text(binding.uuid),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.onDelete != null)
                            IconButton(
                              key: ValueKey(
                                'delete-saved-binding-' + binding.id,
                              ),
                              tooltip: '删除已保存设备',
                              onPressed: _deletingBindingId == null
                                  ? () => _deleteBinding(binding)
                                  : null,
                              icon: _deletingBindingId == binding.id
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.delete_outline),
                            ),
                          const Icon(Icons.chevron_right),
                        ],
                      ),
                      selected: _selected?.id == binding.id,
                      onTap: () => setState(() => _selected = binding),
                    ),
                  )
                  .toList(growable: false),
            ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      if (widget.onConnect != null)
        OutlinedButton.icon(
          key: const ValueKey('connect-saved-binding'),
          onPressed:
              _selected == null ||
                  _deletingBindingId != null ||
                  _connectingBindingId != null
              ? null
              : () => _connectBinding(_selected!),
          icon: _connectingBindingId == null
              ? const Icon(Icons.link)
              : const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
          label: const Text('连接'),
        ),
      FilledButton(
        onPressed: _selected == null
            ? null
            : () => Navigator.of(context).pop(_selected),
        child: const Text('修改'),
      ),
    ],
  );
}

class _GlobalConnectionStatus extends StatelessWidget {
  const _GlobalConnectionStatus({required this.controller});

  final DeviceController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final connected = controller.isConnected;
    final connecting = !connected && controller.isConnecting;
    final disconnecting =
        !connected && !connecting && controller.isConnectionBusy;
    final deviceName =
        (controller.connectedDeviceName ??
                controller.connectedProfile?.displayName ??
                '')
            .trim();
    final label = connected
        ? (deviceName.isEmpty ? '已连接设备' : deviceName)
        : connecting
        ? '正在连接${deviceName.isEmpty ? '' : '：$deviceName'}'
        : disconnecting
        ? '正在断开设备'
        : '设备未连接';

    return Row(
      key: const ValueKey('global-connection-status'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Wristload'),
        const SizedBox(width: 16),
        Container(
          key: const ValueKey('global-connection-status-dot'),
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: connected
                ? colors.primary
                : (connecting || disconnecting
                      ? colors.tertiary
                      : colors.error),
          ),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: colors.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _AuthKeyEditDialog extends StatefulWidget {
  const _AuthKeyEditDialog({
    required this.deviceName,
    required this.initialValue,
  });

  final String? deviceName;
  final String? initialValue;

  @override
  State<_AuthKeyEditDialog> createState() => _AuthKeyEditDialogState();
}

class _AuthKeyEditDialogState extends State<_AuthKeyEditDialog> {
  late final TextEditingController _field;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _field = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _save() {
    if (_formKey.currentState?.validate() ?? false) {
      Navigator.of(context).pop(_field.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.deviceName == null
          ? '修改设备 authkey'
          : '修改 ${widget.deviceName} authkey',
    ),
    content: Form(
      key: _formKey,
      child: TextFormField(
        controller: _field,
        autofocus: true,
        selectAllOnFocus: false,
        keyboardType: TextInputType.visiblePassword,
        textInputAction: TextInputAction.done,
        maxLength: 32,
        autocorrect: false,
        enableSuggestions: false,
        onFieldSubmitted: (_) => _save(),
        decoration: const InputDecoration(
          labelText: 'authkey',
          hintText: '32 位十六进制',
          counterText: '',
          border: OutlineInputBorder(),
        ),
        validator: (text) =>
            RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(text?.trim() ?? '')
            ? null
            : '请输入 32 位十六进制字符',
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('保存')),
    ],
  );
}

/// Exposes the authkey editor to widget tests without making its state public.
Widget buildAuthKeyEditDialogForTesting({
  String? deviceName,
  String? initialValue,
}) {
  return _AuthKeyEditDialog(deviceName: deviceName, initialValue: initialValue);
}

Widget buildAuthKeyBindingPickerForTesting({
  required List<AuthKeyBinding> bindings,
  Future<bool> Function(AuthKeyBinding binding)? onDelete,
  Future<bool> Function(AuthKeyBinding binding)? onConnect,
}) => _AuthKeyBindingPicker(
  bindings: bindings,
  onDelete: onDelete,
  onConnect: onConnect,
);

Future<void> openVerifiedDeviceInfo(
  BuildContext context,
  DeviceController controller,
) {
  if (!context.mounted || !DeviceInfoPage.hasVerifiedSession(controller)) {
    return Future<void>.value();
  }
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/device-info'),
      builder: (_) => DeviceInfoPage(controller: controller),
    ),
  );
}

class HomePage extends StatelessWidget {
  const HomePage({
    required this.controller,
    required this.preferredInstallTarget,
    required this.onPreferredInstallTargetChanged,
    this.diagnosticLogWindowOpen = false,
    this.onDiagnosticLogWindowChanged,
    super.key,
  });

  final DeviceController controller;
  final InstallPreference preferredInstallTarget;
  final ValueChanged<InstallPreference> onPreferredInstallTargetChanged;
  final bool diagnosticLogWindowOpen;
  final ValueChanged<bool>? onDiagnosticLogWindowChanged;

  Future<void> _pickFirmware(BuildContext context) async {
    final selected = await ScopedFilePicker.pickFiles(
      allowedExtensions: const ['zip', 'bin'],
    );
    final file = selected?.single;
    final path = file?.path;
    if (path == null || !context.mounted) return;

    try {
      final inspection = await SecurityScopedFileAccess.instance.withAccess(
        file!,
        (resolved) => const FirmwarePackageInspector().inspect(resolved.path),
      );
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => FirmwareInspectionDialog(inspection: inspection),
      );
    } on FormatException catch (error) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => FirmwareInspectionErrorDialog(
          fileName: path.split(RegExp(r'[/\\]')).last,
          message: error.message.toString(),
        ),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => FirmwareInspectionErrorDialog(
          fileName: path.split(RegExp(r'[/\\]')).last,
          message: '读取固件包时发生错误：$error',
        ),
      );
    }
  }

  Future<void> _pickAndTry(BuildContext context, InstallKind kind) async {
    final extensions = kind == InstallKind.watchface
        ? const ['bin', 'face']
        : const ['rpk'];
    final selected = await ScopedFilePicker.pickFiles(
      allowedExtensions: extensions,
    );
    final source = selected?.single;
    if (source == null) return;
    try {
      final importedRequest = await QueueFileImporter().prepareSingle(
        source,
        expectedKind: kind,
      );
      var metadata = importedRequest.metadata;
      var unsupportedLuaConfirmed = false;
      var watchfaceResolutionConfirmed = false;
      if (!context.mounted) return;
      if (kind == InstallKind.watchface) {
        final compatibilityError = controller.watchfaceCompatibilityError(
          metadata,
        );
        if (compatibilityError != null) {
          watchfaceResolutionConfirmed = await _confirmWatchfaceResolution(
            context,
            metadata,
          );
          if (!watchfaceResolutionConfirmed) return;
          if (!context.mounted) return;
        }
        if (controller.requiresUnsupportedLuaConfirmation(metadata)) {
          unsupportedLuaConfirmed = await _confirmUnsupportedLuaWatchface(
            context,
            metadata,
          );
          if (!unsupportedLuaConfirmed) return;
        }
        if (!context.mounted) return;
        final edited = await _editFaceId(context, metadata);
        if (edited == null) return;
        metadata = edited;
      } else if (metadata.versionCode == null) {
        if (!context.mounted) return;
        final edited = await _editRpkVersion(context, metadata);
        if (edited == null) return;
        metadata = edited;
      }
      if (kind == InstallKind.watchface &&
          !RegExp(r'^\d+$').hasMatch(metadata.faceId ?? '')) {
        throw const FormatException('faceId 必须为数值型 ID');
      }
      if (kind == InstallKind.quickApp &&
          (metadata.versionCode == null ||
              metadata.versionCode! <= 0 ||
              metadata.versionCode! > maxRpkVersionCode)) {
        throw const FormatException('RPK 清单未提供版本号，请填写有效 32 位正整数版本号');
      }
      controller.enqueue(
        importedRequest.copyWith(
          metadata: metadata,
          unsupportedLuaConfirmed: unsupportedLuaConfirmed,
          watchfaceResolutionConfirmed: watchfaceResolutionConfirmed,
        ),
      );
      await controller.runQueue();
    } on Object catch (error) {
      controller.reportError('无法创建安装计划：$error');
    }
  }

  Future<bool> _confirmWatchfaceResolution(
    BuildContext context,
    InstallMetadata metadata,
  ) async {
    var confirmed = false;
    final profile = controller.connectedProfile;
    final resolutions = metadata.watchfaceResolutions.isEmpty
        ? '未识别'
        : metadata.watchfaceResolutions.join('、');
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InstallWarningDialog(
        title: '表盘分辨率不匹配',
        message: '安装后可能无法正常显示或使用',
        rows: [
          ('表盘分辨率', resolutions, false),
          ('设备分辨率', profile?.watchfaceResolution?.toString() ?? '未知', true),
          ('文件名', metadata.fileName, false),
        ],
        onConfirm: () => confirmed = true,
      ),
    );
    return confirmed;
  }

  Future<bool> _confirmUnsupportedLuaWatchface(
    BuildContext context,
    InstallMetadata metadata,
  ) async {
    var confirmed = false;
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InstallWarningDialog(
        title: 'Lua 不被支持',
        message: '安装后可能无法正常显示或使用',
        rows: [
          ('文件名', metadata.fileName, false),
          ('检测结果', '检测到lua文件', true),
          ('目标设备', controller.connectedProfile?.displayName ?? '未知设备', false),
        ],
        onConfirm: () => confirmed = true,
      ),
    );
    return confirmed;
  }

  Future<InstallMetadata?> _editFaceId(
    BuildContext context,
    InstallMetadata metadata,
  ) async {
    // TextFormField owns its internal controller for the whole dialog route.
    // Keeping a controller in this caller and disposing it after showDialog
    // returns races the route's reverse animation on macOS.
    var faceId = metadata.faceId ?? '';
    final formKey = GlobalKey<FormState>();
    return showDialog<InstallMetadata>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('表盘 faceId'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: faceId,
            onChanged: (value) => faceId = value,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '从表盘资源解析，可按需编辑',
              border: OutlineInputBorder(),
            ),
            validator: (value) => RegExp(r'^\d+$').hasMatch(value ?? '')
                ? null
                : 'faceId 必须是非空数值',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(faceId: faceId.trim()),
              );
            },
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  Future<InstallMetadata?> _editRpkVersion(
    BuildContext context,
    InstallMetadata metadata,
  ) async {
    var versionText = '';
    final formKey = GlobalKey<FormState>();
    return showDialog<InstallMetadata>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('RPK 版本号'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: versionText,
            onChanged: (value) => versionText = value,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: '包名：${metadata.packageName}',
              helperText: '包名必须来自 RPK 清单，不能手动修改。',
              border: const OutlineInputBorder(),
            ),
            validator: (value) {
              final version = int.tryParse(value?.trim() ?? '');
              if (version == null ||
                  version <= 0 ||
                  version > maxRpkVersionCode) {
                return '请输入 1–$maxRpkVersionCode';
              }
              return null;
            },
            onFieldSubmitted: (value) {
              versionText = value;
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(versionCode: int.parse(versionText.trim())),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(versionCode: int.parse(versionText.trim())),
              );
            },
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  /// authkey 是正式会话身份校验的必填输入。
  Future<void> _connectWithAuthKey(
    BuildContext context,
    DiscoveredEventArgs result,
  ) async {
    final deviceId = result.peripheral.uuid.toString();
    // 只读取本设备经认证后保存的 authkey；绝不能把另一台设备的凭据
    // 当作通用回退值。没有本设备记录时才请求用户输入。
    if (await controller.useSavedAuthKeyForDevice(deviceId)) {
      if (!context.mounted) return;
      await controller.connect(result);
      return;
    }
    if (!context.mounted) return;
    var authKey = '';
    final formKey = GlobalKey<FormState>();
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('输入 authkey'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: authKey,
            onChanged: (value) => authKey = value,
            autofocus: true,
            maxLength: 32,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: '32 位十六进制（绑定 token，16 字节）',
              counterText: '',
              border: OutlineInputBorder(),
            ),
            validator: (value) {
              final v = value?.trim() ?? '';
              if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(v)) {
                return '请输入 32 位十六进制字符';
              }
              return null;
            },
            onFieldSubmitted: (value) {
              authKey = value;
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, authKey.trim());
              }
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, authKey.trim());
              }
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
    if (input != null &&
        await controller.setAuthKey(input, deviceId: deviceId)) {
      // The controller persists the device-specific binding only after f=27
      // confirms the authkey. A cancelled macOS pairing or failed RFCOMM
      // handshake must not create an apparent "saved device".
      await controller.connect(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    // A selected peripheral is only a transport candidate until the
    // controller confirms an authenticated session. In particular, macOS
    // pairing cancellation can briefly leave a candidate behind. Do not let
    // that candidate unlock device actions in the UI.
    final connected = controller.isConnected;
    final canOpenDeviceInfo = DeviceInfoPage.hasVerifiedSession(controller);
    final device = connected ? controller.connectedDevice : null;
    final connecting = !connected && controller.isConnecting;
    final disconnecting =
        !connected && !connecting && controller.isConnectionBusy;
    final candidateName =
        (controller.connectedDeviceName ??
                controller.connectedProfile?.displayName ??
                '')
            .trim();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final battery = controller.batteryPercent;
    final hasBattery = battery != null && battery >= 0 && battery <= 100;
    final storageUsed = controller.storageUsedBytes;
    final storageTotal = controller.storageTotalBytes;
    final hasStorage =
        storageUsed != null &&
        storageTotal != null &&
        storageTotal > 0 &&
        storageUsed <= storageTotal;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              connected
                                  ? '已连接：${candidateName.isEmpty ? '未知设备' : candidateName}'
                                  : connecting
                                  ? '正在连接：${candidateName.isEmpty ? '设备' : candidateName}'
                                  : disconnecting
                                  ? '正在断开连接…'
                                  : '尚未连接设备',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleLarge,
                            ),
                          ),
                          if (canOpenDeviceInfo)
                            IconButton(
                              key: const ValueKey('device-info-button'),
                              tooltip: '查看设备信息',
                              style: IconButton.styleFrom(
                                side: BorderSide(color: colors.outlineVariant),
                              ),
                              icon: const Icon(Icons.chevron_right),
                              onPressed: () => unawaited(
                                openVerifiedDeviceInfo(context, controller),
                              ),
                            ),
                        ],
                      ),
                      if (connected) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: colors.tertiary,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text('已连接', style: theme.textTheme.bodyMedium),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                device?.uuid.toString() ?? '设备身份读取中',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.end,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      if (connected && (hasBattery || hasStorage)) ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            if (hasBattery)
                              Expanded(
                                child: _DeviceStat(
                                  icon: Icons.battery_std,
                                  value: '$battery%',
                                  detail: '电量',
                                  progress: battery / 100,
                                  progressColor: battery < 20
                                      ? colors.error
                                      : null,
                                ),
                              ),
                            if (hasBattery && hasStorage)
                              const SizedBox(width: 12),
                            if (hasStorage)
                              Expanded(
                                child: _DeviceStat(
                                  icon: Icons.sd_storage,
                                  value:
                                      '${_formatBytes(storageUsed)} / ${_formatBytes(storageTotal)}',
                                  detail: '存储',
                                  progress: storageUsed / storageTotal,
                                ),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (!connected && controller.bluetoothUnavailable) ...[
                        _BluetoothUnavailableBanner(
                          message: controller.bluetoothStateMessage,
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (!connected)
                        if (connecting || disconnecting)
                          Row(
                            children: [
                              const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  connecting
                                      ? '正在建立设备连接，完成验证后即可使用设备功能。'
                                      : '正在释放蓝牙连接，请稍候。',
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ),
                            ],
                          )
                        else if (controller.isScanning)
                          Row(
                            children: [
                              const ScanningPulseIndicator(),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '正在扫描附近的设备…',
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                    Text(
                                      '找到 ${controller.scanResults.where(isInstallableDiscovery).length} 个可安装设备',
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: colors.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              OutlinedButton.icon(
                                onPressed: controller.stopScan,
                                icon: const Icon(Icons.stop_circle_outlined),
                                label: const Text('停止扫描'),
                              ),
                            ],
                          )
                        else
                          FilledButton.icon(
                            onPressed:
                                controller.canScan &&
                                    !controller.isConnectionBusy
                                ? controller.beginScan
                                : null,
                            icon: const Icon(Icons.bluetooth_searching),
                            label: const Text('开始扫描'),
                          )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            FilledButton.icon(
                              onPressed: controller.isConnectionBusy
                                  ? null
                                  : controller.reconnect,
                              icon: controller.isConnectionBusy
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.refresh),
                              label: Text(
                                controller.isConnectionBusy ? '正在连接' : '重新连接',
                              ),
                            ),
                            OutlinedButton.icon(
                              key: const ValueKey('disconnect-button'),
                              onPressed: controller.isConnectionBusy
                                  ? null
                                  : controller.disconnect,
                              icon: const Icon(Icons.link_off),
                              label: const Text('断开连接'),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
              if (controller.error case final error?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (!connected && controller.authKeyBindings.isNotEmpty) ...[
                const SizedBox(height: 12),
                _SavedDevicesSection(
                  bindings: controller.authKeyBindings,
                  enabled: !controller.isConnectionBusy && controller.canScan,
                  onConnect: controller.connectSavedDevice,
                ),
              ],
              if (!connected && !controller.isConnectionBusy) ...[
                const SizedBox(height: 12),
                ScanResultsList(
                  results: controller.scanResults,
                  onConnect: (result) => _connectWithAuthKey(context, result),
                ),
              ] else if (connected) ...[
                const SizedBox(height: 12),
                Text('安装', style: Theme.of(context).textTheme.titleMedium),
                const Text('完成设备验证后，可连续安装多个文件。'),
                const SizedBox(height: 8),
                InstallSplitButton(
                  preferredTarget: preferredInstallTarget,
                  enabled:
                      controller.sessionReady &&
                      !controller.installInProgress &&
                      !controller.timeSyncInProgress &&
                      !controller.statusRefreshInProgress,
                  onInstall: (target) => _pickAndTry(context, target),
                  onInstallFirmware: () => _pickFirmware(context),
                ),
                if (controller.latestTask case final task?)
                  InstallTaskCard(
                    task: task,
                    onCancel: controller.cancelInstall,
                    onRetry: controller.retryInstall,
                    onClear: controller.clearLatestTask,
                  ),
              ],
              const SizedBox(height: 12),
              DiagnosticLogToggle(
                entryCount: appLogger.length,
                enabled: diagnosticLogWindowOpen,
                onChanged: onDiagnosticLogWindowChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SavedDevicesSection extends StatelessWidget {
  const _SavedDevicesSection({
    required this.bindings,
    required this.enabled,
    required this.onConnect,
  });

  final List<AuthKeyBinding> bindings;
  final bool enabled;
  final Future<bool> Function(AuthKeyBinding binding) onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Container(
      key: const ValueKey('saved-devices-section'),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Icon(Icons.history, size: 20, color: colors.primary),
                const SizedBox(width: 8),
                Text('已保存设备', style: theme.textTheme.titleMedium),
                const Spacer(),
                Text(
                  '${bindings.length} 台',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          for (var index = 0; index < bindings.length; index++) ...[
            if (index > 0) const Divider(height: 1),
            _SavedDeviceTile(
              binding: bindings[index],
              enabled: enabled,
              onConnect: onConnect,
            ),
          ],
        ],
      ),
    );
  }
}

class _SavedDeviceTile extends StatelessWidget {
  const _SavedDeviceTile({
    required this.binding,
    required this.enabled,
    required this.onConnect,
  });

  final AuthKeyBinding binding;
  final bool enabled;
  final Future<bool> Function(AuthKeyBinding binding) onConnect;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.watch_outlined),
    title: Text(
      binding.name.trim().isEmpty ? '已保存设备' : binding.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(
      binding.id,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontFamily: 'monospace'),
    ),
    trailing: OutlinedButton.icon(
      key: ValueKey('connect-saved-device-${binding.id}'),
      onPressed: enabled ? () => unawaited(onConnect(binding)) : null,
      icon: const Icon(Icons.link, size: 18),
      label: const Text('连接'),
    ),
  );
}

class _BluetoothUnavailableBanner extends StatelessWidget {
  const _BluetoothUnavailableBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('bluetooth-unavailable-banner'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.bluetooth_disabled, color: colors.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colors.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// 设备卡片上的统计块（电量/存储）。
class _DeviceStat extends StatelessWidget {
  const _DeviceStat({
    required this.icon,
    required this.value,
    required this.detail,
    required this.progress,
    this.progressColor,
  });

  final IconData icon;
  final String value;
  final String detail;
  final double progress;
  final Color? progressColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 4,
              color: progressColor ?? theme.colorScheme.primary,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(1)} KB';
}
