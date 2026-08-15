import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'diagnostic_log_service.dart';

const diagnosticLogWindowArgument = 'diagnostic-log-window';
const diagnosticLogWindowChannelName = 'wristload/diagnostic-log-window';

class DiagnosticLogWindowDelta {
  const DiagnosticLogWindowDelta({
    required this.method,
    required this.entries,
    this.removeFirst = 0,
  });

  final String method;
  final List<DiagnosticLogEntry> entries;
  final int removeFirst;
}

DiagnosticLogWindowDelta planDiagnosticLogWindowDelta({
  required List<DiagnosticLogEntry> entries,
  required bool hasSnapshot,
  required int publishedLength,
  required String? publishedLastId,
}) {
  if (!hasSnapshot) {
    return DiagnosticLogWindowDelta(method: 'snapshot', entries: entries);
  }
  if (entries.isEmpty) {
    return const DiagnosticLogWindowDelta(
      method: 'reset',
      entries: <DiagnosticLogEntry>[],
    );
  }
  if (publishedLength == 0 || publishedLastId == null) {
    return DiagnosticLogWindowDelta(method: 'append', entries: entries);
  }
  final lastIndex = entries.indexWhere((entry) => entry.id == publishedLastId);
  if (lastIndex < 0) {
    return DiagnosticLogWindowDelta(method: 'reset', entries: entries);
  }
  final retainedPublishedCount = lastIndex + 1;
  final removedCount = publishedLength - retainedPublishedCount;
  return DiagnosticLogWindowDelta(
    method: 'append',
    entries: entries.skip(retainedPublishedCount).toList(growable: false),
    removeFirst: removedCount < 0 ? 0 : removedCount,
  );
}

class DiagnosticLogWindowCoordinator {
  DiagnosticLogWindowCoordinator({
    DiagnosticLogService? logger,
    VoidCallback? onClear,
    VoidCallback? onClosed,
    Color Function()? themeSeedProvider,
  }) : _logger = logger ?? appLogger,
       _onClear = onClear,
       _onClosed = onClosed,
       _themeSeedProvider =
           themeSeedProvider ?? (() => const Color(0xFF6750A4));

  final DiagnosticLogService _logger;
  final VoidCallback? _onClear;
  final VoidCallback? _onClosed;
  final Color Function() _themeSeedProvider;
  final WindowMethodChannel _channel = const WindowMethodChannel(
    diagnosticLogWindowChannelName,
    mode: ChannelMode.bidirectional,
  );
  WindowController? _window;
  bool _initialized = false;
  bool _ready = false;
  bool _publishing = false;
  bool _publishPending = false;
  bool _publishedSnapshot = false;
  int _publishedLength = 0;
  String? _publishedLastId;
  bool _publishedPersistence = false;
  int? _publishedThemeSeed;
  bool _disposed = false;

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    await _channel.setMethodCallHandler(_handleWindowCall);
    _logger.addListener(_publish);
  }

  Future<void> show() async {
    if (_disposed) return;
    await initialize();
    var window = _window;
    if (window == null) {
      final windows = await WindowController.getAll();
      for (final candidate in windows) {
        if (candidate.arguments == diagnosticLogWindowArgument) {
          window = candidate;
          break;
        }
      }
    }
    window ??= await WindowController.create(
      const WindowConfiguration(
        arguments: diagnosticLogWindowArgument,
        hiddenAtLaunch: true,
      ),
    );
    _window = window;
    _publish();
    await window.show();
  }

  Future<void> hide() async {
    await _window?.hide();
  }

  Future<void> updateTheme() async {
    _publish();
  }

  Future<Object?> _handleWindowCall(MethodCall call) async {
    switch (call.method) {
      case 'ready':
        _ready = true;
        _publishedSnapshot = false;
        _publish();
        return true;
      case 'clear':
        _onClear?.call();
        if (_onClear == null) _logger.clear();
        return true;
      case 'closed':
        _onClosed?.call();
        await _window?.hide();
        return true;
      case 'hide':
        await _window?.hide();
        return true;
      default:
        throw MissingPluginException(
          'Unknown diagnostic log window call: ' + call.method,
        );
    }
  }

  void _publish() {
    if (!_ready || _disposed || _window == null) return;
    _publishPending = true;
    if (!_publishing) unawaited(_drainPublish());
  }

  Future<void> _drainPublish() async {
    _publishing = true;
    try {
      while (_publishPending && _ready && !_disposed) {
        _publishPending = false;
        final entries = _logger.entries;
        final themeSeed = _themeSeedProvider().toARGB32();
        final persistence = _logger.persistenceEnabled;
        final common = <String, Object?>{
          'persistenceEnabled': persistence,
          'themeSeedColor': themeSeed,
        };
        final metadataChanged =
            _publishedPersistence != persistence ||
            _publishedThemeSeed != themeSeed;
        final delta = planDiagnosticLogWindowDelta(
          entries: entries,
          hasSnapshot: _publishedSnapshot && !metadataChanged,
          publishedLength: _publishedLength,
          publishedLastId: _publishedLastId,
        );
        if (delta.method != 'append' ||
            delta.entries.isNotEmpty ||
            delta.removeFirst > 0 ||
            metadataChanged) {
          await _channel.invokeMethod<void>(delta.method, {
            ...common,
            'entries': [for (final entry in delta.entries) entry.toJson()],
            if (delta.removeFirst > 0) 'removeFirst': delta.removeFirst,
          });
        }
        _publishedSnapshot = true;
        _publishedLength = entries.length;
        _publishedLastId = entries.isEmpty ? null : entries.last.id;
        _publishedPersistence = persistence;
        _publishedThemeSeed = themeSeed;
      }
    } on Object {
      _ready = false;
    } finally {
      _publishing = false;
      if (_publishPending && _ready && !_disposed) unawaited(_drainPublish());
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _logger.removeListener(_publish);
    await _channel.setMethodCallHandler(null);
  }
}
