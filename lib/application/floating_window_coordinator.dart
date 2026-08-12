import 'dart:async';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:system_tray/system_tray.dart';
import 'package:window_manager/window_manager.dart';

import '../domain/floating_window_preferences.dart';
import '../domain/queue_file_importer.dart';
import 'device_controller.dart';
import 'floating_install_snapshot_mapper.dart';

const floatingInstallWindowArgument = 'floating-install-window';
const floatingInstallChannelName = 'miwearable/floating-install-window';
const floatingInstallWindowSize = Size(264, 148);

typedef FloatingWindowNotice = void Function(FloatingWindowImportNotice notice);

/// Owns the platform-facing lifetime of the optional floating install window.
///
/// The main Flutter engine remains the single owner of [DeviceController]. The
/// floating engine receives immutable snapshots and sends file paths or simple
/// commands through [WindowMethodChannel].
class FloatingWindowCoordinator with WindowListener {
  FloatingWindowCoordinator({
    required this.controller,
    FloatingWindowPreferences? preferences,
    QueueFileImporter? importer,
    this.onNotice,
    this.onOpenMainWindow,
    this.onExitRequested,
  })  : _preferences = preferences ?? FloatingWindowPreferences(),
        _importer = importer ?? QueueFileImporter();

  final DeviceController controller;
  final FloatingWindowPreferences _preferences;
  final QueueFileImporter _importer;
  final FloatingWindowNotice? onNotice;
  final FutureOr<void> Function()? onOpenMainWindow;
  final FutureOr<void> Function()? onExitRequested;

  final WindowMethodChannel _channel = const WindowMethodChannel(
    floatingInstallChannelName,
    mode: ChannelMode.bidirectional,
  );
  final SystemTray _systemTray = SystemTray();

  WindowController? _floatingWindow;
  bool _enabled = false;
  bool _initialized = false;
  bool _floatingReady = false;
  bool _showWhenReady = false;
  bool _snapshotPublishInProgress = false;
  bool _snapshotPublishPending = false;
  bool _trayReady = false;
  bool _exiting = false;
  bool _disposed = false;

  bool get enabled => _enabled;

