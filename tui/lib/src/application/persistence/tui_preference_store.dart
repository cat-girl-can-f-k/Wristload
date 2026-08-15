/// Persistence for small, non-secret TUI preferences.
library;

import 'dart:convert';
import 'dart:io';

import '../../domain/tui_application_support.dart';
import 'atomic_json_file_store.dart';

class TuiPreferences {
  const TuiPreferences({
    this.autoConnectLastDevice = true,
    this.themeId = defaultThemeId,
  });

  static const defaultThemeId = 'black-blue';

  final bool autoConnectLastDevice;
  final String themeId;

  TuiPreferences copyWith({bool? autoConnectLastDevice, String? themeId}) {
    return TuiPreferences(
      autoConnectLastDevice:
          autoConnectLastDevice ?? this.autoConnectLastDevice,
      themeId: themeId ?? this.themeId,
    );
  }

  Map<String, Object?> toJson() => {
        'autoConnectLastDevice': autoConnectLastDevice,
        'themeId': themeId,
      };

  factory TuiPreferences.fromJson(Map<String, Object?> json) {
    final autoConnect = json['autoConnectLastDevice'];
    final themeId = json['themeId'];
    return TuiPreferences(
      autoConnectLastDevice: autoConnect is bool
          ? autoConnect
          : const TuiPreferences().autoConnectLastDevice,
      themeId: _normalizeThemeId(
        themeId is String ? themeId : const TuiPreferences().themeId,
      ),
    );
  }

  static String _normalizeThemeId(String value) {
    final normalized = value.trim();
    return normalized.isEmpty ? defaultThemeId : normalized;
  }
}

/// TUI-specific settings store. It holds neither saved devices nor authkeys.
class TuiPreferenceStore {
  TuiPreferenceStore({
    File? file,
    Future<File> Function()? fileResolver,
  }) : _store = file != null
            ? AtomicJsonFileStore(file: file)
            : AtomicJsonFileStore(fileResolver: fileResolver ?? _defaultFile);

  static const fileName = 'tui_preferences.json';

  final AtomicJsonFileStore _store;
  Future<void> _operationQueue = Future<void>.value();

  static Future<File> _defaultFile() async {
    final directory = await wristloadTuiApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  Future<TuiPreferences> load() async {
    await _waitForWrites();
    try {
      final document = await _store.read();
      if (document == null) return const TuiPreferences();
      final decoded = jsonDecode(document);
      if (decoded is! Map) return const TuiPreferences();
      return TuiPreferences.fromJson(Map<String, Object?>.from(decoded));
    } on Object {
      return const TuiPreferences();
    }
  }

  Future<void> save(TuiPreferences preferences) {
    return _enqueue(() => _store.write(jsonEncode(preferences.toJson())));
  }

  Future<void> setAutoConnectLastDevice(bool enabled) async {
    await _enqueue(() async {
      final current = await _loadWithoutWaiting();
      await _store.write(
        jsonEncode(current.copyWith(autoConnectLastDevice: enabled).toJson()),
      );
    });
  }

  Future<void> setThemeId(String themeId) async {
    final normalized = TuiPreferences._normalizeThemeId(themeId);
    await _enqueue(() async {
      final current = await _loadWithoutWaiting();
      await _store
          .write(jsonEncode(current.copyWith(themeId: normalized).toJson()));
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _operationQueue.then<void>(
      (_) => operation(),
      onError: (_) => operation(),
    );
    _operationQueue = next;
    return next;
  }

  Future<void> _waitForWrites() async {
    try {
      await _operationQueue;
    } on Object {
      // Keep the next preference read usable after an interrupted write.
    }
  }

  Future<TuiPreferences> _loadWithoutWaiting() async {
    try {
      final document = await _store.read();
      if (document == null) return const TuiPreferences();
      final decoded = jsonDecode(document);
      return decoded is Map
          ? TuiPreferences.fromJson(Map<String, Object?>.from(decoded))
          : const TuiPreferences();
    } on Object {
      return const TuiPreferences();
    }
  }
}
