import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'application/device_controller.dart';
import 'domain/device_profile.dart';
import 'domain/install_task.dart';
import 'domain/wear_protocol.dart';

void main() => runApp(const MiWearableApp());

class MiWearableApp extends StatefulWidget {
  const MiWearableApp({super.key});

  @override
  State<MiWearableApp> createState() => _MiWearableAppState();
}

class _MiWearableAppState extends State<MiWearableApp> {
  final controller = DeviceController();

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => HomePage(controller: controller),
        ),
      );
}

class HomePage extends StatelessWidget {
  const HomePage({required this.controller, super.key});

  final DeviceController controller;

  Future<void> _pickAndTry(BuildContext context, InstallKind kind) async {
    final extension = kind == InstallKind.watchface ? 'bin' : 'rpk';
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: [extension],
    );
    final path = selected?.files.single.path;
    if (path != null) await controller.startInstall(kind, path);
  }

  /// authkey 是正式会话身份校验的必填输入。
  Future<void> _connectWithAuthKey(
      BuildContext context, DiscoveredEventArgs result) async {
    final textController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('输入 authkey'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: textController,
            autofocus: true,
            maxLength: 32,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              hintText: '32 位十六进制（绑定 token，16 字节）',
              counterText: '',
              border: OutlineInputBorder(),
            ),
            validator: (value) {
              final v = value?.trim() ?? '';
              if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(v)) {
                return '请输入 32 位十六进制字符';
              }
              return null;
            },
            onFieldSubmitted: (value) {
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, value.trim());
              }
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
              if (formKey.currentState!.validate()) {
                Navigator.pop(dialogContext, textController.text.trim());
              }
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
    if (input != null && controller.setAuthKey(input)) {
      await controller.connect(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = controller.connectedDevice;
    return Scaffold(
      appBar: AppBar(title: const Text('MiWearable 安装工具')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(device == null ? '尚未连接设备' : '已连接：${device.uuid}',
                        style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      device == null
                          ? '连接必须输入 authkey（32 位 hex）。私有鉴权和安装帧仅在真机验证后启用。'
                          : '已发现 ${controller.services.length} 个 GATT 服务；能力需通过后续协议验证读取。',
                    ),
                    if (controller.authKey != null) ...[
                      const SizedBox(height: 4),
                      Text(
                          'authkey 已保存：${controller.authKey!.substring(0, 4)}…'
                          '${controller.authKey!.substring(28)}',
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: device == null
                          ? controller.beginScan
                          : controller.disconnect,
                      icon: Icon(device == null
                          ? Icons.bluetooth_searching
                          : Icons.link_off),
                      label: Text(device == null ? '扫描附近设备' : '断开连接'),
                    ),
                  ]),
            ),
          ),
          if (controller.error case final error?)
            Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))),
          if (device == null) ...[
            const SizedBox(height: 12),
            Text('发现的设备', style: Theme.of(context).textTheme.titleMedium),
            for (final result in controller.scanResults)
              _ScanTile(
                result: result,
                onConnect: () => _connectWithAuthKey(context, result),
              ),
          ] else ...[
            const SizedBox(height: 12),
            Text('实验性安装', style: Theme.of(context).textTheme.titleMedium),
            const Text('文件可被选择，但私有协议尚未验证前不会发送数据。'),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () => _pickAndTry(context, InstallKind.watchface),
              icon: const Icon(Icons.watch),
              label: const Text('选择表盘 .bin 并尝试'),
            ),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () => _pickAndTry(context, InstallKind.quickApp),
              icon: const Icon(Icons.apps),
              label: const Text('选择快应用 .rpk 并尝试'),
            ),
            const SizedBox(height: 8),
            if (controller.isConnected)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  kProtocolVerified
                      ? '已启用经过真机验证的私有协议操作。'
                      : 'SPP/authkey 会话可验证；表盘、快应用与其他业务帧仍处于安全门控状态。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            FilledButton.icon(
              onPressed: controller.canStartSppAuth
                  ? controller.connectSpp
                  : null,
              icon: const Icon(Icons.verified_user_outlined),
              label: const Text('通过 SPP 验证 authkey'),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: controller.l1StartVariant,
                    decoration: const InputDecoration(
                      labelText: 'L1START 变体（实验）',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (var variant = 0; variant <= 5; variant++)
                        DropdownMenuItem(
                          value: variant,
                          child: Text(DeviceController.variantName(variant),
                              overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) controller.setL1StartVariant(value);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: kProtocolVerified
                      ? () => controller.sendL1Start(
                            variant: controller.l1StartVariant,
                          )
                      : null,
                  icon: const Icon(Icons.handshake_outlined),
                  label: const Text('发 L1START'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'SPP 鉴权仅适用于已确认的 V2 设备；表盘、快应用与其他业务命令仍不会发送。',
              style: TextStyle(fontSize: 12),
            ),
            if (controller.latestTask case final task?) _TaskCard(task: task),
          ],
          const SizedBox(height: 12),
          _LogPanel(logs: controller.logs, onClear: controller.clearLogs),
        ],
      ),
    );
  }
}

class _LogPanel extends StatelessWidget {
  const _LogPanel({required this.logs, required this.onClear});

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
                        child: Text('暂无日志。扫描、连接、服务发现与鉴权状态都会显示在这里。',
                            style: theme.textTheme.bodySmall),
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

class _ScanTile extends StatelessWidget {
  const _ScanTile({required this.result, required this.onConnect});
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
        ProtocolGeneration.unknown => '未确认',
      };
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task});
  final InstallTask task;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(top: 12),
        child: ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(task.fileName),
          subtitle: Text(task.message),
          trailing: Text(task.stage.name),
        ),
      );
}
