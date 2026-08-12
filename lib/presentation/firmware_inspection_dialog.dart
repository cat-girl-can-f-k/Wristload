import 'package:flutter/material.dart';

import '../domain/firmware_package_inspector.dart';

class FirmwareInspectionDialog extends StatelessWidget {
  const FirmwareInspectionDialog({required this.inspection, super.key});

  final FirmwarePackageInspection inspection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final valid = inspection.packageStructureValid;

    return AlertDialog(
      icon: Icon(
        valid ? Icons.fact_check_outlined : Icons.warning_amber_rounded,
        color: valid ? colors.primary : colors.error,
      ),
      title: Text(valid ? '固件包检查完成' : '固件包存在问题'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _InspectionRows(inspection: inspection),
              if (inspection.errors.isNotEmpty) ...[
                const SizedBox(height: 12),
                _MessagePanel(
                  icon: Icons.error_outline,
                  messages: inspection.errors,
                  background: colors.errorContainer,
                  foreground: colors.onErrorContainer,
                ),
              ],
              if (inspection.warnings.isNotEmpty) ...[
                const SizedBox(height: 12),
                _MessagePanel(
                  icon: Icons.info_outline,
                  messages: inspection.warnings,
                  background: colors.surfaceContainerHigh,
                  foreground: colors.onSurfaceVariant,
                ),
              ],
              const SizedBox(height: 12),
              Container(
                key: const ValueKey('firmware-no-transfer-notice'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 20,
                      color: colors.onPrimaryContainer,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '本次仅在本地读取固件包结构，未向设备发送任何数据。'
                        'OTA 通道 6 的控制帧与确认流程完成真机取证前，固件传输保持关闭。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class FirmwareInspectionErrorDialog extends StatelessWidget {
  const FirmwareInspectionErrorDialog({
    required this.fileName,
    required this.message,
    super.key,
  });

  final String fileName;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.error_outline, color: colors.error),
      title: const Text('无法读取固件包'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              fileName,
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            Text(message, style: TextStyle(color: colors.error)),
            const SizedBox(height: 12),
            Text(
              '未向设备发送任何数据。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _InspectionRows extends StatelessWidget {
  const _InspectionRows({required this.inspection});

  final FirmwarePackageInspection inspection;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('文件', inspection.fileName),
      ('文件大小', _formatBytes(inspection.fileSize)),
      ('清单', inspection.manifestName ?? '未找到'),
      ('目标标识', inspection.target ?? '未提供'),
      ('软件版本', inspection.softwareVersion ?? '未提供'),
      ('固件类型', inspection.firmwareType ?? '未提供'),
      ('分区文件', '${inspection.partitionFiles.length} 项'),
      ('ZIP 条目', '${inspection.entryCount} 项'),
      (
        '签名材料',
        inspection.hasSignatureMaterial
            ? '${inspection.signatureFiles.length} 项（未验证）'
            : '未发现',
      ),
    ];
    final colors = Theme.of(context).colorScheme;

    return Container(
      key: const ValueKey('firmware-inspection-rows'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      row.$1,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SelectableText(
                      row.$2,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({
    required this.icon,
    required this.messages,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final List<String> messages;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: foreground),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                messages.join('\n'),
                style: TextStyle(color: foreground),
              ),
            ),
          ],
        ),
      );
}

String _formatBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}
