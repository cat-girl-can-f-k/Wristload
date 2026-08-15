/// authkey 的平台安全存储边界。
/// Windows 使用 DPAPI，Android 使用 Android Keystore，macOS 使用 Keychain；
/// 不会降级为普通文本文件。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../application/diagnostic_log_service.dart';

class AuthKeyStore {
  static const _channel = MethodChannel('wristload/secure_store');

  Future<String?> read() {
    if (!_supported) {
      appLogger.debug('安全存储读取跳过：平台不支持', category: DiagnosticLogCategory.security);
      return Future.value(null);
    }
    appLogger.trace('安全存储读取开始', category: DiagnosticLogCategory.security);
    return _channel.invokeMethod<String>('read').then((value) {
      appLogger.debug('安全存储读取完成', category: DiagnosticLogCategory.security, fields: <String, Object?>{'hasValue': value != null});
      return value;
    }, onError: (Object error, StackTrace stackTrace) {
      appLogger.error('安全存储读取失败：$error', category: DiagnosticLogCategory.security, fields: <String, Object?>{'errorType': error.runtimeType.toString()});
      Error.throwWithStackTrace(error, stackTrace);
    });
  }

  Future<void> write(String value) async {
    if (!_supported) return;
    appLogger.trace('安全存储写入开始', category: DiagnosticLogCategory.security, fields: <String, Object?>{'bytes': value.length});
    await _channel.invokeMethod<void>('write', value);
    appLogger.info('安全存储写入完成', category: DiagnosticLogCategory.security);
  }

  Future<void> delete() async {
    if (!_supported) return;
    appLogger.trace('安全存储删除开始', category: DiagnosticLogCategory.security);
    await _channel.invokeMethod<void>('delete');
    appLogger.info('安全存储删除完成', category: DiagnosticLogCategory.security);
  }

  Future<String?> readFor(String id) {
    if (!_supported) return Future.value(null);
    return _channel.invokeMethod<String>('readFor', id);
  }

  Future<void> writeFor(String id, String value) async {
    if (!_supported) return;
    await _channel.invokeMethod<void>('writeFor', <String, String>{
      'id': id,
      'value': value,
    });
  }

  Future<void> deleteFor(String id) async {
    if (!_supported) return;
    await _channel.invokeMethod<void>('deleteFor', id);
  }

  bool get _supported => switch (defaultTargetPlatform) {
        TargetPlatform.windows ||
        TargetPlatform.android ||
        TargetPlatform.macOS =>
          true,
        _ => false,
      };
}
