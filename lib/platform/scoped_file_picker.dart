library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'security_scoped_file_access.dart';

class ScopedFilePicker {
  static const _channel = MethodChannel('wristload/security_scope');

  static Future<List<ScopedFileRef>?> pickFiles({
    required List<String> allowedExtensions,
    bool allowMultiple = false,
    bool withData = false,
  }) async {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final values = await _channel.invokeMethod<List<dynamic>>('pickFiles', {
        'allowedExtensions': allowedExtensions,
        'allowMultiple': allowMultiple,
      });
      if (values == null) return null;
      final files = <ScopedFileRef>[];
      for (final value in values) {
        if (value is! Map || value['path'] is! String) {
          throw const FormatException('macOS returned an invalid selected file');
        }
        final bookmark = value['bookmark'];
        if (bookmark is! Uint8List ||
            bookmark.isEmpty ||
            bookmark.length > maxSecurityScopedBookmarkBytes) {
          throw const FormatException('macOS did not return a valid file bookmark');
        }
        files.add(ScopedFileRef(
          path: value['path'] as String,
          bookmark: bookmark,
        ));
      }
      return files;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      allowMultiple: allowMultiple,
      withData: withData,
    );
    if (result == null) return null;
    return result.files
        .where((file) => file.path != null)
        .map((file) => ScopedFileRef(path: file.path!))
        .toList();
  }
}
