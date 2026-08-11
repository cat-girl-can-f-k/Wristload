import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../domain/protocol/hci_decoder.dart';

/// 只能包含可跨 Isolate 发送的数据；不要把 Widget、BuildContext 或闭包带入 worker。
class _HciDecodeInput {
  const _HciDecodeInput(this.bytes, this.authKey);

  final TransferableTypedData bytes;
  final String authKey;
}

class _HciWorkerMessage {
  const _HciWorkerMessage(this.replyPort, this.input);

  final SendPort replyPort;
  final _HciDecodeInput input;
}

class _HciWorkerFailure {
  const _HciWorkerFailure(this.message);

  final String message;
}

/// 顶层 Isolate 入口：Flutter Windows 只允许可发送对象穿过 SendPort。
void _hciWorkerEntry(_HciWorkerMessage message) {
  try {
    message.replyPort.send(const HciDecoder().decode(
      hciBytes: message.input.bytes.materialize().asUint8List(),
      authKeyHex: message.input.authKey,
    ));
  } on Object catch (error) {
    message.replyPort.send(_HciWorkerFailure(error.toString()));
  }
}

Future<HciDecodeReport> _runHciDecode(_HciDecodeInput input) async {
  final replies = ReceivePort();
  final isolate = await Isolate.spawn<_HciWorkerMessage>(
    _hciWorkerEntry,
    _HciWorkerMessage(replies.sendPort, input),
  );
  try {
    final result = await replies.first.timeout(const Duration(minutes: 5));
    return switch (result) {
      HciDecodeReport report => report,
      _HciWorkerFailure failure => throw StateError(failure.message),
      _ => throw StateError('HCI worker 返回了未知结果'),
    };
  } finally {
    isolate.kill(priority: Isolate.immediate);
    replies.close();
  }
}

class HciDecoderPage extends StatefulWidget {
  const HciDecoderPage({super.key});

  @override
  State<HciDecoderPage> createState() => _HciDecoderPageState();
}

class _HciDecoderPageState extends State<HciDecoderPage> {
  final _authKey = TextEditingController();
  String? _filePath;
  HciDecodeReport? _report;
  String? _error;
  bool _running = false;

  @override
  void dispose() {
    _authKey.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['log'],
    );
    final path = selected?.files.single.path;
    if (path != null && mounted) {
      setState(() {
        _filePath = path;
        _report = null;
        _error = null;
      });
    }
  }

  Future<void> _decode() async {
    final path = _filePath;
    final authKey = _authKey.text.trim();
    if (path == null || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(authKey)) {
      setState(() => _error = '请选择 .log，并输入 32 位十六进制 authkey。');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _report = null;
    });
    try {
      final file = File(path);
      final length = await file.length();
      if (length <= 0 || length > maxHciCaptureBytes) {
        throw const FormatException('HCI 文件为空或超过 512 MB 安全上限');
      }
      final bytes = Uint8List.fromList(await file.readAsBytes());
      final report = await _runHciDecode(_HciDecodeInput(
        TransferableTypedData.fromList([bytes]),
        authKey,
      ));
      if (mounted) setState(() => _report = report);
    } on Object catch (error) {
      if (mounted) setState(() => _error = '解码失败：$error');
    } finally {
      _authKey.clear();
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      appBar: AppBar(title: const Text('离线 HCI 解码')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('只读取本地 btsnoop HCI 文件；不会连接设备、上传文件或保存 authkey。'),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _running ? null : _pickFile,
            icon: const Icon(Icons.folder_open_outlined),
            label: Text(_filePath == null
                ? '选择 btsnoop_hci.log'
                : '已选：${_filePath!.split(RegExp(r'[/\\]')).last}'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _authKey,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            maxLength: 32,
            decoration: const InputDecoration(
              labelText: '该抓包会话的 authkey',
              helperText: '仅在内存中用于本次解码，完成后自动清空。',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _running ? null : _decode,
            icon: _running
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(_running ? '正在本地解码…' : '开始解码'),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: 12),
            Text(error,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          if (report != null) ...[
            const SizedBox(height: 16),
            Text(
              '结果：${report.l1Frames} 个 L1 帧，${report.sessions} 个已确认会话，'
              '${report.encryptedFrames} 个 WRITE_ENC 帧，${report.massFrames} 个 Mass 帧。',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SelectionArea(child: Text(report.lines.join('\n'))),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
