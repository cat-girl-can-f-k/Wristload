import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

enum DiagnosticLogLevel {
  trace,
  debug,
  info,
  warning,
  error,
  fatal;

  String get label =>
      this == DiagnosticLogLevel.fatal ? 'SEVERE' : name.toUpperCase();
  static DiagnosticLogLevel parse(Object? value) {
    final normalized = value?.toString().toLowerCase();
    if (normalized == 'severe') return DiagnosticLogLevel.fatal;
    return values.firstWhere(
      (item) => item.name == normalized,
      orElse: () => DiagnosticLogLevel.info,
    );
  }
}

enum DiagnosticLogCategory {
  runtime,
  storage,
  communication,
  installation,
  security,
  ui,
  system,
  general;

  String get label => switch (this) {
    runtime => 'Runtime',
    storage => 'Storage',
    communication => 'Communication',
    installation => 'Installation',
    security => 'Security',
    ui => 'UI',
    system => 'System',
    general => 'General',
  };
  static DiagnosticLogCategory parse(Object? value) {
    final normalized = value?.toString().toLowerCase();
    return values.firstWhere(
      (item) => item.name == normalized,
      orElse: () => DiagnosticLogCategory.general,
    );
  }
}

String _defaultLogScope(DiagnosticLogCategory category) =>
    category == DiagnosticLogCategory.ui ? 'frontend' : 'backend';

String _defaultLogComponent(DiagnosticLogCategory category) =>
    switch (category) {
      DiagnosticLogCategory.runtime => 'wristload.Runtime',
      DiagnosticLogCategory.storage => 'wristload.Storage',
      DiagnosticLogCategory.communication => 'wristload.BluetoothPlatform',
      DiagnosticLogCategory.installation => 'wristload.Installation',
      DiagnosticLogCategory.security => 'wristload.Security',
      DiagnosticLogCategory.ui => 'wristload.Frontend',
      DiagnosticLogCategory.system => 'wristload.System',
      DiagnosticLogCategory.general => 'wristload.Application',
    };

String _formatLogField(String key, Object? value) {
  if (value == null) return key + '=null';
  if (value is String) {
    final escaped = value.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    final quoted =
        escaped.isEmpty || !RegExp(r'^[A-Za-z0-9_./:+-]+$').hasMatch(escaped);
    return key + '=' + (quoted ? '"' + escaped + '"' : escaped);
  }
  return key + '=' + value.toString();
}

class DiagnosticLogEntry {
  DiagnosticLogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
    String? scope,
    String? component,
    String? event,
    this.fields = const <String, Object?>{},
    String? id,
  }) : scope = scope ?? _defaultLogScope(category),
       component = component ?? _defaultLogComponent(category),
       event = event ?? message,
       id = id ?? timestamp.microsecondsSinceEpoch.toString();

  factory DiagnosticLogEntry.fromJson(Map<String, Object?> json) {
    final timestamp =
        DateTime.tryParse(json['timestamp']?.toString() ?? '')?.toLocal() ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final rawFields = json['fields'];
    return DiagnosticLogEntry(
      id: json['id']?.toString(),
      timestamp: timestamp,
      level: DiagnosticLogLevel.parse(json['level']),
      category: DiagnosticLogCategory.parse(json['category']),
      scope: json['scope']?.toString(),
      component: json['component']?.toString(),
      event: DiagnosticLogService._redact(
        json['event']?.toString() ?? json['message']?.toString() ?? '',
      ),
      message: DiagnosticLogService._redact(json['message']?.toString() ?? ''),
      fields: rawFields is Map
          ? DiagnosticLogService._redactFields(<String, Object?>{
              for (final e in rawFields.entries) e.key.toString(): e.value,
            })
          : const <String, Object?>{},
    );
  }

  final String id;
  final DateTime timestamp;
  final DiagnosticLogLevel level;
  final DiagnosticLogCategory category;
  final String scope;
  final String component;
  final String event;
  final String message;
  final Map<String, Object?> fields;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'timestamp': timestamp.toUtc().toIso8601String(),
    'level': level.name,
    'category': category.name,
    'scope': scope,
    'component': component,
    'event': event,
    'message': message,
    if (fields.isNotEmpty) 'fields': fields,
  };

  String get displayText {
    final time = timestamp.toLocal().toIso8601String();
    final suffix = fields.isEmpty
        ? ''
        : ' ' +
              fields.entries
                  .map((e) => _formatLogField(e.key, e.value))
                  .join(' ');
    return time +
        '  ' +
        level.label.padRight(7) +
        ' [' +
        scope +
        '] ' +
        component +
        '  ' +
        message +
        suffix;
  }
}

