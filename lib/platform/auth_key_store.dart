/// authkey 的平台安全存储边界。
/// Windows 使用 DPAPI，Android 使用 Android Keystore，macOS 使用 Keychain；
/// 不会降级为普通文本文件。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AuthKeyStore {
  static const _channel = MethodChannel('wristload/secure_store');

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

  bool get _supported => switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.android ||
        TargetPlatform.macOS =>
          true,
        _ => false,
      };
}
