import 'package:flutter/material.dart';

import '../domain/install_preference_store.dart';

class OobeInstallPreview extends StatelessWidget {
  const OobeInstallPreview({required this.preference, super.key});

  final InstallPreference preference;

  static const _duration = Duration(milliseconds: 500);
  static const _curve = Curves.easeInOutCubicEmphasized;

  void _showDemo(BuildContext context, String action) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$action（预览）')));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('oobe-install-preview'),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.all(20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final both = preference == InstallPreference.both;
          return TweenAnimationBuilder<double>(
            tween: Tween(end: both ? 1 : 0),
            duration: _duration,
            curve: _curve,
            builder: (context, expansion, _) {
              const menuWidth = 56.0;
              const splitGap = 2.0;
              const bothGap = 10.0;
              final fullWidth = constraints.maxWidth;
              final rightGroupWidth = (fullWidth - bothGap) / 2;
              final expandedSecondWidth =
                  (rightGroupWidth - menuWidth - splitGap)
                      .clamp(0.0, fullWidth);
              final secondWidth = expandedSecondWidth * expansion;
              // The normal split button only has the menu seam. The wider gap
              // is introduced exclusively while the quick-app button expands.
              final groupGap = bothGap * expansion;
              final mainWidth =
                  (fullWidth - menuWidth - splitGap - groupGap - secondWidth)
                      .clamp(0.0, fullWidth);

              return Row(
                children: [
                  SizedBox(
                    key: const ValueKey('oobe-primary-segment'),
                    width: mainWidth,
                    child: _PreviewSegment(
                      radius: BorderRadius.lerp(
                        const BorderRadius.horizontal(
                          left: Radius.circular(27),
                          right: Radius.circular(8),
                        ),
                        BorderRadius.circular(27),
                        expansion,
                      )!,
                      onTap: () => _showDemo(
                        context,
                        both ? '安装表盘' : _primaryLabel,
                      ),
                      child: _AnimatedInstallLabel(
                        preference:
                            both ? InstallPreference.watchface : preference,
                        compactWatchface: both,
                      ),
                    ),
                  ),
                  SizedBox(width: groupGap),
                  IgnorePointer(
                    key: const ValueKey('oobe-secondary-hit-region'),
                    ignoring: !both,
                    child: Opacity(
                      opacity: expansion,
                      child: SizedBox(
                        key: const ValueKey('oobe-secondary-segment'),
                        width: secondWidth,
                        child: _PreviewSegment(
                          radius: const BorderRadius.horizontal(
                            left: Radius.circular(27),
                            right: Radius.circular(8),
                          ),
                          onTap: () => _showDemo(context, '安装快应用 .rpk'),
                          child: const _AnimatedInstallLabel(
                            preference: InstallPreference.quickApp,
                            compactWatchface: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: splitGap),
                  _PreviewMenu(
                    preference: preference,
                    both: both,
                    width: menuWidth,
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  String get _primaryLabel => preference == InstallPreference.quickApp
      ? '安装快应用 .rpk'
      : '安装表盘 .bin / .face';
}

class _AnimatedInstallLabel extends StatelessWidget {
  const _AnimatedInstallLabel({
    required this.preference,
    required this.compactWatchface,
  });

  final InstallPreference preference;
  final bool compactWatchface;

  @override
  Widget build(BuildContext context) {
    final quickApp = preference == InstallPreference.quickApp;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      transitionBuilder: (child, animation) {
        final direction = quickApp ? 1.0 : -1.0;
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(direction * .05, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        );
      },
      child: Row(
        // Do not animate the watchface label when switching watchface -> both:
        // that transition changes structure, rather than the selected type.
        key: ValueKey(preference.name),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(quickApp ? Icons.apps : Icons.watch),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              quickApp
                  ? '安装快应用 .rpk'
                  : compactWatchface
                      ? '安装表盘'
                      : '安装表盘 .bin / .face',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewMenu extends StatelessWidget {
  const _PreviewMenu({
    required this.preference,
    required this.both,
    required this.width,
  });

  final InstallPreference preference;
  final bool both;
  final double width;

  void _showDemo(BuildContext context, String action) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$action（预览）')));
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      alignmentOffset: const Offset(0, 8),
      style: MenuStyle(
        alignment: AlignmentDirectional.bottomEnd,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      menuChildren: [
        if (!both)
          MenuItemButton(
            leadingIcon: Icon(_alternateIcon),
            onPressed: () => _showDemo(context, _alternateLabel),
            child: Text(_alternateLabel),
          ),
        MenuItemButton(
          key: const ValueKey('oobe-firmware-menu-item'),
          leadingIcon: const Icon(Icons.system_update_alt),
          onPressed: () => _showDemo(context, '安装固件'),
          child: Text(
            both ? '安装固件（协议取证中）' : '安装固件 .zip / .bin（协议取证中）',
          ),
        ),
      ],
      builder: (context, controller, _) => SizedBox(
        key: const ValueKey('oobe-menu-segment'),
        width: width,
        child: _PreviewSegment(
          radius: const BorderRadius.horizontal(
            left: Radius.circular(8),
            right: Radius.circular(27),
          ),
          onTap: controller.isOpen ? controller.close : controller.open,
          child: AnimatedRotation(
            turns: controller.isOpen ? .5 : 0,
            duration: const Duration(milliseconds: 180),
            child: const Icon(Icons.keyboard_arrow_down),
          ),
        ),
      ),
    );
  }

  bool get _quickAppPreferred => preference == InstallPreference.quickApp;

  IconData get _alternateIcon => _quickAppPreferred ? Icons.watch : Icons.apps;

  String get _alternateLabel =>
      _quickAppPreferred ? '安装表盘 .bin / .face' : '安装快应用 .rpk';
}

class _PreviewSegment extends StatelessWidget {
  const _PreviewSegment({
    required this.radius,
    required this.onTap,
    required this.child,
  });

  final BorderRadius radius;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.primaryContainer,
      borderRadius: radius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(height: 54, child: Center(child: child)),
      ),
    );
  }
}
