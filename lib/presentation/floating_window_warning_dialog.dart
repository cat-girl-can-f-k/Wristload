import 'package:flutter/material.dart';

/// 开启悬浮安装窗前的确认提示。
/// 视觉规范与「设备无响应」系列弹窗（connection_warning_dialog.dart）一致：
/// 圆形 errorContainer 警告图标 + 居中标题 + 居中正文 +
/// barrierDismissible: false + TextButton/FilledButton。
Future<bool?> showFloatingWindowEnableWarning(BuildContext context) =>
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _FloatingWindowEnableWarningDialog(),
    );

class _FloatingWindowEnableWarningDialog extends StatelessWidget {
  const _FloatingWindowEnableWarningDialog();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.warning_amber_rounded,
            size: 28, color: scheme.error),
      ),
      title: const Text('开启悬浮窗会导致软件内无法输入',
          textAlign: TextAlign.center),
      content: const Text(
        '确认开启吗',
        textAlign: TextAlign.center,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('确认'),
        ),
      ],
    );
  }
}
