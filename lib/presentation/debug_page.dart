import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../application/device_controller.dart';
import '../domain/install_metadata_reader.dart';
import '../domain/install_models.dart';
import '../domain/queue_file_importer.dart';

class DebugPage extends StatefulWidget {
  const DebugPage({required this.controller, super.key});

  final DeviceController controller;

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage> {
  PlatformFile? _file;
  InstallRequest? _request;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _pickFile() async {
    if (widget.controller.debugInstallInProgress || _loading) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['rpk', 'bin', 'face'],
    );
    if (!mounted || result == null || result.files.isEmpty) return;
    final selected = result.files.single;
    final path = selected.path;
    if (path == null || path.isEmpty) {
      setState(() => _error = '无法读取所选文件路径。');
      return;
    }
    final kind = QueueFileImporter.kindForPath(path);
    if (kind == null) {
      setState(() => _error = '仅支持 .rpk、.bin、.face 文件。');
      return;
    }
    setState(() {
      _file = selected;
      _request = null;
      _error = null;
      _loading = true;
    });
    try {
      final metadata = await InstallMetadataReader().read(kind, path);
      if (!mounted) return;
      setState(() {
        _request = InstallRequest(kind: kind, path: path, metadata: metadata);
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '文件解析失败：$error';
      });
    }
  }

  Future<void> _start() async {
    final request = _request;
    if (request == null || widget.controller.debugInstallInProgress) return;
    await widget.controller.startDebugInstall(request);
  }

  Future<void> _cancel() async {
    await widget.controller.cancelDebugInstall();
  }

  String _size(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final request = _request;
    final controller = widget.controller;
    final running = controller.debugInstallInProgress;
    final polling = controller.debugCleanupPolling;
    final report = controller.debugCleanupReport;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('调试', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 20),
            Card(
              color: colors.surfaceContainer,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
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
                            color: colors.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.bug_report_outlined,
                              color: colors.primary),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('安装清理速度测试',
                                  style: theme.textTheme.titleMedium),
                              Text('取消安装后每 8 秒轮询设备清理状态，直到状态不再为 1。',
                                  style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    InkWell(
                      onTap: running || _loading ? null : _pickFile,
                      borderRadius: BorderRadius.circular(12),
                      child: CustomPaint(
                        painter: _DebugDashedPainter(color: colors.outline),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(20),
                          child: _file == null
                              ? const Column(
                                  children: [
                                    Icon(Icons.upload_file, size: 30),
                                    SizedBox(height: 8),
                                    Text('点击选择 .rpk、.bin 或 .face 文件'),
                                  ],
                                )
                              : Row(
                                  children: [
                                    const Icon(Icons.insert_drive_file),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(_file!.name,
                                          overflow: TextOverflow.ellipsis),
                                    ),
                                    if (request != null)
                                      Text(_size(request.metadata.fileSize)),
                                    TextButton(
                                        onPressed: running || _loading
                                            ? null
                                            : _pickFile,
                                        child: const Text('重新选择')),
                                  ],
                                ),
                        ),
                      ),
                    ),
                    if (_loading) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(minHeight: 4),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        FilledButton.icon(
                          onPressed:
                              request == null || running || polling || _loading
                                  ? null
                                  : _start,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('开始测试安装'),
                        ),
                        const SizedBox(width: 12),
                        if (running && !polling)
                          OutlinedButton.icon(
                            onPressed: _cancel,
                            icon: const Icon(Icons.stop),
                            label: const Text('取消'),
                          ),
                      ],
                    ),
                    if (polling) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 10),
                          Text('正在每 8 秒轮询设备清理状态…',
                              style: theme.textTheme.bodyMedium),
                        ],
                      ),
                    ],
                    if (_error case final error?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child:
                            Text(error, style: TextStyle(color: colors.error)),
                      ),
                    if (controller.debugError case final error?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child:
                            Text(error, style: TextStyle(color: colors.error)),
                      ),
                    if (report case final result?) ...[
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: result.completed
                              ? colors.primaryContainer
                              : colors.errorContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(result.completed ? '设备清理完成' : '设备清理查询结束',
                                style: theme.textTheme.titleSmall),
                            const SizedBox(height: 4),
                            Text(
                                '用时 ${(result.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} 秒 · 轮询 ${result.pollCount} 次 · 最终状态 ${result.finalStatus ?? '未知'}'),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DebugDashedPainter extends CustomPainter {
  const _DebugDashedPainter({required this.color});
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
  bool shouldRepaint(covariant _DebugDashedPainter oldDelegate) =>
      oldDelegate.color != color;
}
