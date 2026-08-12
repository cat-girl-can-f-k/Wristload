import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef InstallWarningRow = (String label, String value, bool highlight);

class InstallWarningDialog extends StatefulWidget {
  const InstallWarningDialog({
    required this.title,
    required this.message,
    required this.rows,
    required this.onConfirm,
    this.confirmLabel = '仍然安装',
    this.countdownSeconds = 3,
    super.key,
  });

  final String title;
  final String message;
  final List<InstallWarningRow> rows;
  final String confirmLabel;
  final int countdownSeconds;
  final VoidCallback onConfirm;

  @override
  State<InstallWarningDialog> createState() => _InstallWarningDialogState();
}

class _InstallWarningDialogState extends State<InstallWarningDialog> {
  Timer? _countdown;
  late int _secondsLeft;

  @override
  void initState() {
    super.initState();
    _secondsLeft = widget.countdownSeconds.clamp(0, 1 << 31).toInt();
    if (_secondsLeft > 0) {
      _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(
            () => _secondsLeft = (_secondsLeft - 1).clamp(0, 1 << 31).toInt());
        if (_secondsLeft == 0) timer.cancel();
      });
    }
  }

  @override
  void dispose() {
    _countdown?.cancel();
    super.dispose();
  }

  void _cancel() => Navigator.of(context).pop(false);

  void _confirm() {
    widget.onConfirm();
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final confirmEnabled = _secondsLeft == 0;
    final confirmLabel = confirmEnabled
        ? widget.confirmLabel
        : '${widget.confirmLabel}（$_secondsLeft）';

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): _DismissWarningIntent(),
      },
      child: Actions(
        actions: {
          _DismissWarningIntent: CallbackAction<_DismissWarningIntent>(
            onInvoke: (_) {
              _cancel();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: AlertDialog(
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  key: const ValueKey('install-warning-icon'),
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: colors.errorContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: colors.error,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  widget.title,
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  widget.message,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                Container(
                  key: const ValueKey('install-warning-evidence'),
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      for (final row in widget.rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  row.$1,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 16),
                              Flexible(
                                child: SelectableText(
                                  row.$2,
                                  textAlign: TextAlign.right,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontFamily: 'monospace',
                                    color: row.$3
                                        ? colors.error
                                        : colors.onSurface,
                                    fontWeight: row.$3 ? FontWeight.w600 : null,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: _cancel, child: const Text('取消')),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: colors.error,
                  foregroundColor: colors.onError,
                ),
                onPressed: confirmEnabled ? _confirm : null,
                child: Text(confirmLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DismissWarningIntent extends Intent {
  const _DismissWarningIntent();
}
