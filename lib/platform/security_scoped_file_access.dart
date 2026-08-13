/// macOS sandbox file access helpers.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
        if (!actionFailed) {
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
    }
  }

  Future<SecurityScopedFileLease> acquire(ScopedFileRef file) async {
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      return SecurityScopedFileLease._(file, null);
    }
    if (!file.hasBookmark) {
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
      throw StateError('无法获得 macOS 文件访问权限');
    }
    final token = result?['token'];
    final path = result?['path'];
    if (result?['started'] != true ||
        token is! String ||
        token.isEmpty ||
        path is! String ||
        path.isEmpty) {
      if (token is String && token.isNotEmpty) {
        await _stopBestEffort(token);
      }
      throw StateError('无法获得 macOS 文件访问权限');
    }
    final replacement = result['bookmark'];
    if (replacement != null &&
        (replacement is! Uint8List ||
            replacement.isEmpty ||
            replacement.length > maxSecurityScopedBookmarkBytes)) {
      await _stopBestEffort(token);
      throw StateError('macOS 返回了无效的文件书签');
    }
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
    await _channel.invokeMethod<void>('stopAccess', {'token': token});
  }

  Future<void> _stopBestEffort(String token) async {
    try {
      await _stop(token);
    } on Object {
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
    if (_closed) return;
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
