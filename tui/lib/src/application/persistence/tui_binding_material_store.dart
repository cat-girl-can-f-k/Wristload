/// Secure TUI-only persistence for Xiaomi WearAuthV2 binding material.
///
/// Binding material is deliberately separate from saved-device JSON and from
/// the authkey store. A Bluetooth MAC identifies a Keychain account only; it
/// is never used to construct appDeviceId or OOB material.
library;

import 'dart:convert';
import 'dart:io';

import 'saved_tui_device.dart';

/// Explicit Xiaomi identity values for one previously bound device.
///
/// Both values are redacted by [toString] to avoid accidental disclosure by
/// diagnostics or exception interpolation.
class TuiBindingMaterial {
  TuiBindingMaterial({
    required String appDeviceId,
    String? oob,
  })  : appDeviceId = normalizeTuiAppDeviceId(appDeviceId),
        oob = normalizeTuiBindingOob(oob);

  final String appDeviceId;
  final String? oob;

  bool get hasOob => oob != null;

  @override
  String toString() {
    final oobState = oob == null ? '<absent>' : '<redacted>';
    return 'TuiBindingMaterial(appDeviceId: <redacted>, oob: $oobState)';
  }

  @override
  bool operator ==(Object other) {
    return other is TuiBindingMaterial &&
        other.appDeviceId == appDeviceId &&
        other.oob == oob;
  }

  @override
  int get hashCode => Object.hash(appDeviceId, oob);
}

/// TUI-only persistence boundary for one binding record per normalized MAC.
abstract interface class TuiBindingMaterialStore {
  Future<TuiBindingMaterial?> readBindingMaterial(String macAddress);

  Future<void> saveBindingMaterial(
    String macAddress, {
    required String appDeviceId,
    String? oob,
  });

  Future<void> removeBindingMaterial(String macAddress);
}

/// Opaque persistence error which never contains binding values or command
/// output.
class TuiBindingMaterialStoreException implements Exception {
  const TuiBindingMaterialStoreException(this.message);

  final String message;

  @override
  String toString() => 'TuiBindingMaterialStoreException: $message';
}

const int _maxBindingTextUtf8Bytes = 256;

/// Validates an explicit Xiaomi appDeviceId without deriving a fallback.
String normalizeTuiAppDeviceId(String value) {
  return _normalizeBindingText(
    value,
    fieldName: 'appDeviceId',
    allowEmpty: false,
  );
}

/// Validates optional OOB material.
///
/// Whitespace-only input has no material value and is represented by null.
String? normalizeTuiBindingOob(String? value) {
  if (value == null) return null;
  final normalized = _normalizeBindingText(
    value,
    fieldName: 'oob',
    allowEmpty: true,
  );
  return normalized.isEmpty ? null : normalized;
}

String _normalizeBindingText(
  String value, {
  required String fieldName,
  required bool allowEmpty,
}) {
  if (_containsControlCharacter(value)) {
    throw FormatException('$fieldName contains a control character.');
  }
  final normalized = value.trim();
  if (normalized.isEmpty && !allowEmpty) {
    throw FormatException('$fieldName must not be empty.');
  }
  if (utf8.encode(normalized).length > _maxBindingTextUtf8Bytes) {
    throw FormatException(
        '$fieldName exceeds $_maxBindingTextUtf8Bytes UTF-8 bytes.');
  }
  return normalized;
}

bool _containsControlCharacter(String value) {
  return value.runes.any(
    (rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f),
  );
}

typedef TuiBindingKeychainCommandRunner
    = Future<TuiBindingKeychainCommandResult> Function(List<String> arguments);

/// Minimal command result surface that deliberately excludes stderr.
class TuiBindingKeychainCommandResult {
  const TuiBindingKeychainCommandResult({
    required this.exitCode,
    this.stdout = '',
  });

  final int exitCode;
  final String stdout;
}

/// macOS Keychain implementation for one structured record per normalized MAC.
///
/// The JSON payload is only the value of a dedicated Keychain item. It is not
/// written to an application-support JSON file, and command failures expose no
/// command diagnostics or binding values.
class MacKeychainTuiBindingMaterialStore implements TuiBindingMaterialStore {
  MacKeychainTuiBindingMaterialStore({
    TuiBindingKeychainCommandRunner? commandRunner,
    String serviceName = defaultServiceName,
  })  : serviceName = _normalizeServiceName(serviceName),
        _commandRunner = commandRunner ?? _runSecurity;

  static const String defaultServiceName =
      'com.anemo.wristload.tui.binding-material';
  static const int _itemNotFoundExitCode = 44;

  final TuiBindingKeychainCommandRunner _commandRunner;
  final String serviceName;
  Future<void> _operationQueue = Future<void>.value();

  @override
  Future<TuiBindingMaterial?> readBindingMaterial(String macAddress) async {
    final account = SavedTuiDevice.normalizeMacAddress(macAddress);
    return _enqueue(() async {
      try {
        final result = await _commandRunner([
          'find-generic-password',
          '-s',
          serviceName,
          '-a',
          account,
          '-w',
        ]);
        if (result.exitCode == _itemNotFoundExitCode) return null;
        if (result.exitCode != 0) throw const _BindingKeychainFailure();
        return _decodeBindingPayload(result.stdout);
      } on FormatException {
        throw const TuiBindingMaterialStoreException(
          'Saved binding material is invalid.',
        );
      } on Object {
        throw const TuiBindingMaterialStoreException(
          'Unable to read saved binding material.',
        );
      }
    });
  }

