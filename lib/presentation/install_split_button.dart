import 'package:flutter/material.dart';

import '../domain/install_task.dart';
import '../domain/install_preference_store.dart';

/// InstallPreference → InstallKind（both 无对应，调用方需先处理）。
extension InstallPreferenceKindX on InstallPreference {
  InstallKind toKind() => switch (this) {
        InstallPreference.quickApp => InstallKind.quickApp,
        _ => InstallKind.watchface,
      };
}

class InstallSplitButton extends StatefulWidget {
  const InstallSplitButton({
    required this.preferredTarget,
    required this.enabled,
    required this.onInstall,
    super.key,
  });

  final InstallPreference preferredTarget;
  final bool enabled;
  final Future<void> Function(InstallKind target) onInstall;

  @override
  State<InstallSplitButton> createState() => _InstallSplitButtonState();
}

class _InstallSplitButtonState extends State<InstallSplitButton> {
  bool _menuOpen = false;

  @override
  Widget build(BuildContext context) {
    if (widget.preferredTarget == InstallPreference.both) {
      return Row(
        children: [
          Expanded(child: _bothButton(InstallKind.watchface)),
          const SizedBox(width: 12),
          Expanded(child: _bothButton(InstallKind.quickApp)),
        ],
      );
    }
    final preferred =
        _InstallTargetPresentation(widget.preferredTarget.toKind());
    final alternate = _InstallTargetPresentation(preferred.alternate);

    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 56,
            child: FilledButton.icon(
              key: const ValueKey('preferred-install-button'),
              onPressed: widget.enabled
                  ? () => widget.onInstall(preferred.target)
                  : null,
              style: FilledButton.styleFrom(
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.horizontal(
                    left: Radius.circular(28),
                    right: Radius.circular(6),
                  ),
                ),
              ),
              icon: Icon(preferred.icon),
              label: Text(
                preferred.installLabel,
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ),
        ),
        const SizedBox(width: 2),
        SizedBox(
          width: 64,
          height: 56,
          child: PopupMenuButton<InstallKind>(
            tooltip: '选择另一种安装文件',
            padding: EdgeInsets.zero,
            offset: const Offset(0, 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            onOpened: () {
              if (mounted) {
                setState(() => _menuOpen = true);
              }
            },
            onCanceled: () {
              if (mounted) {
                setState(() => _menuOpen = false);
              }
            },
            onSelected: (target) async {
              if (mounted) {
                setState(() => _menuOpen = false);
              }
              await widget.onInstall(target);
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                key: const ValueKey('alternate-install-menu-item'),
                value: alternate.target,
                child: Row(
                  children: [
                    Icon(alternate.icon),
                    const SizedBox(width: 12),
                    Text(alternate.installLabel),
                  ],
                ),
              ),
            ],
            child: FilledButton(
              key: const ValueKey('install-menu-button'),
              // Selecting an alternate file type is useful before authentication.
              onPressed: null,
              style: FilledButton.styleFrom(
                disabledBackgroundColor: Theme.of(context).colorScheme.primary,
                disabledForegroundColor:
                    Theme.of(context).colorScheme.onPrimary,
                padding: EdgeInsets.zero,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.horizontal(
                    left: Radius.circular(6),
                    right: Radius.circular(28),
                  ),
                ),
              ),
              child: AnimatedRotation(
                key: const ValueKey('install-menu-chevron'),
                turns: _menuOpen ? 0.5 : 0,
                duration: const Duration(milliseconds: 180),
                child: const Icon(Icons.keyboard_arrow_down),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _bothButton(InstallKind target) {
    final presentation = _InstallTargetPresentation(target);
    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        onPressed: widget.enabled ? () => widget.onInstall(target) : null,
        icon: Icon(presentation.icon),
        label: Text(
          presentation.installLabel,
          style: const TextStyle(fontSize: 16),
        ),
      ),
    );
  }
}

class _InstallTargetPresentation {
  const _InstallTargetPresentation(this.target);

  final InstallKind target;

  InstallKind get alternate => target == InstallKind.watchface
      ? InstallKind.quickApp
      : InstallKind.watchface;

  IconData get icon =>
      target == InstallKind.watchface ? Icons.watch : Icons.apps;

  String get installLabel =>
      target == InstallKind.watchface ? '安装表盘 .bin' : '安装快应用 .rpk';
}