  Future<void> initialize() async {
    if (_initialized || !Platform.isWindows) return;
    _initialized = true;
    await _channel.setMethodCallHandler(_handleFloatingCall);
    windowManager.addListener(this);
    controller.addListener(_publishSnapshot);
    // Tray integration is optional; a missing icon or unsupported shell must
    // not prevent the floating window from being created.
    try {
      await _initializeTray();
    } on Object catch (error, stackTrace) {
      debugPrint('System tray initialization failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }

    _enabled = await _preferences.readEnabled();
    if (_enabled) await _ensureFloatingWindow(show: true);
  }

  Future<void> setEnabled(bool enabled) async {
    if (!Platform.isWindows) return;
    if (!_initialized) await initialize();
    if (_enabled == enabled) return;
    _enabled = enabled;
    await _preferences.writeEnabled(enabled);
    if (enabled) {
      await _ensureFloatingWindow(show: true);
    } else {
      await hideFloatingWindow();
    }
  }

  Future<void> showFloatingWindow() async {
    if (!_enabled) return;
    await _ensureFloatingWindow(show: true);
  }

  Future<void> hideFloatingWindow() async {
    await _floatingWindow?.hide();
  }

  Future<void> showMainWindow() async {
    await _floatingWindow?.hide();
    await windowManager.setAlwaysOnTop(false);
    await windowManager.show();
    await windowManager.focus();
    await onOpenMainWindow?.call();
  }

  Future<void> _ensureFloatingWindow({required bool show}) async {
    _showWhenReady = show;
    var floating = _floatingWindow;
    if (floating == null) {
      final windows = await WindowController.getAll();
      for (final candidate in windows) {
        if (candidate.arguments == floatingInstallWindowArgument) {
          floating = candidate;
          break;
        }
      }
    }
    floating ??= await WindowController.create(
      const WindowConfiguration(
        arguments: floatingInstallWindowArgument,
        hiddenAtLaunch: true,
      ),
    );
    _floatingWindow = floating;
    if (_floatingReady) {
      await _sendConfiguration();
      _publishSnapshot();
      if (show) await floating.show();
    }
  }

  Future<Object?> _handleFloatingCall(MethodCall call) async {
    switch (call.method) {
      case 'ready':
        _floatingReady = true;
        scheduleMicrotask(() => unawaited(_finishFloatingReady()));
        return true;
      case 'addFiles':
        return _importFiles(_stringList(call.arguments));
      case 'retry':
        return _retryFile(call.arguments);
      case 'openMain':
        await showMainWindow();
        return true;
      case 'hideFloating':
        await hideFloatingWindow();
        return true;
      case 'position':
        await _savePosition(call.arguments);
        return true;
      default:
        throw MissingPluginException(
            'Unknown floating-window call: ${call.method}');
    }
  }

  Future<Map<String, Object?>> _importFiles(List<String> paths) async {
    final result = await _importer.prepare(
      paths,
      existingPaths: controller.installQueue.map((entry) => entry.request.path),
    );
    for (final request in result.requests) {
      controller.enqueue(request);
    }

    final notice = FloatingWindowImportNotice(
      addedCount: result.addedCount,
      duplicateCount: result.duplicateCount,
      unsupportedCount: result.unsupportedCount,
      failureCount: result.failures.length,
    );
    onNotice?.call(notice);

    // A drop onto the floating window means “install now”. The controller
    // still owns all authentication and compatibility gates.
    if (result.addedCount > 0 && controller.sessionReady) {
      unawaited(controller.runQueue());
    } else if (result.addedCount > 0) {
      unawaited(showMainWindow());
    }

    return notice.toJson();
  }

  bool _retryFile(Object? arguments) {
    final path = arguments is Map ? arguments['path'] as String? : null;
    for (final entry in controller.installQueue.reversed) {
      if (entry.canRetry &&
          (path == null || _samePath(entry.request.path, path))) {
        return controller.retryQueueEntry(entry);
      }
    }
    return false;
  }

  Future<void> _sendConfiguration() async {
    if (!_floatingReady || _disposed) return;
    final position = await _restoredOrDefaultPosition();
    await _invokeFloating('configure', {
      'width': floatingInstallWindowSize.width,
      'height': floatingInstallWindowSize.height,
      'x': position.dx,
      'y': position.dy,
      'alwaysOnTop': !(await windowManager.isFocused()),
    });
  }

  Future<void> _finishFloatingReady() async {
    await _sendConfiguration();
    if (!_floatingReady || _disposed) return;
    _publishSnapshot();
    if (_enabled && _showWhenReady) {
      await _floatingWindow?.show();
    }
  }

  void _publishSnapshot() {
    if (!_floatingReady || _disposed) return;
    _snapshotPublishPending = true;
    if (!_snapshotPublishInProgress) {
      unawaited(_drainSnapshots());
    }
  }

  Future<void> _drainSnapshots() async {
    _snapshotPublishInProgress = true;
    try {
      while (_snapshotPublishPending && _floatingReady && !_disposed) {
        _snapshotPublishPending = false;
        await _invokeFloating(
          'snapshot',
          controller.floatingInstallSnapshot.toJson(),
        );
      }
    } finally {
      _snapshotPublishInProgress = false;
      if (_snapshotPublishPending && _floatingReady && !_disposed) {
        unawaited(_drainSnapshots());
      }
    }
  }

  Future<void> _invokeFloating(String method, Object? arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on WindowChannelException catch (error) {
      // A secondary engine may still be starting, or may just have closed.
      debugPrint('Floating-window channel $method failed: $error');
      _floatingReady = false;
    }
  }

  Future<void> _savePosition(Object? arguments) async {
    if (arguments is! Map) return;
    final x = arguments['x'];
    final y = arguments['y'];
    if (x is! num || y is! num || !x.isFinite || !y.isFinite) return;
    await _preferences.writePosition(
      FloatingWindowPosition(x: x.toDouble(), y: y.toDouble()),
    );
  }

  Future<Offset> _restoredOrDefaultPosition() async {
    final displays = await screenRetriever.getAllDisplays();
    final saved = await _preferences.readPosition();
    if (saved != null) {
      final position = Offset(saved.x, saved.y);
      if (displays.any((display) => _fitsDisplay(position, display))) {
        return position;
      }
    }

    final primary = await screenRetriever.getPrimaryDisplay();
    final origin = primary.visiblePosition ?? Offset.zero;
    final area = primary.visibleSize ?? primary.size;
    return Offset(
      origin.dx + area.width - floatingInstallWindowSize.width - 12,
      origin.dy + area.height - floatingInstallWindowSize.height - 48,
    );
  }

  bool _fitsDisplay(Offset position, Display display) {
    final origin = display.visiblePosition ?? Offset.zero;
    final area = display.visibleSize ?? display.size;
    final bounds = origin & area;
    final windowBounds = position & floatingInstallWindowSize;
    return bounds.contains(windowBounds.topLeft) &&
        bounds.contains(windowBounds.bottomRight - const Offset(1, 1));
  }

  Future<void> _initializeTray() async {
    final iconPath = _trayIconPath();
    await _systemTray.initSystemTray(
      iconPath: iconPath,
      toolTip: 'MiWearable 安装工具',
    );
    final menu = Menu();
    await menu.buildFrom([
      MenuItemLabel(
        label: '显示主窗口',
        onClicked: (_) => unawaited(showMainWindow()),
      ),
      MenuItemLabel(
        label: '显示悬浮窗',
        onClicked: (_) => unawaited(showFloatingWindow()),
      ),
      MenuSeparator(),
      MenuItemLabel(
        label: '退出',
        onClicked: (_) => unawaited(_exitApplication()),
      ),
    ]);
    await _systemTray.setContextMenu(menu);
    _trayReady = true;
    _systemTray.registerSystemTrayEventHandler((event) {
      if (event == kSystemTrayEventClick ||
          event == kSystemTrayEventDoubleClick) {
        unawaited(showMainWindow());
      } else if (event == kSystemTrayEventRightClick) {
        unawaited(_systemTray.popUpContextMenu());
      }
    });
  }

  String _trayIconPath() {
    final executableDir = File(Platform.resolvedExecutable).parent.path;
    final bundled =
        '$executableDir${Platform.pathSeparator}data${Platform.pathSeparator}'
        'flutter_assets${Platform.pathSeparator}windows${Platform.pathSeparator}'
        'runner${Platform.pathSeparator}resources${Platform.pathSeparator}'
        'app_icon.ico';
    if (File(bundled).existsSync()) return bundled;

    // Debug launches run from the project directory, where the source asset
    // remains available even before a build copies Flutter assets.
    final source =
        '${Directory.current.path}${Platform.pathSeparator}windows${Platform.pathSeparator}'
        'runner${Platform.pathSeparator}resources${Platform.pathSeparator}'
        'app_icon.ico';
    return source;
  }

  Future<void> _exitApplication() async {
    if (_exiting) return;
    _exiting = true;
    await _invokeFloating('destroy', null);
    if (_trayReady) {
      await _systemTray.destroy();
      _trayReady = false;
    }
    if (onExitRequested != null) {
      await onExitRequested!.call();
    } else {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
  }

  @override
  void onWindowFocus() {
    unawaited(_invokeFloating('setAlwaysOnTop', false));
  }

  @override
  void onWindowBlur() {
    if (_enabled) unawaited(_invokeFloating('setAlwaysOnTop', true));
  }

  @override
  void onWindowClose() {
    if (_exiting) return;
    if (!_trayReady) {
      _exiting = true;
      unawaited(_destroyMainWindow());
      return;
    }
    // Main-window close is a tray hide. The tray Exit action is the only
    // process-terminating path.
    unawaited(windowManager.hide());
    if (_enabled) unawaited(showFloatingWindow());
  }

  Future<void> _destroyMainWindow() async {
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_initialized) {
      controller.removeListener(_publishSnapshot);
      windowManager.removeListener(this);
      await _channel.setMethodCallHandler(null);
    }
    if (_trayReady) {
      await _systemTray.destroy();
      _trayReady = false;
    }
  }
}

class FloatingWindowImportNotice {
  const FloatingWindowImportNotice({
    required this.addedCount,
    required this.duplicateCount,
    required this.unsupportedCount,
    required this.failureCount,
  });

  final int addedCount;
  final int duplicateCount;
  final int unsupportedCount;
  final int failureCount;

  Map<String, Object> toJson() => {
        'addedCount': addedCount,
        'duplicateCount': duplicateCount,
        'unsupportedCount': unsupportedCount,
        'failureCount': failureCount,
      };
}

List<String> _stringList(Object? value) {
  if (value is Map) value = value['paths'];
  if (value is! List) return const [];
  return value.whereType<String>().where((path) => path.isNotEmpty).toList();
}

bool _samePath(String a, String b) =>
    QueueFileImporter.normalizePath(a) == QueueFileImporter.normalizePath(b);
