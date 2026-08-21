import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../application/device_controller.dart';
import '../../domain/install_file_classifier.dart';
import '../../domain/install_metadata_reader.dart';
import '../../domain/install_models.dart';
import '../../domain/install_task.dart';
import '../../domain/protocol/zau.dart';
import '../../domain/queue_file_importer.dart';
import '../../platform/scoped_file_picker.dart';

import '../install_request_preflight.dart';
import '../page_module.dart';

const wristloadPage = WristloadPageModule(
  id: 'debug',
  route: '/debug',
  label: '调试',
  icon: Icons.bug_report_outlined,
  selectedIcon: Icons.bug_report,
  order: 40,
  build: _buildDebugPage,
);

Widget _buildDebugPage(WristloadPageContext context) =>
    DebugPage(controller: context.controller);

class DebugPage extends StatefulWidget {
  const DebugPage({required this.controller, super.key});

  final DeviceController controller;

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage> {
  PlatformFile? _file;
  String? _macOSFileName;
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
    if (Platform.isMacOS) {
      await _pickMacOSFile();
      return;
    }

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
    final kind = _legacyKindForPath(path);
    if (kind == null) {
      setState(() => _error = '仅支持 .rpk、.bin、.face 文件。');
      return;
    }
    setState(() {
      _file = selected;
      _macOSFileName = null;
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

  Future<void> _pickMacOSFile() async {
    try {
      final selected = await ScopedFilePicker.pickFiles(
        allowedExtensions: const ['rpk', 'bin', 'face'],
      );
      final source = selected?.single;
      if (!mounted || source == null) return;

      final fileName = source.path.split(RegExp(r'[/\\]')).last;
      setState(() {
        _file = null;
        _macOSFileName = fileName;
        _request = null;
        _error = null;
        _loading = true;
      });

      final classifiedSource = await const InstallFileClassifier()
          .classifySource(source);
      final classification = classifiedSource.type;
      if (!mounted) return;
      if (classification == InstallableFileType.firmware) {
        setState(() {
          _loading = false;
          _error = '调试安装不支持固件包，请使用首页的固件检查入口。';
        });
        return;
      }
      final kind = switch (classification) {
        InstallableFileType.quickApp => InstallKind.quickApp,
        InstallableFileType.watchface => InstallKind.watchface,
        InstallableFileType.unsupported => null,
        InstallableFileType.firmware => null,
      };
      if (kind == null) {
        setState(() {
          _loading = false;
          _error = '仅支持可安装的 .rpk、.bin 或 .face 文件。';
        });
        return;
      }

      final request = await QueueFileImporter().prepareSingle(
        classifiedSource.source,
        expectedKind: kind,
      );
      if (!mounted) return;
      setState(() {
        _request = request;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _request = null;
        _error = '文件解析失败：$error';
      });
    }
  }

  InstallKind? _legacyKindForPath(String path) {
    final declaredKind = QueueFileImporter.kindForPath(path);
    if (declaredKind != null) return declaredKind;
    return path.toLowerCase().endsWith('.bin') ? InstallKind.watchface : null;
  }

  Future<void> _start() async {
    final request = _request;
    if (request == null || widget.controller.debugInstallInProgress) return;
    if (!Platform.isMacOS) {
      await widget.controller.startDebugInstall(request);
      return;
    }
    final prepared = await const InstallRequestPreflight().prepare(
      context,
      widget.controller,
      request,
    );
    if (!mounted || prepared == null) return;
    await widget.controller.startDebugInstall(prepared);
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
    final pullingDeviceLog =
        controller.deviceLogPullStarting || controller.deviceLogPullActive;
    final switchingBootMode = controller.bootModeSwitching;
    final report = controller.debugCleanupReport;
    final cleanupLogs = controller.debugCleanupLogs;
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
                borderRadius: BorderRadius.circular(16),
              ),
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
                          child: Icon(Icons.restart_alt, color: colors.primary),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('启动模式', style: theme.textTheme.titleMedium),
                              Text(
                                '发送后手环会立即重启，蓝牙连接断开属于预期现象。',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        for (final mode in DeviceBootMode.values)
                          FilledButton.icon(
                            onPressed:
                                running ||
                                    polling ||
                                    pullingDeviceLog ||
                                    switchingBootMode ||
                                    controller.selfCheckStarting ||
                                    controller.selfCheckModeSwitching ||
                                    controller.selfCheckActive
                                ? null
                                : () => controller.switchBootMode(mode),
                            icon:
                                switchingBootMode &&
                                    controller.pendingBootModeLabel ==
                                        mode.label
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.restart_alt),
                            label: Text('重启到 ${mode.label}'),
                          ),
                      ],
                    ),
                    if (controller.pendingBootModeLabel case final mode?)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          '已请求重启到 $mode，等待设备重启后重新连接。',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    if (controller.bootModeError case final error?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Card(
              color: colors.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
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
                          child: Icon(
                            Icons.download_for_offline_outlined,
                            color: colors.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('设备日志', style: theme.textTheme.titleMedium),
                              Text(
                                '从设备拉取诊断日志并导出为原始文件。',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed:
                          running ||
                              polling ||
                              controller.selfCheckStarting ||
                              controller.selfCheckActive ||
                              pullingDeviceLog
                          ? null
                          : controller.pullDeviceLog,
                      icon: pullingDeviceLog
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_outlined),
                      label: Text(pullingDeviceLog ? '正在拉取设备日志' : '拉取设备日志'),
                    ),
                    if (pullingDeviceLog) ...[
                      const SizedBox(height: 16),
                      Text(
                        controller.deviceLogSegmentTotal == 0
                            ? '正在等待设备开始发送日志。'
                            : '已接收 ${controller.deviceLogReceivedSegments}/'
                                  '${controller.deviceLogSegmentTotal} 个分片，'
                                  '${controller.deviceLogReceivedBytes} B。',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                    if (controller.deviceLogError case final error?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    if (controller.latestDeviceLogPath case final path?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText(
                          '已导出${controller.latestDeviceLogId == null || controller.latestDeviceLogId!.isEmpty ? '' : '（${controller.latestDeviceLogId}）'}：$path',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Card(
              color: colors.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
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
                          child: Icon(
                            Icons.bug_report_outlined,
                            color: colors.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '安装清理速度测试',
                                style: theme.textTheme.titleMedium,
                              ),
                              Text(
                                '取消安装后每 3 秒轮询设备清理状态，直到状态不再为 1。',
                                style: theme.textTheme.bodySmall,
                              ),
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
                                      child: Text(
                                        _file?.name ?? _macOSFileName!,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (request != null)
                                      Text(_size(request.metadata.fileSize)),
                                    TextButton(
                                      onPressed: running || _loading
                                          ? null
                                          : _pickFile,
                                      child: const Text('重新选择'),
                                    ),
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
                        if (polling)
                          OutlinedButton.icon(
                            onPressed: controller.stopDebugCleanupPolling,
                            icon: const Icon(Icons.stop),
                            label: const Text('停止轮询'),
                          ),
                      ],
                    ),
                    if (polling) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '正在每 3 秒轮询设备清理状态…',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ],
                    if (_error case final error?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    if (controller.debugError case final error?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    if (cleanupLogs.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text('清理轮询日志', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 220),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerLowest,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: colors.outlineVariant),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            cleanupLogs.join('\n'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              height: 1.45,
                            ),
                          ),
                        ),
                      ),
                    ],
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
                            Text(
                              result.stoppedByUser
                                  ? '轮询已停止'
                                  : result.completed
                                  ? '设备清理轮询结束'
                                  : '设备清理查询结束',
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '用时 ${(result.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} 秒 · 轮询 ${result.pollCount} 次 · 最终状态 ${result.finalStatus ?? '未知'}',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Card(
              color: colors.surfaceContainer,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
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
                          child: Icon(
                            Icons.fact_check_outlined,
                            color: colors.primary,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('设备自检', style: theme.textTheme.titleMedium),
                              Text(
                                '进入自检后等待手环主动上报结果。',
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        FilledButton.icon(
                          onPressed:
                              running ||
                                  polling ||
                                  pullingDeviceLog ||
                                  controller.selfCheckStarting ||
                                  controller.selfCheckModeSwitching ||
                                  controller.selfCheckEntered
                              ? null
                              : controller.enterSelfCheckMode,
                          icon: controller.selfCheckModeSwitching
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.play_arrow),
                          label: Text(
                            controller.selfCheckModeSwitching
                                ? '正在进入自检'
                                : '进入自检模式',
                          ),
                        ),
                        FilledButton.icon(
                          onPressed:
                              controller.selfCheckEntered &&
                                  !controller.selfCheckStarting &&
                                  !controller.selfCheckModeSwitching &&
                                  !controller.selfCheckActive
                              ? controller.startSelfCheck
                              : null,
                          icon: controller.selfCheckStarting
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.fact_check_outlined),
                          label: Text(
                            controller.selfCheckStarting ? '正在启动自检' : '开始自检',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              controller.selfCheckStarting ||
                                  controller.selfCheckModeLoading ||
                                  controller.selfCheckModeSwitching
                              ? null
                              : controller.refreshSelfCheckMode,
                          icon: controller.selfCheckModeLoading
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.refresh),
                          label: const Text('读取当前模式'),
                        ),
                        OutlinedButton.icon(
                          onPressed:
                              controller.selfCheckEntered &&
                                  !controller.selfCheckStarting &&
                                  !controller.selfCheckModeSwitching
                              ? controller.exitSelfCheck
                              : null,
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('退出自检模式'),
                        ),
                        OutlinedButton.icon(
                          onPressed: controller.latestSelfCheckReport == null
                              ? null
                              : controller.exportSelfCheckResult,
                          icon: const Icon(Icons.file_download_outlined),
                          label: const Text('导出自检结果'),
                        ),
                      ],
                    ),
                    if (controller.selfCheckActive) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '设备正在自检，等待结果上报。',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ],
                    if (controller.selfCheckEntered &&
                        !controller.selfCheckActive &&
                        !controller.selfCheckStarting)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          '已进入自检模式，可以开始自检或退出。',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    if (controller.currentSelfCheckMode case final mode?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          '设备模式值：$mode（3 表示设备正在执行自检）',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    if (controller.selfCheckError case final error?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                    if (controller.latestSelfCheckReport
                        case final result?) ...[
                      const SizedBox(height: 16),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: result.completed
                              ? colors.primaryContainer
                              : colors.secondaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              result.completed ? '已收到设备自检结果' : '已收到未完成的自检结果',
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '通过 ${result.passedCount}/${result.items.length} 项',
                            ),
                            const SizedBox(height: 8),
                            SelectableText(
                              result.items
                                  .map(
                                    (item) =>
                                        '项目 ${item.id}: ${item.passed ? 'PASS' : 'FAIL'}',
                                  )
                                  .join('\n'),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (controller.latestSelfCheckExportPath case final path?)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText(
                          '已导出：$path',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
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
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      );
    for (final metric in path.computeMetrics()) {
      for (var offset = 0.0; offset < metric.length; offset += 10) {
        canvas.drawPath(
          metric.extractPath(offset, (offset + 6).clamp(0, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DebugDashedPainter oldDelegate) =>
      oldDelegate.color != color;
}
