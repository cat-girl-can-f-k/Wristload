import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:window_manager/window_manager.dart';

import 'application/device_controller.dart';
import 'application/floating_window_coordinator.dart';
import 'domain/firmware_package_inspector.dart';
import 'domain/install_metadata_reader.dart';
import 'domain/install_models.dart';
import 'domain/install_preference_store.dart';
import 'domain/install_task.dart';
import 'presentation/device_info_page.dart';
import 'presentation/firmware_inspection_dialog.dart';
import 'presentation/floating_install_window_app.dart';
import 'presentation/home_widgets.dart';
import 'presentation/install_split_button.dart';
import 'presentation/install_task_card.dart';
import 'presentation/install_warning_dialog.dart';
import 'presentation/install_request_preflight.dart';
import 'presentation/queue_page.dart';
import 'presentation/settings_page.dart';
import 'presentation/tools_page.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    final currentWindow = await WindowController.fromCurrentEngine();
    await windowManager.setPreventClose(true);
    if (currentWindow.arguments == floatingInstallWindowArgument) {
      runApp(const FloatingInstallWindowApp());
      return;
    }
  }
  runApp(WristloadApp(desktopIntegrationEnabled: Platform.isWindows));
}

class WristloadApp extends StatefulWidget {
  const WristloadApp({
    this.desktopIntegrationEnabled = false,
    super.key,
  });

  final bool desktopIntegrationEnabled;

  @override
  State<WristloadApp> createState() => _WristloadAppState();
}

class _WristloadAppState extends State<WristloadApp> {
  final controller = DeviceController();
  final _appShellKey = GlobalKey<_AppShellState>();
  final _installRequestPreflight = const InstallRequestPreflight();
  late final FloatingWindowCoordinator _floatingWindowCoordinator;
  bool _floatingInstallWindowEnabled = false;

  @override
  void initState() {
    super.initState();
    controller.queueInstallPreparer = _prepareQueuedRequest;
    _floatingWindowCoordinator = FloatingWindowCoordinator(
      controller: controller,
      onOpenMainWindow: () => _appShellKey.currentState?.showHome(),
    );
    if (widget.desktopIntegrationEnabled) {
      unawaited(_initializeFloatingWindow());
    }
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
    try {
      await _floatingWindowCoordinator.initialize();
      if (!mounted) return;
      setState(() {
        _floatingInstallWindowEnabled = _floatingWindowCoordinator.enabled;
      });
    } on Object catch (error, stackTrace) {
      debugPrint('Floating window initialization failed: $error');
      debugPrintStack(stackTrace: stackTrace);
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
      debugPrint('Floating window setting failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  void dispose() {
    controller.queueInstallPreparer = null;
    unawaited(_floatingWindowCoordinator.dispose());
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.indigo,
          brightness: Brightness.dark,
        ),
        themeMode: ThemeMode.system,
        home: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => AppShell(
            key: _appShellKey,
            controller: controller,
            floatingInstallWindowEnabled: _floatingInstallWindowEnabled,
            onFloatingInstallWindowEnabledChanged: (enabled) {
              unawaited(_setFloatingInstallWindowEnabled(enabled));
            },
          ),
        ),
        routes: {
          '/device-info': (context) => DeviceInfoPage(controller: controller),
          '/queue': (context) => QueuePage(controller: controller),
          '/tools': (context) => ToolsPage(controller: controller),
        },
      );
}

class AppShell extends StatefulWidget {
  const AppShell({
    required this.controller,
    required this.floatingInstallWindowEnabled,
    required this.onFloatingInstallWindowEnabledChanged,
    super.key,
  });

  final DeviceController controller;
  final bool floatingInstallWindowEnabled;
  final ValueChanged<bool> onFloatingInstallWindowEnabledChanged;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;
  final _installPreferenceStore = InstallPreferenceStore();
  InstallPreference _preferredInstallTarget = InstallPreference.watchface;
  bool _installPreferenceChangedByUser = false;

  @override
  void initState() {
    super.initState();
    _loadInstallPreference();
  }

  void showHome() {
    if (_selectedIndex == 0 || !mounted) return;
    setState(() => _selectedIndex = 0);
  }

  Future<void> _loadInstallPreference() async {
    final target = await _installPreferenceStore.readPreference();
    if (!mounted || _installPreferenceChangedByUser) return;
    setState(() => _preferredInstallTarget = target);
  }

