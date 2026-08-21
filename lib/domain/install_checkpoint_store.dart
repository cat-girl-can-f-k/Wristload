/// 单一安装检查点的持久化。
///
/// 这是唯一允许落盘的安装状态：不含 authkey、会话密钥或文件副本。每次写入
/// 使用同目录临时文件再替换，避免设备重启或进程终止时留下半份 JSON。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'install_models.dart';
import '../application/diagnostic_log_service.dart';

class InstallCheckpointStore {
  static const _fileName = 'active_install_checkpoint.json';

  /// Creates a checkpoint store for one authenticated device session.
  ///
  /// The original no-argument form intentionally keeps its historical file
  /// name for the primary session. Secondary macOS sessions receive a scoped
  /// file so simultaneous installations cannot overwrite each other's resume
  /// state.
  InstallCheckpointStore({String? scope}) : _scope = _normalizeScope(scope);

  final String? _scope;

  static String? _normalizeScope(String? value) {
    final trimmed = value?.trim().toLowerCase();
    if (trimmed == null || trimmed.isEmpty) return null;
    final normalized = trimmed.replaceAll(RegExp(r'[^a-z0-9_-]'), '_');
    return normalized.isEmpty ? null : normalized;
  }

  String get _scopedFileName =>
      _scope == null ? _fileName : 'active_install_checkpoint_$_scope.json';

  Future<File> _target() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}$_scopedFileName');
  }

  Future<void> save(InstallCheckpoint checkpoint) async {
    appLogger.trace(
      '安装检查点保存开始',
      category: DiagnosticLogCategory.storage,
      fields: <String, Object?>{
        'kind': checkpoint.kind.name,
        'phase': checkpoint.phase,
        'lastAcknowledgedSegment': checkpoint.lastAcknowledgedSegment,
        'hasBookmark': checkpoint.bookmark?.isNotEmpty == true,
      },
    );
    final target = await _target();
    final temporary = File('${target.path}.new');
    final backup = File('${target.path}.bak');
    await temporary.writeAsString(jsonEncode(checkpoint.toJson()), flush: true);
    if (await backup.exists()) await backup.delete();
    if (await target.exists()) await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
      if (await backup.exists()) await backup.delete();
      appLogger.info(
        '安装检查点保存完成',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{
          'kind': checkpoint.kind.name,
          'phase': checkpoint.phase,
        },
      );
    } on Object {
      // Windows cannot atomically replace an existing file. Keep the previous
      // valid checkpoint recoverable if the second rename fails or the process
      // is interrupted between the two renames.
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      appLogger.error(
        '安装检查点保存失败',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{'errorType': 'rename'},
      );
      rethrow;
    }
  }

  Future<InstallCheckpoint?> load() async {
    appLogger.trace('安装检查点读取开始', category: DiagnosticLogCategory.storage);
    try {
      var target = await _target();
      if (!await target.exists()) {
        final backup = File('${target.path}.bak');
        if (!await backup.exists()) {
          appLogger.debug('未找到安装检查点', category: DiagnosticLogCategory.storage);
          return null;
        }
        await backup.rename(target.path);
        target = File(target.path);
      }
      final value = jsonDecode(await target.readAsString());
      if (value is! Map) {
        appLogger.warning(
          '安装检查点 JSON 格式无效',
          category: DiagnosticLogCategory.storage,
        );
        return null;
      }
      final checkpoint = InstallCheckpoint.fromJson(
        Map<String, Object?>.from(value),
      );
      appLogger.info(
        checkpoint == null ? '安装检查点校验失败' : '安装检查点读取完成',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{'valid': checkpoint != null},
      );
      return checkpoint;
    } on Object catch (error) {
      // 损坏的检查点不会阻止正常连接，也不应被当作可恢复安装。
      appLogger.error(
        '安装检查点读取失败：$error',
        category: DiagnosticLogCategory.storage,
        fields: <String, Object?>{'errorType': error.runtimeType.toString()},
      );
      return null;
    }
  }

  Future<void> clear() async {
    appLogger.trace('安装检查点清理开始', category: DiagnosticLogCategory.storage);
    final target = await _target();
    if (await target.exists()) await target.delete();
    final temporary = File('${target.path}.new');
    if (await temporary.exists()) await temporary.delete();
    final backup = File('${target.path}.bak');
    if (await backup.exists()) await backup.delete();
    appLogger.info('安装检查点清理完成', category: DiagnosticLogCategory.storage);
  }
}
