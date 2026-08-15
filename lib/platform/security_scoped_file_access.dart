/// macOS sandbox file access helpers.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../application/diagnostic_log_service.dart';

const int maxSecurityScopedBookmarkBytes = 64 * 1024;

/// A user-selected file path plus its macOS security-scoped bookmark.
///
/// The bookmark is intentionally opaque. It must never be logged.
class ScopedFileRef {
  const ScopedFileRef({required this.path, this.bookmark});

  final String path;
  final Uint8List? bookmark;

  bool get hasBookmark => bookmark != null && bookmark!.isNotEmpty;
}

/// A lease must be closed after every File API operation that needs a sandbox
/// extension. Non-macOS paths deliberately remain no-ops; macOS paths require
/// a bookmark so direct callers cannot bypass the sandbox-aware picker flow.
class SecurityScopedFileAccess {
  SecurityScopedFileAccess._();

  static final instance = SecurityScopedFileAccess._();
  static const _channel = MethodChannel('wristload/security_scope');

  Future<T> withAccess<T>(
    ScopedFileRef file,
    Future<T> Function(ScopedFileRef resolved) action,
  ) async {
    appLogger.trace(
      '安全作用域访问开始',
      category: DiagnosticLogCategory.security,
      fields: <String, Object?>{
        'platform': defaultTargetPlatform.name,
        'hasBookmark': file.hasBookmark,
      },
    );
    final lease = await acquire(file);
    var actionFailed = false;
    try {
      return await action(lease.file);
    } catch (error) {
      actionFailed = true;
      rethrow;
    } finally {
      try {
        await lease.close();
      } on Object catch (error, stackTrace) {
        // Preserve an action failure when both the operation and cleanup
        // fail. If the action succeeded, surface the cleanup failure.
        appLogger.error(
          '安全作用域释放失败',
          category: DiagnosticLogCategory.security,
          fields: <String, Object?>{'errorType': error.runtimeType.toString()},
        );
        if (!actionFailed) {
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
    }
  }

  Future<SecurityScopedFileLease> acquire(ScopedFileRef file) async {
    appLogger.trace(
      '安全作用域获取开始',
      category: DiagnosticLogCategory.security,
      fields: <String, Object?>{
        'platform': defaultTargetPlatform.name,
        'hasBookmark': file.hasBookmark,
        'bookmarkBytes': file.bookmark?.length ?? 0,
      },
    );
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      appLogger.debug(
        '非 macOS 安全作用域使用直通访问',
        category: DiagnosticLogCategory.security,
      );
      return SecurityScopedFileLease._(file, null);
    }
    if (!file.hasBookmark) {
      appLogger.warning(
        'macOS 安全作用域书签缺失',
        category: DiagnosticLogCategory.security,
      );
      throw StateError('macOS 文件访问需要安全作用域书签；请重新选择文件');
    }
    if (file.bookmark!.length > maxSecurityScopedBookmarkBytes) {
      throw ArgumentError.value(file.bookmark, 'bookmark', 'Bookmark is too large');
    }
    final result = await _channel.invokeMethod<Map<Object?, Object?>>(
      'startAccess',
      {'bookmark': file.bookmark},
    );
    if (result == null) {
      appLogger.error(
        'macOS 安全作用域返回空响应',
        category: DiagnosticLogCategory.security,
      );
      throw StateError('无法获得 macOS 文件访问权限');
    }
    final token = result['token'];
    final path = result['path'];
    if (result['started'] != true ||
        token is! String ||
        token.isEmpty ||
        path is! String ||
        path.isEmpty) {
      if (token is String && token.isNotEmpty) {
        await _stopBestEffort(token);
      }
      appLogger.error(
        'macOS 安全作用域启动失败',
        category: DiagnosticLogCategory.security,
        fields: <String, Object?>{
          'started': result['started'],
          'hasToken': token is String && token.isNotEmpty,
          'hasPath': path is String && path.isNotEmpty,
        },
      );
      throw StateError('无法获得 macOS 文件访问权限');
    }
    final replacement = result['bookmark'];
    if (replacement != null &&
        (replacement is! Uint8List ||
            replacement.isEmpty ||
            replacement.length > maxSecurityScopedBookmarkBytes)) {
      await _stopBestEffort(token);
      appLogger.error(
        'macOS 返回无效安全作用域书签',
        category: DiagnosticLogCategory.security,
        fields: <String, Object?>{
          'replacementType': replacement.runtimeType.toString(),
        },
      );
      throw StateError('macOS 返回了无效的文件书签');
    }
    appLogger.info(
      'macOS 安全作用域已获取',
      category: DiagnosticLogCategory.security,
      fields: <String, Object?>{
        'bookmarkRefreshed': replacement is Uint8List,
        'resolvedPath': _safeBasename(path),
      },
    );
    return SecurityScopedFileLease._(
      ScopedFileRef(
        path: path,
        bookmark: replacement is Uint8List ? replacement : file.bookmark,
      ),
      token,
    );
  }

  Future<void> _stop(String token) async {
    if (defaultTargetPlatform != TargetPlatform.macOS) return;
    appLogger.trace(
      'macOS 安全作用域释放开始',
      category: DiagnosticLogCategory.security,
    );
    await _channel.invokeMethod<void>('stopAccess', {'token': token});
    appLogger.debug(
      'macOS 安全作用域释放完成',
      category: DiagnosticLogCategory.security,
    );
  }

  Future<void> _stopBestEffort(String token) async {
    try {
      await _stop(token);
    } on Object catch (error) {
      appLogger.warning(
        'macOS 安全作用域回滚释放失败',
        category: DiagnosticLogCategory.security,
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      // Preserve the malformed native response as the primary failure.
    }
  }
}

class SecurityScopedFileLease {
  SecurityScopedFileLease._(this.file, this._token);

  final ScopedFileRef file;
  final String? _token;
  bool _closed = false;
  Future<void>? _closing;

  Future<void> close() async {
    if (_closed) {
      appLogger.trace(
        '安全作用域重复释放已忽略',
        category: DiagnosticLogCategory.security,
      );
      return;
    }
    final pending = _closing;
    if (pending != null) {
      await pending;
      return;
    }
    final operation = _closeOnce();
    _closing = operation;
    try {
      await operation;
    } finally {
      if (identical(_closing, operation)) _closing = null;
    }
  }

  Future<void> _closeOnce() async {
    final token = _token;
    if (token != null) await SecurityScopedFileAccess.instance._stop(token);
    _closed = true;
  }
}

String _safeBasename(String path) {
  final separator = path.lastIndexOf(RegExp(r'[/\\]'));
  return separator >= 0 ? path.substring(separator + 1) : path;
}
