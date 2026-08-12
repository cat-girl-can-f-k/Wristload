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
    final colors = Theme.of(context).colorScheme;
    final disabledBackground = colors.onSurface.withValues(alpha: 0.12);
    final disabledForeground = colors.onSurface.withValues(alpha: 0.38);

    return Row(
      children: [
        Expanded(
          child: _InstallSegment(
            key: const ValueKey('preferred-install-button'),
            enabled: widget.enabled,
            backgroundColor:
                widget.enabled ? colors.primary : disabledBackground,
            foregroundColor:
                widget.enabled ? colors.onPrimary : disabledForeground,
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(28),
              right: Radius.circular(6),
            ),
            onPressed: () => widget.onInstall(preferred.target),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(preferred.icon,
                    color:
                        widget.enabled ? colors.onPrimary : disabledForeground),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    preferred.installLabel,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 2),
        SizedBox(
          width: 64,
          height: 56,
          child: PopupMenuButton<InstallKind>(
            key: const ValueKey('install-menu-popup'),
            enabled: widget.enabled,
            tooltip: '选择另一种安装文件',
            padding: EdgeInsets.zero,
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(6),
              right: Radius.circular(28),
            ),
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
            child: _InstallSegment(
              key: const ValueKey('install-menu-button'),
              enabled: widget.enabled,
              backgroundColor:
                  widget.enabled ? colors.primary : disabledBackground,
              foregroundColor:
                  widget.enabled ? colors.onPrimary : disabledForeground,
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(6),
                right: Radius.circular(28),
              ),
              // PopupMenuButton owns pointer handling for this segment.
              onPressed: null,
              child: AnimatedRotation(
                key: const ValueKey('install-menu-chevron'),
                turns: _menuOpen ? 0.5 : 0,
                duration: const Duration(milliseconds: 180),
                child: Icon(
                  Icons.keyboard_arrow_down,
                  color: widget.enabled ? colors.onPrimary : disabledForeground,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _bothButton(InstallKind target) {
    final presentation = _InstallTargetPresentation(target);
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 56,
      child: FilledButton.icon(
        onPressed: widget.enabled ? () => widget.onInstall(target) : null,
        style: FilledButton.styleFrom(
          disabledBackgroundColor: colors.onSurface.withValues(alpha: 0.12),
          disabledForegroundColor: colors.onSurface.withValues(alpha: 0.38),
        ),
        icon: Icon(presentation.icon),
        label: Text(
          presentation.installLabel,
          style: const TextStyle(fontSize: 16),
        ),
      ),
    );
  }
}

class _InstallSegment extends StatelessWidget {
  const _InstallSegment({
    required this.enabled,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.borderRadius,
    required this.onPressed,
    required this.child,
    super.key,
  });

  final bool enabled;
  final Color backgroundColor;
  final Color foregroundColor;
  final BorderRadius borderRadius;
  final VoidCallback? onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final content = IconTheme.merge(
      data: IconThemeData(color: foregroundColor),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: foregroundColor),
        child: Center(child: child),
      ),
    );
    return Semantics(
      button: true,
      enabled: enabled,
      child: Material(
        key: const ValueKey('install-segment-material'),
        color: backgroundColor,
        borderRadius: borderRadius,
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 56,
          child: onPressed == null
              ? content
              : InkWell(
                  onTap: enabled ? onPressed : null,
                  child: content,
                ),
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
      target == InstallKind.watchface ? '安装表盘 .bin / .face' : '安装快应用 .rpk';
}
