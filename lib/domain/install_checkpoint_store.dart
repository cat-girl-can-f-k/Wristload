/// 单一安装检查点的持久化。
///
/// 这是唯一允许落盘的安装状态：不含 authkey、会话密钥或文件副本。每次写入
/// 使用同目录临时文件再替换，避免设备重启或进程终止时留下半份 JSON。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'install_models.dart';

class InstallCheckpointStore {
  static const _fileName = 'active_install_checkpoint.json';

  Future<File> _target() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}$_fileName');
  }

  Future<void> save(InstallCheckpoint checkpoint) async {
    final target = await _target();
    final temporary = File('${target.path}.new');
    final backup = File('${target.path}.bak');
    await temporary.writeAsString(jsonEncode(checkpoint.toJson()), flush: true);
    if (await backup.exists()) await backup.delete();
    if (await target.exists()) await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
      if (await backup.exists()) await backup.delete();
    } on Object {
      // Windows cannot atomically replace an existing file. Keep the previous
      // valid checkpoint recoverable if the second rename fails or the process
      // is interrupted between the two renames.
      if (!await target.exists() && await backup.exists()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }

  Future<InstallCheckpoint?> load() async {
    try {
      var target = await _target();
      if (!await target.exists()) {
        final backup = File('${target.path}.bak');
        if (!await backup.exists()) return null;
        await backup.rename(target.path);
        target = File(target.path);
      }
      final value = jsonDecode(await target.readAsString());
      if (value is! Map) return null;
      return InstallCheckpoint.fromJson(Map<String, Object?>.from(value));
    } on Object {
      // 损坏的检查点不会阻止正常连接，也不应被当作可恢复安装。
      return null;
    }
  }

  Future<void> clear() async {
    final target = await _target();
    if (await target.exists()) await target.delete();
    final temporary = File('${target.path}.new');
    if (await temporary.exists()) await temporary.delete();
    final backup = File('${target.path}.bak');
    if (await backup.exists()) await backup.delete();
  }
}
