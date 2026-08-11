/// authkey 的平台安全存储边界。
/// Windows 使用 DPAPI，Android 使用 Android Keystore；不会降级为普通文本文件。
library;

import 'dart:io';

import 'package:flutter/services.dart';

class AuthKeyStore {
  static const _channel = MethodChannel('miwearable/secure_store');

  Future<String?> read() {
    if (!_supported) return Future.value(null);
    return _channel.invokeMethod<String>('read');
  }

  Future<void> write(String value) async {
    if (!_supported) return;
    await _channel.invokeMethod<void>('write', value);
  }

  Future<void> delete() async {
    if (!_supported) return;
    await _channel.invokeMethod<void>('delete');
  }

  bool get _supported => Platform.isWindows || Platform.isAndroid;
}