/// Process-wide diagnostic journal. Sensitive values are redacted before they
/// reach memory, the UI, or the JSONL file.
class DiagnosticLogService extends ChangeNotifier {
  DiagnosticLogService({
    this.maxEntries = 5000,
    Future<Directory> Function()? directoryProvider,
  }) : _directoryProvider = directoryProvider;

  static final instance = DiagnosticLogService();
  final int maxEntries;
  final Future<Directory> Function()? _directoryProvider;
  final List<DiagnosticLogEntry> _entries = <DiagnosticLogEntry>[];
  Future<void> _writeQueue = Future<void>.value();
  final List<String> _pendingLines = <String>[];
  Timer? _writeTimer;
  Timer? _notifyTimer;
  File? _journalFile;
  bool _persistenceEnabled = false;
  bool _initialized = false;
  bool _disposed = false;
  bool _notifyPending = false;

  List<DiagnosticLogEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;
  bool get persistenceEnabled => _persistenceEnabled;

  Future<void> initializePersistence() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final directory =
          await (_directoryProvider?.call() ??
              getApplicationSupportDirectory());
      final logDirectory = Directory(
        directory.path + Platform.pathSeparator + 'logs',
      );
      await logDirectory.create(recursive: true);
      final now = DateTime.now();
      final day =
          now.year.toString().padLeft(4, '0') +
          '-' +
          now.month.toString().padLeft(2, '0') +
          '-' +
          now.day.toString().padLeft(2, '0');
      final file = File(
        logDirectory.path +
            Platform.pathSeparator +
            'wristload-' +
            day +
            '.jsonl',
      );
      _journalFile = file;
      _persistenceEnabled = true;
      if (await file.exists()) {
        final lines = await file.readAsLines();
        final start = lines.length > maxEntries ? lines.length - maxEntries : 0;
        for (final line in lines.skip(start)) {
          try {
            final decoded = jsonDecode(line);
            if (decoded is Map)
              _entries.add(
                DiagnosticLogEntry.fromJson(Map<String, Object?>.from(decoded)),
              );
          } on Object {
            // Continue after an isolated malformed journal record.
          }
        }
        if (_entries.isNotEmpty && !_disposed) notifyListeners();
      }
      info(
        '诊断日志持久化已启用',
        category: DiagnosticLogCategory.runtime,
        fields: const <String, Object?>{'file': '<app-support>/logs'},
      );
    } on Object catch (failure, stackTrace) {
      _persistenceEnabled = false;
      error(
        '诊断日志持久化不可用',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{
          'errorType': failure.runtimeType.toString(),
          'stackTrace': stackTrace.toString(),
        },
      );
    }
  }

  DiagnosticLogEntry trace(
    String message, {
    DiagnosticLogCategory category = DiagnosticLogCategory.general,
    String? scope,
    String? component,
    String? event,
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _record(
    DiagnosticLogLevel.trace,
    message,
    category,
    scope: scope,
    component: component,
    event: event,
    fields: fields,
  );
  DiagnosticLogEntry debug(
    String message, {
    DiagnosticLogCategory category = DiagnosticLogCategory.general,
    String? scope,
    String? component,
    String? event,
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _record(
    DiagnosticLogLevel.debug,
    message,
    category,
    scope: scope,
    component: component,
    event: event,
    fields: fields,
  );
  DiagnosticLogEntry info(
    String message, {
    DiagnosticLogCategory category = DiagnosticLogCategory.general,
    String? scope,
    String? component,
    String? event,
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _record(
    DiagnosticLogLevel.info,
    message,
    category,
    scope: scope,
    component: component,
    event: event,
    fields: fields,
  );
  DiagnosticLogEntry warning(
    String message, {
    DiagnosticLogCategory category = DiagnosticLogCategory.general,
    String? scope,
    String? component,
    String? event,
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _record(
    DiagnosticLogLevel.warning,
    message,
    category,
    scope: scope,
    component: component,
    event: event,
    fields: fields,
  );
  DiagnosticLogEntry error(
    String message, {
    DiagnosticLogCategory category = DiagnosticLogCategory.general,
    String? scope,
    String? component,
    String? event,
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _record(
    DiagnosticLogLevel.error,
    message,
    category,
    scope: scope,
    component: component,
    event: event,
    fields: fields,
  );
  DiagnosticLogEntry fatal(
    String message, {
    DiagnosticLogCategory category = DiagnosticLogCategory.general,
    String? scope,
    String? component,
    String? event,
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _record(
    DiagnosticLogLevel.fatal,
    message,
    category,
    scope: scope,
    component: component,
    event: event,
    fields: fields,
  );

  DiagnosticLogEntry _record(
    DiagnosticLogLevel level,
    String message,
    DiagnosticLogCategory category, {
    String? scope,
    String? component,
    String? event,
    required Map<String, Object?> fields,
  }) {
    final entry = DiagnosticLogEntry(
      timestamp: DateTime.now(),
      level: level,
      category: category,
      scope: scope,
      component: component,
      event: event == null ? null : _redact(event),
      message: _redact(message),
      fields: _redactFields(fields),
    );
    _entries.add(entry);
    if (_entries.length > maxEntries)
      _entries.removeRange(0, _entries.length - maxEntries);
    if (_persistenceEnabled && _journalFile != null) {
      _pendingLines.add(jsonEncode(entry.toJson()) + '\n');
      _scheduleWrite();
    }
    _scheduleNotify(immediate: level.index >= DiagnosticLogLevel.error.index);
    return entry;
  }

  void clear() {
    _entries.clear();
    final file = _journalFile;
    if (_persistenceEnabled && file != null) {
      _writeTimer?.cancel();
      _writeTimer = null;
      _enqueuePendingWrite();
      _writeQueue = _writeQueue.then<void>((_) async {
        if (await file.exists()) await file.writeAsString('', flush: true);
      });
    }
    _scheduleNotify(immediate: true);
  }

  Future<void> flush() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    _enqueuePendingWrite();
    await _writeQueue;
  }

  void _scheduleWrite() {
    if (_pendingLines.length >= 64) {
      _writeTimer?.cancel();
      _writeTimer = null;
      _enqueuePendingWrite();
      return;
    }
    _writeTimer ??= Timer(const Duration(milliseconds: 150), () {
      _writeTimer = null;
      _enqueuePendingWrite();
    });
  }

  void _enqueuePendingWrite() {
    if (_pendingLines.isEmpty) return;
    final file = _journalFile;
    if (!_persistenceEnabled || file == null) {
      _pendingLines.clear();
      return;
    }
    final batch = _pendingLines.join();
    _pendingLines.clear();
    _writeQueue = _writeQueue.then<void>(
      (_) async {
        await file.writeAsString(batch, mode: FileMode.append, flush: true);
      },
      onError: (_) async {
        await file.writeAsString(batch, mode: FileMode.append, flush: true);
      },
    );
  }

  void _scheduleNotify({bool immediate = false}) {
    // Entries remain available through [entries] and the JSONL writer even
    // when no UI/window is attached. Avoid creating timers that cannot notify
    // anyone; a newly opened log window requests a fresh snapshot.
    if (_disposed || !hasListeners) return;
    _notifyPending = true;
    if (immediate) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      _notifyPending = false;
      notifyListeners();
      return;
    }
    _notifyTimer ??= Timer(const Duration(milliseconds: 100), () {
      _notifyTimer = null;
      if (_disposed || !_notifyPending) return;
      _notifyPending = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _writeTimer?.cancel();
    _writeTimer = null;
    _enqueuePendingWrite();
    _disposed = true;
    _notifyTimer?.cancel();
    super.dispose();
  }

  static String _redact(String value) => value
      .replaceAllMapped(
        RegExp(
          r'(authkey|token|password|secret|bookmark|nonce|payload|hmac|iv|appkey|appiv|session[_ -]?(?:key|nonce))\s*[:=]\s*[^\s,;]+',
          caseSensitive: false,
        ),
        (match) => match.group(1).toString() + '=<redacted>',
      )
      .replaceAllMapped(
        RegExp(r'(?<![a-f0-9])[a-f0-9]{32,}(?![a-f0-9])', caseSensitive: false),
        (_) => '<redacted-hex>',
      );

  static Map<String, Object?> _redactFields(Map<String, Object?> fields) =>
      <String, Object?>{
        for (final entry in fields.entries)
          entry.key: _redactFieldValue(entry.key, entry.value),
      };

  static Object? _redactFieldValue(String key, Object? value) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    // Wire bytes are forensic evidence, not a credential field. Callers must
    // opt in explicitly with `wireHex`; auth material continues to use the
    // redacted payload/nonce/session-key fields below.
    if (normalized == 'wirehex' && value is String) {
      return value;
    }
    final metadata =
        normalized.startsWith('has') ||
        normalized.startsWith('is') ||
        normalized.endsWith('bytes') ||
        normalized.endsWith('count') ||
        normalized.endsWith('length') ||
        normalized.endsWith('refreshed') ||
        normalized.endsWith('present');
    if (metadata && (value is num || value is bool)) return value;
    final sensitive =
        normalized == 'authkey' ||
        normalized.contains('authkey') ||
        normalized == 'password' ||
        normalized == 'secret' ||
        normalized.contains('secret') ||
        normalized == 'bookmark' ||
        normalized.contains('bookmark') ||
        normalized == 'nonce' ||
        normalized.endsWith('nonce') ||
        normalized == 'payload' ||
        normalized.contains('payload') ||
        normalized == 'hmac' ||
        normalized.contains('sessionkey') ||
        normalized == 'token' ||
        normalized.endsWith('token') ||
        normalized.endsWith('encryptionkey');
    if (sensitive) return '<redacted>';
    return _redactValue(value);
  }

  static Object? _redactValue(Object? value) {
    if (value is String) return _redact(value);
    if (value is Uint8List) return '<redacted bytes=${value.length}>';
    if (value is List) {
      if (value.every((item) => item is int)) {
        return '<redacted bytes=${value.length}>';
      }
      return value
          .map(
            (item) => item is Map
                ? <String, Object?>{
                    for (final entry in item.entries)
                      entry.key.toString(): _redactFieldValue(
                        entry.key.toString(),
                        entry.value,
                      ),
                  }
                : _redactValue(item),
          )
          .toList(growable: false);
    }
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries)
          entry.key.toString(): _redactFieldValue(
            entry.key.toString(),
            entry.value,
          ),
      };
    }
    return value;
  }
}

DiagnosticLogCategory classifyLogMessage(String message) {
  final value = message.toLowerCase();
  if (RegExp(r'authkey|安全存储|书签|鉴权|hmac|密钥|配对').hasMatch(value))
    return DiagnosticLogCategory.security;
  if (RegExp(r'安装|队列|mass|分片|传输|文件|firmware|rpk|表盘').hasMatch(value))
    return DiagnosticLogCategory.installation;
  if (RegExp(r'存储|设置|检查点|文件访问|持久化|读取配置|写入配置').hasMatch(value))
    return DiagnosticLogCategory.storage;
  if (RegExp(r'窗口|主页|界面|主题|ui').hasMatch(value))
    return DiagnosticLogCategory.ui;
  if (RegExp(r'系统时间|runtime|启动|平台').hasMatch(value))
    return DiagnosticLogCategory.runtime;
  if (RegExp(
    r'rfcomm|spp|gatt|ble|蓝牙|扫描|连接|服务|特征|l1|ack|data|帧|写入|读取|版本',
  ).hasMatch(value))
    return DiagnosticLogCategory.communication;
  if (RegExp(r'系统|版本').hasMatch(value)) return DiagnosticLogCategory.runtime;
  return DiagnosticLogCategory.general;
}

DiagnosticLogLevel classifyLogLevel(String message) {
  final value = message.toLowerCase();
  if (RegExp(r'fatal|崩溃|不可恢复').hasMatch(value)) return DiagnosticLogLevel.fatal;
  if (RegExp(r'失败|错误|异常|拒绝|无效|error|exception|failed').hasMatch(value))
    return DiagnosticLogLevel.error;
  if (RegExp(r'警告|注意|未知|warning|unknown').hasMatch(value))
    return DiagnosticLogLevel.warning;
  if (message.startsWith('  ') ||
      RegExp(r'0x[0-9a-f]+|[a-f0-9]{8,}').hasMatch(value))
    return DiagnosticLogLevel.trace;
  return DiagnosticLogLevel.info;
}

final appLogger = DiagnosticLogService.instance;