  void _setPreferredInstallTarget(InstallPreference target) {
    if (target == _preferredInstallTarget) return;
    _installPreferenceChangedByUser = true;
    setState(() => _preferredInstallTarget = target);
    _installPreferenceStore.writePreference(target);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Wristload'),
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
                    icon: Icon(Icons.build_outlined),
                    selectedIcon: Icon(Icons.build),
                    label: Text('工具'),
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
                      preferredInstallTarget: _preferredInstallTarget,
                      onPreferredInstallTargetChanged:
                          _setPreferredInstallTarget,
                    ),
                  1 => QueuePage(controller: widget.controller),
                  2 => ToolsPage(controller: widget.controller),
                  _ => TransferSettingsPage(
                      preferredInstallTarget: _preferredInstallTarget,
                      connectionMode: widget.controller.connectionMode,
                      connectionModeEnabled: !widget.controller.isConnected,
                      segmentIntervalMs: widget.controller.segmentIntervalMs,
                      massWindowSize: widget.controller.massWindowSize,
                      autoTimeSync: widget.controller.autoTimeSync,
                      floatingInstallWindowEnabled:
                          widget.floatingInstallWindowEnabled,
                      onConnectionModeChanged:
                          widget.controller.setConnectionMode,
                      onSegmentIntervalChanged:
                          widget.controller.setSegmentIntervalMs,
                      onMassWindowSizeChanged:
                          widget.controller.setMassWindowSize,
                      onAutoTimeSyncChanged: widget.controller.setAutoTimeSync,
                      onFloatingInstallWindowEnabledChanged:
                          widget.onFloatingInstallWindowEnabledChanged,
                      onPreferredInstallTargetChanged:
                          _setPreferredInstallTarget,
                    ),
                },
              ),
            ],
          ),
        ),
      );
}

class HomePage extends StatelessWidget {
  const HomePage({
    required this.controller,
    required this.preferredInstallTarget,
    required this.onPreferredInstallTargetChanged,
    super.key,
  });

  final DeviceController controller;
  final InstallPreference preferredInstallTarget;
  final ValueChanged<InstallPreference> onPreferredInstallTargetChanged;

  Future<void> _pickFirmware(BuildContext context) async {
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip', 'bin'],
    );
    final file = selected?.files.single;
    final path = file?.path;
    if (path == null || !context.mounted) return;

