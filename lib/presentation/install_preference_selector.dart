import 'package:flutter/material.dart';

import '../domain/install_preference_store.dart';

/// Shared install-preference control used by Settings and OOBE.
class InstallPreferenceSelector extends StatelessWidget {
  const InstallPreferenceSelector({
    required this.value,
    required this.onChanged,
    this.titleStyle,
    super.key,
  });

  final InstallPreference value;
  final ValueChanged<InstallPreference> onChanged;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '安装',
          style: titleStyle ?? theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        SegmentedButton<InstallPreference>(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.selected)
                  ? colors.secondaryContainer
                  : null;
            }),
          ),
          showSelectedIcon: true,
          segments: const [
            ButtonSegment(
              value: InstallPreference.watchface,
              icon: Icon(Icons.watch),
              label: Text('表盘设计优先'),
            ),
            ButtonSegment(
              value: InstallPreference.quickApp,
              icon: Icon(Icons.apps),
              label: Text('快应用开发优先'),
            ),
            ButtonSegment(
              value: InstallPreference.both,
              icon: Icon(Icons.apps),
              label: Text('均有开发'),
            ),
          ],
          selected: {value},
          onSelectionChanged: (selection) => onChanged(selection.single),
        ),
        const SizedBox(height: 8),
        Text(
          '主页安装按钮会优先显示所选类型；菜单中的临时安装不会修改此设置。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
