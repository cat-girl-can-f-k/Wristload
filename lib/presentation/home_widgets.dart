import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/device_profile.dart';

class LogPanel extends StatelessWidget {
  const LogPanel({
    required this.logs,
    required this.onClear,
    super.key,
  });

  final List<String> logs;
  final VoidCallback onClear;

  Future<void> _copyAll(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: logs.join('\n')));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('已复制全部日志（${logs.length} 行）'),
        duration: const Duration(seconds: 2),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('运行日志（${logs.length}）',
                    style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: '复制全部日志',
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: logs.isEmpty ? null : () => _copyAll(context),
                ),
                IconButton(
                  tooltip: '清空日志',
                  icon: const Icon(Icons.clear_all, size: 20),
                  onPressed: onClear,
                ),
              ],
            ),
            const SizedBox(height: 4),
            SelectionArea(
              child: SizedBox(
                height: 220,
                child: logs.isEmpty
                    ? Center(
                        child: Text(
                          '暂无日志。扫描、连接、服务发现与鉴权状态都会显示在这里。',
                          style: theme.textTheme.bodySmall,
                        ),
                      )
                    : ListView.builder(
                        reverse: true,
                        itemCount: logs.length,
                        itemBuilder: (context, index) {
                          final line = logs[logs.length - 1 - index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1),
                            child: Text(
                              line,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool isInstallableDiscovery(DiscoveredEventArgs result) {
  final name = (result.advertisement.name ?? '').trim();
  return DeviceProfile.matchAdvertisementName(name)?.generation ==
      ProtocolGeneration.v2Vela;
}

class ScanResultsList extends StatefulWidget {
  const ScanResultsList({
    required this.results,
    required this.onConnect,
    super.key,
  });

  final List<DiscoveredEventArgs> results;
  final ValueChanged<DiscoveredEventArgs> onConnect;

  @override
  State<ScanResultsList> createState() => _ScanResultsListState();
}

class _ScanResultsListState extends State<ScanResultsList> {
  bool _showOtherDevices = true;

  @override
  Widget build(BuildContext context) {
    final installable = widget.results
        .where(isInstallableDiscovery)
        .toList(growable: false);
    final other = widget.results
        .where((result) => !isInstallableDiscovery(result))
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ScanGroupHeader(label: '可安装的设备 · ${installable.length}'),
        for (final result in installable)
          ScanTile(
            key: ValueKey(result.peripheral.uuid.toString()),
            result: result,
            installable: true,
            onConnect: () => widget.onConnect(result),
          ),
        const SizedBox(height: 8),
        _ScanGroupHeader(
          label: '其他设备 · ${other.length}（不支持安装）',
          expanded: _showOtherDevices,
          onToggle: () => setState(() {
            _showOtherDevices = !_showOtherDevices;
          }),
        ),
        if (_showOtherDevices)
          for (final result in other)
            ScanTile(
              key: ValueKey(result.peripheral.uuid.toString()),
              result: result,
              installable: false,
              onConnect: null,
            ),
      ],
    );
  }
}

class _ScanGroupHeader extends StatelessWidget {
  const _ScanGroupHeader({
    required this.label,
    this.expanded,
    this.onToggle,
  });

  final String label;
  final bool? expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final title = Text(label, style: Theme.of(context).textTheme.titleMedium);
    if (onToggle == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
        child: title,
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 0, 4),
        child: Row(
          children: [
            Expanded(child: title),
            Icon(expanded == true ? Icons.expand_less : Icons.expand_more),
          ],
        ),
      ),
    );
  }
}

class ScanTile extends StatelessWidget {
  const ScanTile({
    required this.result,
    required this.installable,
    required this.onConnect,
    super.key,
  });

  final DiscoveredEventArgs result;
  final bool installable;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final name = (result.advertisement.name ?? '').trim();
    final profile = DeviceProfile.matchAdvertisementName(name);
    final card = Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: installable
            ? BorderSide(
                color: colors.primary.withValues(alpha: .55),
                width: 1.5,
              )
            : BorderSide(color: colors.outlineVariant),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: installable
              ? LinearGradient(
                  colors: [
                    colors.primaryContainer.withValues(alpha: .48),
                    colors.surfaceContainerLow,
                  ],
                )
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: installable
                      ? colors.primaryContainer
                      : colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  installable ? Icons.watch_outlined : Icons.bluetooth,
                  color: installable ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? '未命名设备' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (installable && profile != null) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          _DeviceLabel(
                            label: profile.displayName,
                            backgroundColor: colors.secondaryContainer,
                            foregroundColor: colors.onSecondaryContainer,
                          ),
                          _DeviceLabel(
                            label: '✓ 可安装',
                            foregroundColor: colors.tertiary,
                            borderColor: colors.tertiary,
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      result.peripheral.uuid.toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                    ),
                    if (result.rssi > 0)
                      Text(
                        'RSSI ${result.rssi}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (installable)
                FilledButton(
                  onPressed: onConnect,
                  child: const Text('连接'),
                )
              else
                _DeviceLabel(
                  label: '非手环设备',
                  foregroundColor: colors.onSurfaceVariant,
                  borderColor: colors.outline,
                ),
            ],
          ),
        ),
      ),
    );
    return installable ? card : Opacity(opacity: .58, child: card);
  }
}

class _DeviceLabel extends StatelessWidget {
  const _DeviceLabel({
    required this.label,
    required this.foregroundColor,
    this.backgroundColor,
    this.borderColor,
  });

  final String label;
  final Color foregroundColor;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(8),
          border: borderColor == null ? null : Border.all(color: borderColor!),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: foregroundColor,
              ),
        ),
      );
}

class ScanningPulseIndicator extends StatefulWidget {
  const ScanningPulseIndicator({super.key});

  @override
  State<ScanningPulseIndicator> createState() =>
      _ScanningPulseIndicatorState();
}

class _ScanningPulseIndicatorState extends State<ScanningPulseIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SizedBox.square(
      dimension: 38,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Stack(
          alignment: Alignment.center,
          children: [
            Transform.scale(
              scale: .55 + (_controller.value * .75),
              child: Opacity(
                opacity: 1 - _controller.value,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: primary.withValues(alpha: .7),
                      width: 2,
                    ),
                  ),
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(color: primary, shape: BoxShape.circle),
              child: const SizedBox.square(dimension: 8),
            ),
          ],
        ),
      ),
    );
  }
}