    try {
      final inspection = await const FirmwarePackageInspector().inspect(path);
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
          fileName: file!.name,
          message: error.message.toString(),
        ),
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => FirmwareInspectionErrorDialog(
          fileName: file!.name,
          message: '读取固件包时发生错误：$error',
        ),
      );
    }
  }

  Future<void> _pickAndTry(BuildContext context, InstallKind kind) async {
    final extensions =
        kind == InstallKind.watchface ? const ['bin', 'face'] : const ['rpk'];
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    final path = selected?.files.single.path;
    if (path == null) return;
    try {
      var metadata = await InstallMetadataReader().read(kind, path);
      var unsupportedLuaConfirmed = false;
      var watchfaceResolutionConfirmed = false;
      if (!context.mounted) return;
      if (kind == InstallKind.watchface) {
        final compatibilityError =
            controller.watchfaceCompatibilityError(metadata);
        if (compatibilityError != null) {
          watchfaceResolutionConfirmed =
              await _confirmWatchfaceResolution(context, metadata);
          if (!watchfaceResolutionConfirmed) return;
          if (!context.mounted) return;
        }
        if (controller.requiresUnsupportedLuaConfirmation(metadata)) {
          unsupportedLuaConfirmed =
              await _confirmUnsupportedLuaWatchface(context, metadata);
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
      controller.enqueue(InstallRequest(
        kind: kind,
        path: path,
        metadata: metadata,
        unsupportedLuaConfirmed: unsupportedLuaConfirmed,
        watchfaceResolutionConfirmed: watchfaceResolutionConfirmed,
      ));
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
      BuildContext context, InstallMetadata metadata) async {
    final input = TextEditingController(text: metadata.faceId);
    final formKey = GlobalKey<FormState>();
    try {
      return await showDialog<InstallMetadata>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('表盘 faceId'),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: input,
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
                child: const Text('取消')),
            FilledButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(
                  dialogContext,
                  metadata.copyWith(faceId: input.text.trim()),
                );
              },
              child: const Text('继续'),
            ),
          ],
        ),
      );
    } finally {
      input.dispose();
    }
  }

  Future<InstallMetadata?> _editRpkVersion(
      BuildContext context, InstallMetadata metadata) async {
    final input = TextEditingController();
    final formKey = GlobalKey<FormState>();
    try {
      return await showDialog<InstallMetadata>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('RPK 版本号'),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: input,
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
              onFieldSubmitted: (_) {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(
                  dialogContext,
                  metadata.copyWith(versionCode: int.parse(input.text.trim())),
                );
              },
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            FilledButton(
              onPressed: () {
                if (!formKey.currentState!.validate()) return;
                Navigator.pop(
                  dialogContext,
                  metadata.copyWith(versionCode: int.parse(input.text.trim())),
                );
              },
              child: const Text('继续'),
            ),
          ],
        ),
      );
    } finally {
      input.dispose();
    }
  }

  /// authkey 是正式会话身份校验的必填输入。
  Future<void> _connectWithAuthKey(
      BuildContext context, DiscoveredEventArgs result) async {
    // 已从系统安全存储恢复的 authkey 可直接用于本次连接；弹窗仅用于首次
    // 输入或用户主动更换 key，避免每次连接重复索取同一敏感值。
    if (controller.hasAuthKey) {
      await controller.connect(result);
      return;
    }
    final textController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    String? input;
    try {
      input = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('输入 authkey'),
          content: Form(
            key: formKey,
            child: TextFormField(
              controller: textController,
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
                if (formKey.currentState!.validate()) {
                  Navigator.pop(dialogContext, value.trim());
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
                  Navigator.pop(dialogContext, textController.text.trim());
                }
              },
              child: const Text('连接'),
            ),
          ],
        ),
      );
    } finally {
      textController.dispose();
    }
    if (input != null && await controller.setAuthKey(input)) {
      await controller.connect(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = controller.connectedDevice;
    final battery = controller.batteryPercent;
    final hasBattery = battery != null && battery >= 0 && battery <= 100;
    final storageUsed = controller.storageUsedBytes;
    final storageTotal = controller.storageTotalBytes;
    final hasStorage = storageUsed != null &&
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
                                  device == null
                                      ? '尚未连接设备'
                                      : '已连接：${controller.connectedDeviceName ?? controller.connectedProfile?.displayName ?? '未知设备'}',
                                  style:
                                      Theme.of(context).textTheme.titleLarge),
                            ),
                            if (device != null)
                              IconButton(
                                tooltip: '查看设备信息',
                                style: IconButton.styleFrom(
                                  side: BorderSide(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outlineVariant,
                                  ),
                                ),
                                icon: const Icon(Icons.chevron_right),
                                onPressed: () => Navigator.pushNamed(
                                    context, '/device-info'),
                              ),
                          ],
                        ),
                        if (device != null && (hasBattery || hasStorage)) ...[
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
                                        ? Theme.of(context).colorScheme.error
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
                        if (device == null)
                          FilledButton.icon(
                            onPressed: controller.isScanning
                                ? controller.stopScan
                                : controller.beginScan,
                            icon: Icon(controller.isScanning
                                ? Icons.stop_circle_outlined
                                : Icons.bluetooth_searching),
                            label: Text(
                              controller.isScanning ? '停止扫描' : '扫描附近设备',
                            ),
                          )
                        else
                          OutlinedButton.icon(
                            onPressed: controller.disconnect,
                            icon: const Icon(Icons.link_off),
                            label: const Text('断开连接'),
                          ),
                      ]),
                ),
              ),
              if (controller.error case final error?)
                Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(error,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error))),
              if (device == null) ...[
                const SizedBox(height: 12),
                Text('发现的设备', style: Theme.of(context).textTheme.titleMedium),
                for (final result in controller.scanResults)
                  ExcludeSemantics(
                    key: ValueKey(result.peripheral.uuid.toString()),
                    child: ScanTile(
                      result: result,
                      onConnect: () => _connectWithAuthKey(context, result),
                    ),
                  ),
              ] else ...[
                const SizedBox(height: 12),
                if (!controller.sessionReady && !controller.sppConnecting) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: controller.connectSpp,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重新建立 SPP 会话'),
                  ),
                ],
                const SizedBox(height: 12),
                Text('安装', style: Theme.of(context).textTheme.titleMedium),
                const Text('连接与鉴权只执行一次；会话保持期间可连续安装多个文件。'),
                const SizedBox(height: 8),
                InstallSplitButton(
                  preferredTarget: preferredInstallTarget,
                  enabled: controller.sessionReady &&
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
              LogPanel(logs: controller.logs, onClear: controller.clearLogs),
            ],
          ),
        ),
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
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            minHeight: 4,
            color: progressColor ?? theme.colorScheme.primary,
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