  @override
  Future<void> saveBindingMaterial(
    String macAddress, {
    required String appDeviceId,
    String? oob,
  }) async {
    final account = SavedTuiDevice.normalizeMacAddress(macAddress);
    final material = TuiBindingMaterial(appDeviceId: appDeviceId, oob: oob);
    final payload = _encodeBindingPayload(material);
    await _enqueue<void>(() async {
      try {
        final result = await _commandRunner([
          'add-generic-password',
          '-U',
          '-s',
          serviceName,
          '-a',
          account,
          '-w',
          payload,
        ]);
        if (result.exitCode != 0) throw const _BindingKeychainFailure();
      } on Object {
        throw const TuiBindingMaterialStoreException(
          'Unable to save binding material.',
        );
      }
    });
  }

  @override
  Future<void> removeBindingMaterial(String macAddress) async {
    final account = SavedTuiDevice.normalizeMacAddress(macAddress);
    await _enqueue<void>(() async {
      try {
        final result = await _commandRunner([
          'delete-generic-password',
          '-s',
          serviceName,
          '-a',
          account,
        ]);
        if (result.exitCode != 0 && result.exitCode != _itemNotFoundExitCode) {
          throw const _BindingKeychainFailure();
        }
      } on Object {
        throw const TuiBindingMaterialStoreException(
          'Unable to remove binding material.',
        );
      }
    });
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final next = _operationQueue.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace __) => operation(),
    );
    _operationQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  static String _normalizeServiceName(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || _containsControlCharacter(normalized)) {
      throw ArgumentError.value(
          value, 'serviceName', 'must be a non-empty label');
    }
    if (normalized == 'com.anemo.wristload.tui.authkey') {
      throw ArgumentError.value(
        value,
        'serviceName',
        'must differ from the authkey Keychain service',
      );
    }
    return normalized;
  }

  static String _encodeBindingPayload(TuiBindingMaterial material) {
    return jsonEncode(<String, Object?>{
      'version': 1,
      'appDeviceId': material.appDeviceId,
      if (material.oob != null) 'oob': material.oob,
    });
  }

  static TuiBindingMaterial _decodeBindingPayload(String stdout) {
    final payload = _removeTerminalLineEnding(stdout);
    if (payload.isEmpty || payload.contains('\n') || payload.contains('\r')) {
      throw const FormatException(
          'Binding payload must contain one JSON record.');
    }
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) {
        throw const FormatException('Binding payload is not an object.');
      }
      const allowedKeys = <String>{'version', 'appDeviceId', 'oob'};
      if (decoded.keys.any(
            (key) => key is! String || !allowedKeys.contains(key),
          ) ||
          decoded['version'] != 1) {
        throw const FormatException('Binding payload fields are invalid.');
      }
      final appDeviceId = decoded['appDeviceId'];
      final oob = decoded['oob'];
      if (appDeviceId is! String || (oob != null && oob is! String)) {
        throw const FormatException('Binding payload values are invalid.');
      }
      return TuiBindingMaterial(
        appDeviceId: appDeviceId,
        oob: oob as String?,
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Binding payload is invalid.');
    }
  }

  static String _removeTerminalLineEnding(String value) {
    if (value.endsWith('\r\n')) {
      return value.substring(0, value.length - 2);
    }
    if (value.endsWith('\n') || value.endsWith('\r')) {
      return value.substring(0, value.length - 1);
    }
    return value;
  }

  static Future<TuiBindingKeychainCommandResult> _runSecurity(
    List<String> arguments,
  ) async {
    try {
      final result = await Process.run(
        '/usr/bin/security',
        arguments,
        runInShell: false,
      );
      return TuiBindingKeychainCommandResult(
        exitCode: result.exitCode,
        stdout: result.stdout is String ? result.stdout as String : '',
      );
    } on Object {
      throw const _BindingKeychainFailure();
    }
  }
}

/// In-memory test double with the same normalized-MAC binding contract.
class InMemoryTuiBindingMaterialStore implements TuiBindingMaterialStore {
  final Map<String, TuiBindingMaterial> _values =
      <String, TuiBindingMaterial>{};

  @override
  Future<TuiBindingMaterial?> readBindingMaterial(String macAddress) async {
    return _values[SavedTuiDevice.normalizeMacAddress(macAddress)];
  }

  @override
  Future<void> saveBindingMaterial(
    String macAddress, {
    required String appDeviceId,
    String? oob,
  }) async {
    final account = SavedTuiDevice.normalizeMacAddress(macAddress);
    _values[account] = TuiBindingMaterial(appDeviceId: appDeviceId, oob: oob);
  }

  @override
  Future<void> removeBindingMaterial(String macAddress) async {
    _values.remove(SavedTuiDevice.normalizeMacAddress(macAddress));
  }
}

class _BindingKeychainFailure implements Exception {
  const _BindingKeychainFailure();
}
