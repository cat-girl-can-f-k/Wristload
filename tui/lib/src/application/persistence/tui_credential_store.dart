/// TUI credential-storage boundary.
///
/// Authkeys never belong in JSON device records, diagnostic logs, or thrown
/// error messages. Implementations bind each key to a normalized device MAC.
library;

import 'dart:io';

import 'saved_tui_device.dart';

abstract interface class TuiCredentialStore {
  Future<String?> readAuthKey(String macAddress);

  Future<void> saveAuthKey(String macAddress, String authKey);

  Future<void> removeAuthKey(String macAddress);
}

/// A deliberately non-descriptive failure that cannot carry an authkey.
class TuiCredentialStoreException implements Exception {
  const TuiCredentialStoreException(this.message);

  final String message;

  @override
  String toString() => 'TuiCredentialStoreException: $message';
}

/// Validates and canonicalizes a Xiaomi authkey without echoing invalid input.
String normalizeTuiAuthKey(String value) {
  final normalized = value.trim().toUpperCase();
  if (!RegExp(r'^[0-9A-F]{32}$').hasMatch(normalized)) {
    throw const FormatException(
        'authkey must be exactly 32 hexadecimal characters.');
  }
  return normalized;
}

typedef KeychainCommandRunner = Future<KeychainCommandResult> Function(
  List<String> arguments,
);

/// Result surface intentionally keeps process diagnostics out of the store API.
class KeychainCommandResult {
  const KeychainCommandResult({
    required this.exitCode,
    this.stdout = '',
  });

  final int exitCode;
  final String stdout;
}

/// Uses the macOS Keychain command-line client for one authkey per MAC address.
///
/// The command's stderr is intentionally discarded. In particular, callers
/// never receive a `ProcessResult` whose output could accidentally be logged.
class MacKeychainCredentialStore implements TuiCredentialStore {
  MacKeychainCredentialStore({
    KeychainCommandRunner? commandRunner,
    this.serviceName = 'com.anemo.wristload.tui.authkey',
  }) : _commandRunner = commandRunner ?? _runSecurity;

  static const _itemNotFoundExitCode = 44;

  final KeychainCommandRunner _commandRunner;
  final String serviceName;

  @override
  Future<String?> readAuthKey(String macAddress) async {
    final account = SavedTuiDevice.normalizeMacAddress(macAddress);
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
      if (result.exitCode != 0) {
        throw const TuiCredentialStoreException(
            'Unable to read saved authkey.');
      }
      try {
        return normalizeTuiAuthKey(result.stdout);
      } on FormatException {
        throw const TuiCredentialStoreException('Saved authkey is invalid.');
      }
    } on TuiCredentialStoreException {
      rethrow;
    } on Object {
      throw const TuiCredentialStoreException('Unable to read saved authkey.');
    }
  }

  @override
  Future<void> saveAuthKey(String macAddress, String authKey) async {
    final account = SavedTuiDevice.normalizeMacAddress(macAddress);
    final normalizedKey = normalizeTuiAuthKey(authKey);
    try {
      final result = await _commandRunner([
        'add-generic-password',
        '-U',
        '-s',
        serviceName,
        '-a',
        account,
        '-w',
        normalizedKey,
      ]);
      if (result.exitCode != 0) {
        throw const TuiCredentialStoreException('Unable to save authkey.');
      }
    } on TuiCredentialStoreException {
      rethrow;
    } on Object {
      throw const TuiCredentialStoreException('Unable to save authkey.');
    }
  }

  @override
  Future<void> removeAuthKey(String macAddress) async {
    final account = SavedTuiDevice.normalizeMacAddress(macAddress);
    try {
      final result = await _commandRunner([
        'delete-generic-password',
        '-s',
        serviceName,
        '-a',
        account,
      ]);
      if (result.exitCode != 0 && result.exitCode != _itemNotFoundExitCode) {
        throw const TuiCredentialStoreException(
            'Unable to remove saved authkey.');
      }
    } on TuiCredentialStoreException {
      rethrow;
    } on Object {
      throw const TuiCredentialStoreException(
          'Unable to remove saved authkey.');
    }
  }

  static Future<KeychainCommandResult> _runSecurity(
    List<String> arguments,
  ) async {
    try {
      final result = await Process.run(
        '/usr/bin/security',
        arguments,
        runInShell: false,
      );
      return KeychainCommandResult(
        exitCode: result.exitCode,
        stdout: result.stdout is String ? result.stdout as String : '',
      );
    } on Object {
      throw const TuiCredentialStoreException('macOS Keychain is unavailable.');
    }
  }
}

/// Test and non-persistent implementation with identical device-key binding.
class InMemoryTuiCredentialStore implements TuiCredentialStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> readAuthKey(String macAddress) async {
    return _values[SavedTuiDevice.normalizeMacAddress(macAddress)];
  }

  @override
  Future<void> saveAuthKey(String macAddress, String authKey) async {
    _values[SavedTuiDevice.normalizeMacAddress(macAddress)] =
        normalizeTuiAuthKey(authKey);
  }

  @override
  Future<void> removeAuthKey(String macAddress) async {
    _values.remove(SavedTuiDevice.normalizeMacAddress(macAddress));
  }
}
