import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/device_controller.dart';
import '../domain/install_models.dart';
import '../domain/install_task.dart';
import '../domain/watchface.dart';
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
      return (_incompatibleTargets(controller, request).isNotEmpty &&
              !request.watchfaceResolutionConfirmed) ||
          (_unsupportedLuaTargets(controller, request).isNotEmpty &&
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
      final incompatibleTargets = _incompatibleTargets(controller, request);
      if (incompatibleTargets.isNotEmpty && !resolutionConfirmed) {
        resolutionConfirmed = await _confirmWatchfaceResolution(
          context,
          controller,
          metadata,
          incompatibleTargets,
        );
        if (!resolutionConfirmed || !context.mounted) return null;
      }

      final luaTargets = _unsupportedLuaTargets(controller, request);
      if (luaTargets.isNotEmpty && !luaConfirmed) {
        luaConfirmed = await _confirmUnsupportedLua(
          context,
          controller,
          metadata,
          luaTargets,
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

    if (request.kind == InstallKind.watchface &&
        defaultTargetPlatform == TargetPlatform.macOS) {
      final confirmed = await _prepareWatchfaceReplacement(
        context,
        controller,
        request.copyWith(
          metadata: metadata,
          unsupportedLuaConfirmed: luaConfirmed,
          watchfaceResolutionConfirmed: resolutionConfirmed,
        ),
      );
      if (!confirmed || !context.mounted) return null;
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
      targetDeviceIds: request.targetDeviceIds,
    );
  }

  /// Uses each selected session's real device list after all local metadata
  /// decisions are settled. A local faceId edit must therefore be reflected in
  /// duplicate detection before any transfer control packet is sent.
  Future<bool> _prepareWatchfaceReplacement(
    BuildContext context,
    DeviceController controller,
    InstallRequest request,
  ) async {
    final faceId = request.metadata.faceId;
    if (faceId == null) return true;
    final conflicts = <_WatchfaceConflict>[];
    for (final target in _targets(controller, request)) {
      final session = _sessionForTarget(controller, target);
      if (session == null || !session.sessionReady) {
        throw StateError('目标设备“${target.name}”尚未完成鉴权，未开始覆盖安装');
      }
      final sessionEpoch = session.watchfaceSessionEpoch;
      final watchfaces = await session.refreshInstalledWatchfaces();
      if (!session.sessionReady ||
          session.watchfaceSessionEpoch != sessionEpoch) {
        throw StateError('目标设备“${target.name}”的连接已变更，未开始覆盖安装');
      }
      final readError = session.watchfacesError;
      if (readError != null) {
        throw StateError('无法读取“${target.name}”的表盘列表：$readError');
      }
      for (final watchface in watchfaces) {
        if (watchface.id.trim() == faceId.trim()) {
          conflicts.add(
            _WatchfaceConflict(
              target: target,
              session: session,
              sessionEpoch: sessionEpoch,
              watchface: watchface,
            ),
          );
          break;
        }
      }
    }
    if (conflicts.isEmpty) return true;

    final notRemovable = conflicts.where(
      (conflict) => !conflict.watchface.canRemove,
    );
    if (notRemovable.isNotEmpty) {
      final deviceNames = notRemovable
          .map((conflict) => conflict.target.name)
          .join('、');
      throw StateError('检测到同 ID 表盘，但 $deviceNames 中的旧表盘不可卸载；为避免覆盖失败，未发送新表盘。');
    }

    final approved = controller.forceWatchfaceInstall
        ? true
        : await _confirmWatchfaceReplacement(context, faceId, conflicts);
    if (!approved || !context.mounted) return false;

    // Deletions intentionally finish before the caller can start any new file
    // transfer. There is no protocol-level multi-device transaction, so a
    // failure stops the remaining sequence and reports that no new package was
    // sent to any target.
    for (final conflict in conflicts) {
      if (!conflict.session.sessionReady ||
          conflict.session.watchfaceSessionEpoch != conflict.sessionEpoch) {
        throw StateError('目标设备“${conflict.target.name}”的连接已变更，未开始上传新表盘');
      }
      final removed = await conflict.session.uninstallWatchface(
        conflict.watchface,
      );
      if (!removed) {
        final detail = conflict.session.watchfacesError ?? '设备未确认卸载';
        throw StateError(
          '“${conflict.target.name}”中的旧表盘卸载失败：$detail。未开始上传新表盘。',
        );
      }
    }
    return true;
  }

  DeviceController? _sessionForTarget(
    DeviceController controller,
    ResourceInstallDevice target,
  ) => target.id == 'primary'
      ? controller
      : controller.sessionForDeviceId(target.id);

  Future<bool> _confirmWatchfaceReplacement(
    BuildContext context,
    String faceId,
    List<_WatchfaceConflict> conflicts,
  ) async {
    final devices = conflicts.map((conflict) => conflict.target.name).join('、');
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.warning_amber_rounded),
            title: const Text('检测到同 ID 表盘'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('设备中已存在 ID 为 $faceId 的表盘。'),
                const SizedBox(height: 8),
                Text('目标设备：$devices'),
                const SizedBox(height: 12),
                const Text('覆盖安装会先卸载旧表盘，再上传并安装新表盘。'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('覆盖安装'),
              ),
            ],
          ),
        ) ??
        false;
  }

  List<ResourceInstallDevice> _targets(
    DeviceController controller,
    InstallRequest request,
  ) {
    final connected = controller.resourceInstallDevices;
    if (request.targetDeviceIds.isEmpty) {
      if (connected.isNotEmpty) {
        return <ResourceInstallDevice>[connected.first];
      }
      // Requests created before targetDeviceIds existed may only expose the
      // legacy primary profile. Keep its warning behavior intact.
      if (controller.connectedProfile != null) {
        return <ResourceInstallDevice>[
          ResourceInstallDevice(
            id: 'primary',
            name:
                (controller.connectedDeviceName ??
                        controller.connectedProfile?.displayName ??
                        '已连接设备')
                    .trim(),
          ),
        ];
      }
      return const <ResourceInstallDevice>[];
    }
    final byId = <String, ResourceInstallDevice>{
      for (final target in connected) target.id.trim().toLowerCase(): target,
    };
    final targets = <ResourceInstallDevice>[];
    final seen = <String>{};
    for (final rawId in request.targetDeviceIds) {
      final id = rawId.trim().toLowerCase();
      if (id.isEmpty || !seen.add(id)) continue;
      final target = byId[id];
      if (target != null) targets.add(target);
    }
    return targets;
  }

  List<ResourceInstallDevice> _incompatibleTargets(
    DeviceController controller,
    InstallRequest request,
  ) {
    final targets = _targets(controller, request);
    if (request.targetDeviceIds.isEmpty) {
      return controller.watchfaceCompatibilityError(request.metadata) == null
          ? const <ResourceInstallDevice>[]
          : targets;
    }
    return <ResourceInstallDevice>[
      for (final target in targets)
        if (controller.watchfaceCompatibilityErrorForDevice(
              request.metadata,
              target.id,
            ) !=
            null)
          target,
    ];
  }

  List<ResourceInstallDevice> _unsupportedLuaTargets(
    DeviceController controller,
    InstallRequest request,
  ) {
    final targets = _targets(controller, request);
    if (request.targetDeviceIds.isEmpty) {
      return controller.requiresUnsupportedLuaConfirmation(request.metadata)
          ? targets
          : const <ResourceInstallDevice>[];
    }
    return <ResourceInstallDevice>[
      for (final target in targets)
        if (controller.requiresUnsupportedLuaConfirmationForDevice(
          request.metadata,
          target.id,
        ))
          target,
    ];
  }

  Future<bool> _confirmWatchfaceResolution(
    BuildContext context,
    DeviceController controller,
    InstallMetadata metadata,
    List<ResourceInstallDevice> targets,
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
            targets
                .map(
                  (target) =>
                      target.name +
                      '：' +
                      _targetResolution(controller, target.id),
                )
                .join('、'),
            true,
          ),
          ('文件名', metadata.fileName, false),
        ],
        onConfirm: () => confirmed = true,
      ),
    );
    return confirmed;
  }

  String _targetResolution(DeviceController controller, String deviceId) {
    final profile = deviceId == 'primary'
        ? controller.connectedProfile
        : controller.sessionForDeviceId(deviceId)?.connectedProfile;
    return profile?.watchfaceResolution?.toString() ?? '未知';
  }

  Future<bool> _confirmUnsupportedLua(
    BuildContext context,
    DeviceController controller,
    InstallMetadata metadata,
    List<ResourceInstallDevice> targets,
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
          ('目标设备', targets.map((target) => target.name).join('、'), false),
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

class _WatchfaceConflict {
  const _WatchfaceConflict({
    required this.target,
    required this.session,
    required this.sessionEpoch,
    required this.watchface,
  });

  final ResourceInstallDevice target;
  final DeviceController session;
  final int sessionEpoch;
  final WatchfaceItem watchface;
}
