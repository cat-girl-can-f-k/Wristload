import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/device_profile.dart';

class WatchfaceResolutionDialog extends StatelessWidget {
  const WatchfaceResolutionDialog({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('表盘分辨率提示'),
        content: const Text('该表盘分辨率似乎和您的设备不匹配，请问是否要安装？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('仍然安装'),
          ),
        ],
      );
}

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

class ScanTile extends StatelessWidget {
  const ScanTile({
    required this.result,
    required this.onConnect,
    super.key,
  });

  final DiscoveredEventArgs result;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final name = result.advertisement.name ?? '';
    final profile = DeviceProfile.matchAdvertisementName(name);
    final subtitle =
        StringBuffer('${result.peripheral.uuid} · RSSI ${result.rssi}');
    if (profile != null) {
      subtitle.write(
          '\n识别：${profile.displayName}（${_generationLabel(profile.generation)}）');
    }
    return Card(
      child: ListTile(
        leading: const Icon(Icons.watch_outlined),
        title: Text(name.isEmpty ? '未命名 BLE 设备' : name),
        subtitle: Text(subtitle.toString()),
        trailing: FilledButton(onPressed: onConnect, child: const Text('连接')),
      ),
    );
  }

  String _generationLabel(ProtocolGeneration generation) =>
      switch (generation) {
        ProtocolGeneration.v2Vela => 'V2 传输 · 目标支持',
        ProtocolGeneration.v1Vela => 'V1 传输 · 暂不支持',
        ProtocolGeneration.huamiZepp => 'Huami/Zepp · 独立适配',
        ProtocolGeneration.unknown => '未确认',
      };
}
