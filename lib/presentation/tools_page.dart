import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/device_controller.dart';
import '../domain/device_tools.dart';

class ToolsPage extends StatefulWidget {
  const ToolsPage({required this.controller, super.key});

  final DeviceController controller;

  @override
  State<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends State<ToolsPage> {
  static final _macPattern = RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$');

  final _snController = TextEditingController();
  final _macController = TextEditingController();
  PlatformFile? _zipFile;
  String? _authKey;
  String? _authError;
  String? _unlockCode;
  UnlockAlgorithm _unlockAlgorithm = UnlockAlgorithm.old;
  bool _extracting = false;

  @override
  void dispose() {
    _snController.dispose();
    _macController.dispose();
    super.dispose();
  }

  Future<void> _pickZip() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      withData: true,
    );
    if (!mounted || result == null || result.files.isEmpty) return;
    setState(() {
      _zipFile = result.files.single;
      _authKey = null;
      _authError = null;
    });
  }

  Future<Uint8List?> _readZip(PlatformFile file) async {
    if (file.bytes != null) return file.bytes;
    final path = file.path;
    if (path == null) return null;
    return Uint8List.fromList(await File(path).readAsBytes());
  }

  Future<void> _extractAuthKey() async {
    final file = _zipFile;
    if (file == null) return;
    setState(() {
      _extracting = true;
      _authError = null;
      _authKey = null;
    });
    try {
      final bytes = await _readZip(file);
      if (bytes == null) throw const FormatException('无法读取 ZIP 文件');
      final candidates = extractAuthKeysFromZip(bytes);
      if (candidates.isEmpty) {
        throw const FormatException('未找到 32 位 authkey');
      }
      if (mounted) setState(() => _authKey = candidates.first.key);
    } on Object catch (error) {
      if (mounted) setState(() => _authError = '文件无效或未找到 authkey：$error');
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  void _copy(String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制')));
  }

  Future<void> _applyAuthKey() async {
    final key = _authKey;
    if (key == null) return;
    final applied = await widget.controller.setAuthKey(key);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(applied ? 'authkey 已应用到当前会话' : 'authkey 无效')),
    );
  }

  void _computeUnlockCode() {
    final sn = _snController.text.trim();
    final mac = _macController.text.trim().toUpperCase();
    if (sn.length < 4 || !_macPattern.hasMatch(mac)) return;
    setState(() {
      _unlockCode = computeUnlockCode(
        sn,
        mac,
        algorithm: _unlockAlgorithm,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final key = _authKey;
    final validUnlockInput = _snController.text.trim().length >= 4 &&
        _macPattern.hasMatch(_macController.text);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('工具', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 20),
            _ToolCard(
              icon: Icons.vpn_key,
              title: 'authkey 提取',
              description: '从小米运动健康 / Zepp Life 导出的日志 .zip 中解析设备 authkey',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: _pickZip,
                    borderRadius: BorderRadius.circular(12),
                    child: CustomPaint(
                      painter: _DashedBorderPainter(
                          color: theme.colorScheme.outline),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(20),
                        child: _zipFile == null
                            ? const Column(
                                children: [
                                  Icon(Icons.upload_file, size: 30),
                                  SizedBox(height: 8),
                                  Text('点击选择 .zip 日志文件'),
                                ],
                              )
                            : Row(
                                children: [
                                  const Icon(Icons.insert_drive_file),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _zipFile!.name,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Text(_formatSize(_zipFile!.size)),
                                  TextButton(
                                      onPressed: _pickZip,
                                      child: const Text('重新选择')),
                                ],
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _zipFile == null || _extracting
                        ? null
                        : _extractAuthKey,
                    icon: _extracting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.key),
                    label: Text(_extracting ? '正在提取…' : '提取 authkey'),
                  ),
                  if (_authError case final error?)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(error,
                          style: TextStyle(color: theme.colorScheme.error)),
                    ),
                  if (key != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      color: theme.colorScheme.surfaceContainerLowest,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              key,
                              style: const TextStyle(fontFamily: 'monospace'),
                            ),
                          ),
                          IconButton(
                            tooltip: '复制 authkey',
                            icon: const Icon(Icons.copy),
                            onPressed: () => _copy(key),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _applyAuthKey,
                      icon: const Icon(Icons.check),
                      label: const Text('应用到当前会话'),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            _ToolCard(
              icon: Icons.lock_open,
              title: '解锁码计算',
              description: '根据设备 SN 码与 MAC 地址计算解锁码',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final sn = TextField(
                        controller: _snController,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                            labelText: 'SN 码', border: OutlineInputBorder()),
                      );
                      final mac = TextField(
                        controller: _macController,
                        onChanged: (_) => setState(() {}),
                        inputFormatters: const [_MacAddressFormatter()],
                        decoration: const InputDecoration(
                          labelText: 'MAC 地址',
                          hintText: 'AA:BB:CC:DD:EE:FF',
                          border: OutlineInputBorder(),
                        ),
                      );
                      return constraints.maxWidth < 620
                          ? Column(
                              children: [sn, const SizedBox(height: 12), mac])
                          : Row(children: [
                              Expanded(child: sn),
                              const SizedBox(width: 12),
                              Expanded(child: mac)
                            ]);
                    },
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<UnlockAlgorithm>(
                    segments: const [
                      ButtonSegment(
                        value: UnlockAlgorithm.old,
                        label: Text('旧算法'),
                        icon: Icon(Icons.history),
                      ),
                      ButtonSegment(
                        value: UnlockAlgorithm.newer,
                        label: Text('新算法'),
                        icon: Icon(Icons.new_releases_outlined),
                      ),
                    ],
                    selected: {_unlockAlgorithm},
                    onSelectionChanged: (selection) {
                      setState(() {
                        _unlockAlgorithm = selection.single;
                        _unlockCode = null;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    color: const Color(0xFF3A322A),
                    child: const Text(
                      '在您计算解锁码之前，我们强烈建议您先尝试使用连续插拔设备充电器百余次的方法让设备重启三次触发保护恢复出厂设置这种更便捷的方法删除密码。',
                      style: TextStyle(color: Color(0xFFD9B48A)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: validUnlockInput ? _computeUnlockCode : null,
                    icon: const Icon(Icons.calculate),
                    label: const Text('计算解锁码'),
                  ),
                  if (_unlockCode case final code?) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        SelectableText(
                          '${code.substring(0, 5)} ${code.substring(5)}',
                          style: theme.textTheme.headlineMedium
                              ?.copyWith(fontFamily: 'monospace'),
                        ),
                        IconButton(
                          tooltip: '复制解锁码',
                          icon: const Icon(Icons.copy),
                          onPressed: () => _copy(code),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.child,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.surfaceContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: theme.colorScheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      Text(description, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, const Radius.circular(12)));
    for (final metric in path.computeMetrics()) {
      for (var offset = 0.0; offset < metric.length; offset += 10) {
        canvas.drawPath(
            metric.extractPath(offset, (offset + 6).clamp(0, metric.length)),
            paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _MacAddressFormatter extends TextInputFormatter {
  const _MacAddressFormatter();

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final hex =
        newValue.text.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
    final clipped = hex.substring(0, hex.length.clamp(0, 12));
    final groups = <String>[];
    for (var index = 0; index < clipped.length; index += 2) {
      groups
          .add(clipped.substring(index, (index + 2).clamp(0, clipped.length)));
    }
    final text = groups.join(':');
    return TextEditingValue(
        text: text, selection: TextSelection.collapsed(offset: text.length));
  }
}

String _formatSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(1)} KB';
}
