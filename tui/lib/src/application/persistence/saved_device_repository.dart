/// JSON-backed persistence for non-secret saved TUI devices.
library;

import 'dart:convert';
import 'dart:io';

import '../../domain/tui_application_support.dart';
import 'atomic_json_file_store.dart';
import 'saved_tui_device.dart';

abstract interface class SavedDeviceRepository {
  Future<List<SavedTuiDevice>> load();

  Future<SavedTuiDevice?> findByMacAddress(String macAddress);

  /// Inserts or replaces a device using its stable normalized MAC address.
  Future<void> save(SavedTuiDevice device);

  Future<void> removeByMacAddress(String macAddress);
}

/// TUI-only device repository stored below `WristloadTui` Application Support.
///
/// Device JSON intentionally excludes authkeys; [TuiCredentialStore] owns those
/// values using the macOS Keychain.
class JsonSavedDeviceRepository implements SavedDeviceRepository {
  JsonSavedDeviceRepository({
    File? file,
    Future<File> Function()? fileResolver,
  }) : _store = file != null
            ? AtomicJsonFileStore(file: file)
            : AtomicJsonFileStore(fileResolver: fileResolver ?? _defaultFile);

  static const fileName = 'saved_tui_devices.json';

  final AtomicJsonFileStore _store;
  Future<void> _operationQueue = Future<void>.value();

  static Future<File> _defaultFile() async {
    final directory = await wristloadTuiApplicationSupportDirectory();
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  @override
  Future<List<SavedTuiDevice>> load() async {
    await _waitForWrites();
    return _loadNow();
  }

  @override
  Future<SavedTuiDevice?> findByMacAddress(String macAddress) async {
    final normalized = SavedTuiDevice.normalizeMacAddress(macAddress);
    final devices = await load();
    for (final device in devices) {
      if (device.macAddress == normalized) return device;
    }
    return null;
  }

  @override
  Future<void> save(SavedTuiDevice device) {
    return _enqueue(() async {
      final byAddress = {
        for (final existing in await _loadNow()) existing.macAddress: existing,
      };
      byAddress[device.macAddress] = device;
      final devices = byAddress.values.toList()
        ..sort((left, right) => left.macAddress.compareTo(right.macAddress));
      await _writeNow(devices);
    });
  }

  @override
  Future<void> removeByMacAddress(String macAddress) {
    final normalized = SavedTuiDevice.normalizeMacAddress(macAddress);
    return _enqueue(() async {
      final devices = await _loadNow();
      await _writeNow(
        devices.where((device) => device.macAddress != normalized).toList(),
      );
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
      // A failed write must not make future reads impossible. The current
      // durable document, if any, is still the source of truth.
    }
  }

  Future<List<SavedTuiDevice>> _loadNow() async {
    try {
      final document = await _store.read();
      if (document == null) return const [];
      final decoded = jsonDecode(document);
      if (decoded is! List) return const [];

      final devices = <String, SavedTuiDevice>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        try {
          final device = SavedTuiDevice.fromJson(
            Map<String, Object?>.from(item),
          );
          devices[device.macAddress] = device;
        } on FormatException {
          // One stale record must not hide otherwise useful saved devices.
        }
      }
      final values = devices.values.toList()
        ..sort((left, right) => left.macAddress.compareTo(right.macAddress));
      return values;
    } on Object {
      // Corrupt non-secret history should not block the TUI from starting.
      return const [];
    }
  }

  Future<void> _writeNow(List<SavedTuiDevice> devices) {
    return _store
        .write(jsonEncode(devices.map((device) => device.toJson()).toList()));
  }
}
