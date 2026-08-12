import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../application/floating_window_coordinator.dart';
import '../domain/floating_install_snapshot.dart';
import 'floating_install_window.dart';

/// Secondary-engine host for the compact Windows installation window.
class FloatingInstallWindowApp extends StatefulWidget {
  const FloatingInstallWindowApp({super.key});

  @override
  State<FloatingInstallWindowApp> createState() =>
      _FloatingInstallWindowAppState();
}

class _FloatingInstallWindowAppState extends State<FloatingInstallWindowApp>
    with WindowListener {
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  final WindowMethodChannel _channel = const WindowMethodChannel(
    floatingInstallChannelName,
    mode: ChannelMode.bidirectional,
  );
  FloatingInstallSnapshot _snapshot = const FloatingInstallSnapshot.idle(
    connected: false,
    authenticated: false,
    deviceName: '',
  );
  bool _destroying = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      await _channel.setMethodCallHandler(_handleMainCall);
      await windowManager.waitUntilReadyToShow(
        const WindowOptions(
          size: floatingInstallWindowSize,
          minimumSize: floatingInstallWindowSize,
          maximumSize: floatingInstallWindowSize,
          alwaysOnTop: true,
          backgroundColor: Colors.transparent,
          skipTaskbar: true,
          titleBarStyle: TitleBarStyle.hidden,
          windowButtonVisibility: false,
        ),
        () async {
          await windowManager.setAsFrameless();
          await windowManager.setResizable(false);
          await windowManager.setPreventClose(true);
        },
      );
      await _channel.invokeMethod<void>('ready');
    } on Object catch (error, stackTrace) {
      debugPrint('Floating window initialization failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<Object?> _handleMainCall(MethodCall call) async {
    switch (call.method) {
      case 'snapshot':
        final values = call.arguments;
        if (values is Map && mounted) {
          setState(() {
            _snapshot = FloatingInstallSnapshot.fromJson(values);
          });
        }
        return true;
      case 'configure':
        await _configureWindow(call.arguments);
        return true;
      case 'setAlwaysOnTop':
        await windowManager.setAlwaysOnTop(call.arguments == true);
        return true;
      case 'destroy':
        _destroying = true;
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
        return true;
      default:
        throw MissingPluginException(
          'Unknown main-window call: ${call.method}',
        );
    }
  }

  Future<void> _configureWindow(Object? arguments) async {
    if (arguments is! Map) return;
    final width = (arguments['width'] as num?)?.toDouble();
    final height = (arguments['height'] as num?)?.toDouble();
    final x = (arguments['x'] as num?)?.toDouble();
    final y = (arguments['y'] as num?)?.toDouble();
    if (width != null && height != null) {
      final size = Size(width, height);
      await windowManager.setMinimumSize(size);
      await windowManager.setMaximumSize(size);
      await windowManager.setSize(size);
    }
    if (x != null && y != null) {
      await windowManager.setPosition(Offset(x, y));
    }
    await windowManager.setSkipTaskbar(true);
    await windowManager.setAlwaysOnTop(arguments['alwaysOnTop'] == true);
  }

  Future<void> _addFiles(List<String> paths) async {
    Map<Object?, Object?>? result;
    try {
      result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'addFiles',
        {'paths': paths},
      );
    } on Object {
      if (mounted) _showNotice('无法连接主窗口，请稍后重试', error: true);
      return;
    }
    if (!mounted || result == null) return;
    final added = (result['addedCount'] as num?)?.toInt() ?? 0;
    final duplicates = (result['duplicateCount'] as num?)?.toInt() ?? 0;
    final unsupported = (result['unsupportedCount'] as num?)?.toInt() ?? 0;
    final failures = (result['failureCount'] as num?)?.toInt() ?? 0;
    if (unsupported > 0) {
      _showNotice('仅支持 .bin / .face / .rpk 文件', error: true);
    }
    if (duplicates > 0) {
      _showNotice('$duplicates 个文件已在队列中，已跳过');
    }
    if (failures > 0) {
      _showNotice('$failures 个文件无法读取，已跳过', error: true);
    }
    if (added > 0) _showNotice('已加入 $added 个文件');
  }

  void _showNotice(String message, {bool error = false}) {
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    final colors = Theme.of(messenger.context).colorScheme;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: error ? TextStyle(color: colors.onError) : null,
        ),
        backgroundColor: error ? colors.error : null,
      ),
    );
  }

  void _openMainWindow() {
    unawaited(_channel.invokeMethod<void>('openMain'));
  }

  void _hideWindow() {
    unawaited(_channel.invokeMethod<void>('hideFloating'));
  }

  void _retry() {
    unawaited(_channel.invokeMethod<bool>('retry'));
  }

  @override
  void onWindowMoved() {
    unawaited(_publishPosition());
  }

  Future<void> _publishPosition() async {
    final position = await windowManager.getPosition();
    await _channel.invokeMethod<void>('position', {
      'x': position.dx,
      'y': position.dy,
    });
  }

  @override
  void onWindowClose() {
    if (_destroying) return;
    unawaited(windowManager.hide());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    unawaited(_channel.setMethodCallHandler(null));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        scaffoldMessengerKey: _messengerKey,
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
        home: FloatingInstallWindow(
          snapshot: _snapshot,
          onFilesDropped: _addFiles,
          onOpenMainWindow: _openMainWindow,
          onHideWindow: _hideWindow,
          onRetry: _retry,
        ),
      );
}
