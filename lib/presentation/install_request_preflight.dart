import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/device_controller.dart';
import '../domain/install_models.dart';
import '../domain/install_task.dart';
import 'install_warning_dialog.dart';

/// Collects every user decision required before an installation may start.
///
/// Queue and floating-window imports use the same checks as the home page, so
/// a request that needs confirmation stays waiting instead of being counted as
/// a failed transfer.
class InstallRequestPreflight {
  const InstallRequestPreflight();

  bool requiresInteraction(
    DeviceController controller,
    InstallRequest request, {
    bool reviewWatchfaceId = false,
  }) {
    final metadata = request.metadata;
    if (request.kind == InstallKind.watchface) {
      return (controller.watchfaceCompatibilityError(metadata) != null &&
              !request.watchfaceResolutionConfirmed) ||
          (controller.requiresUnsupportedLuaConfirmation(metadata) &&
              !request.unsupportedLuaConfirmed) ||
          reviewWatchfaceId ||
          !_validFaceId(metadata.faceId);
    }
    return !_validRpkVersion(metadata.versionCode);
  }

  Future<InstallRequest?> prepare(
    BuildContext context,
    DeviceController controller,
    InstallRequest request, {
    bool reviewWatchfaceId = false,
  }) async {
    var metadata = request.metadata;
    var resolutionConfirmed = request.watchfaceResolutionConfirmed;
    var luaConfirmed = request.unsupportedLuaConfirmed;

    if (request.kind == InstallKind.watchface) {
      if (controller.watchfaceCompatibilityError(metadata) != null &&
          !resolutionConfirmed) {
        resolutionConfirmed = await _confirmWatchfaceResolution(
          context,
          controller,
          metadata,
        );
        if (!resolutionConfirmed || !context.mounted) return null;
      }

      if (controller.requiresUnsupportedLuaConfirmation(metadata) &&
          !luaConfirmed) {
        luaConfirmed = await _confirmUnsupportedLua(
          context,
          controller,
          metadata,
        );
        if (!luaConfirmed || !context.mounted) return null;
      }

      if (reviewWatchfaceId || !_validFaceId(metadata.faceId)) {
        final edited = await _editFaceId(context, metadata);
        if (edited == null || !context.mounted) return null;
        metadata = edited;
      }
    } else {
      if (metadata.packageName == null || metadata.packageName!.isEmpty) {
        throw const FormatException('RPK 清单未包含有效包名，已拒绝安装');
      }
      if (!_validRpkVersion(metadata.versionCode)) {
        final edited = await _editRpkVersion(context, metadata);
        if (edited == null || !context.mounted) return null;
        metadata = edited;
      }
    }

    if (request.kind == InstallKind.watchface &&
        !_validFaceId(metadata.faceId)) {
      throw const FormatException('faceId 必须为数值型 ID');
    }
    if (request.kind == InstallKind.quickApp &&
        !_validRpkVersion(metadata.versionCode)) {
      throw const FormatException('RPK 版本号必须为有效 32 位正整数');
    }

    if (identical(metadata, request.metadata) &&
        resolutionConfirmed == request.watchfaceResolutionConfirmed &&
        luaConfirmed == request.unsupportedLuaConfirmed) {
      return request;
    }
    return InstallRequest(
      kind: request.kind,
      path: request.path,
      metadata: metadata,
      source: request.source,
      unsupportedLuaConfirmed: luaConfirmed,
      watchfaceResolutionConfirmed: resolutionConfirmed,
    );
  }

  Future<bool> _confirmWatchfaceResolution(
    BuildContext context,
    DeviceController controller,
    InstallMetadata metadata,
  ) async {
    var confirmed = false;
    final resolutions = metadata.watchfaceResolutions.isEmpty
        ? '未识别'
        : metadata.watchfaceResolutions.join('、');
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InstallWarningDialog(
        title: '表盘分辨率不匹配',
        message: '安装后可能无法正常显示或使用',
        rows: [
          ('表盘分辨率', resolutions, false),
          (
            '设备分辨率',
            controller.connectedProfile?.watchfaceResolution?.toString() ??
                '未知',
            true,
          ),
          ('文件名', metadata.fileName, false),
        ],
        onConfirm: () => confirmed = true,
      ),
    );
    return confirmed;
  }

  Future<bool> _confirmUnsupportedLua(
    BuildContext context,
    DeviceController controller,
    InstallMetadata metadata,
  ) async {
    var confirmed = false;
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InstallWarningDialog(
        title: 'Lua 不被支持',
        message: '安装后可能无法正常显示或使用',
        rows: [
          ('文件名', metadata.fileName, false),
          ('检测结果', '检测到lua文件', true),
          ('目标设备', controller.connectedProfile?.displayName ?? '未知设备', false),
        ],
        onConfirm: () => confirmed = true,
      ),
    );
    return confirmed;
  }

  Future<InstallMetadata?> _editFaceId(
    BuildContext context,
    InstallMetadata metadata,
  ) async {
    // Let TextFormField own its controller until the dialog route is actually
    // disposed. Disposing a caller-owned controller after showDialog returns
    // races the reverse route animation on desktop Flutter.
    var faceId = metadata.faceId ?? '';
    final formKey = GlobalKey<FormState>();
    return showDialog<InstallMetadata>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('表盘 faceId'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: faceId,
            onChanged: (value) => faceId = value,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: '从表盘资源解析，可按需编辑',
              border: OutlineInputBorder(),
            ),
            validator: (value) => _validFaceId(value) ? null : 'faceId 必须是非空数值',
            onFieldSubmitted: (value) {
              faceId = value;
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(faceId: faceId.trim()),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(faceId: faceId.trim()),
              );
            },
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  Future<InstallMetadata?> _editRpkVersion(
    BuildContext context,
    InstallMetadata metadata,
  ) async {
    var versionText = metadata.versionCode?.toString() ?? '';
    final formKey = GlobalKey<FormState>();
    return showDialog<InstallMetadata>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('RPK 版本号'),
        content: Form(
          key: formKey,
          child: TextFormField(
            initialValue: versionText,
            onChanged: (value) => versionText = value,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: '包名：${metadata.packageName}',
              helperText: '包名必须来自 RPK 清单，不能手动修改。',
              border: const OutlineInputBorder(),
            ),
            validator: (value) {
              final version = int.tryParse(value?.trim() ?? '');
              return _validRpkVersion(version)
                  ? null
                  : '请输入 1–$maxRpkVersionCode';
            },
            onFieldSubmitted: (value) {
              versionText = value;
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(versionCode: int.parse(versionText.trim())),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!formKey.currentState!.validate()) return;
              Navigator.pop(
                dialogContext,
                metadata.copyWith(versionCode: int.parse(versionText.trim())),
              );
            },
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  static bool _validFaceId(String? value) =>
      RegExp(r'^\d+$').hasMatch(value ?? '');

  static bool _validRpkVersion(int? value) =>
      value != null && value > 0 && value <= maxRpkVersionCode;
}
