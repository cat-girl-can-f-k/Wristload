/// Mass 文件数据编码。
///
/// 本文件只实现已从官方客户端静态确认的“文件 -> Mass payload”步骤；并不
/// 打开设备数据通道，也不会把结果写入蓝牙。
///
/// 规则来自 `MassDataDispatcher` 与 `MassDataSplitter` 的字段和方法体：
///
/// - 文件按 10 MiB 分成 pending message；
/// - 第一个 pending message 在文件数据前添加 22 字节头；
/// - 最后一个 pending message 末尾添加 CRC32；CRC 覆盖“首头 + 从断点
///   起的文件数据”；
/// - 每个发送 payload 的前四字节为小端序 `总片数:uint16, 片序号:uint16`；
/// - 协商的 `segmentLength` 包含这四字节，因此每片正文最多为
///   `segmentLength - 4` 字节。
///
/// 外层 SPP/L2 的加密及 Mass channel 封装尚未由真机抓包确认，必须由调用方
/// 在验证后单独实现。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 单个可交给底层 Mass 数据通道的 payload。
class MassSegment {
  const MassSegment({
    required this.index,
    required this.total,
    required this.data,
    required this.isFirst,
    required this.isLast,
  });

  /// 设备使用的 1 起始片序号。
  final int index;
  final int total;

  /// 包含 4B 分片头的数据，不含尚未验证的 L1/L2 外层。
  final List<int> data;
  final bool isFirst;
  final bool isLast;
}

/// 官方客户端的 pending message 最大文件块大小。
const int massChunkSize = 10 * 1024 * 1024;

/// 官方客户端在设备没有给出长度时使用的默认发送片长度。
const int defaultMassSegmentLength = 4096;

/// 构造首个 pending message 的 22 字节头。
List<int> buildMassHeader({
  required int dataType,
  required List<int> fileMd5,
  required int fileLength,
  required int sentLength,
}) {
  if (fileMd5.length != 16) {
    throw ArgumentError('fileMd5 必须为 16 字节');
  }
  if (sentLength < 0 || sentLength > fileLength) {
    throw ArgumentError('sentLength 必须位于文件范围内');
  }

  final head = ByteData(22)
    ..setUint8(0, 0)
    ..setUint8(1, dataType);
  for (var i = 0; i < 16; i++) {
    head.setUint8(2 + i, fileMd5[i]);
  }
  head.setUint32(18, fileLength - sentLength, Endian.little);
  return head.buffer.asUint8List().toList();
}

/// 标准 CRC-32（与 Java `CRC32` 一致）。
int crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xEDB88320 : crc >>> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 生成由 `sendMassData` 接收的 payload 序列。
///
/// [sentLength] 用于设备允许断点续传时，从该文件偏移继续构建。是否可以续传
/// 必须以设备 `MassPrepare` 响应为准。
List<MassSegment> splitMassFile({
  required Uint8List fileBytes,
  required int dataType,
  required List<int> fileMd5,
  required int segmentLength,
  int sentLength = 0,
}) {
  if (fileBytes.isEmpty) {
    throw ArgumentError('Mass 不接受空文件');
  }
  if (segmentLength <= 4) {
    throw ArgumentError('segmentLength 必须大于 4（含 4 字节分片头）');
  }
  if (sentLength < 0 || sentLength >= fileBytes.length) {
    throw ArgumentError('sentLength 必须位于可发送文件范围内');
  }

  final bodyCapacity = segmentLength - 4;
  final pendingBodies = <List<int>>[];
  var offset = sentLength;
  var pendingIndex = 0;

  while (offset < fileBytes.length) {
    final end = math.min(offset + massChunkSize, fileBytes.length);
    final body = <int>[];
    if (pendingIndex == 0) {
      body.addAll(buildMassHeader(
        dataType: dataType,
        fileMd5: fileMd5,
        fileLength: fileBytes.length,
        sentLength: sentLength,
      ));
    }
    body.addAll(fileBytes.sublist(offset, end));
    if (end == fileBytes.length) {
      // Java: CRCUtil.getFileCRC32(header, sentLength, filePath)
      // 即 CRC(header + file[sentLength..end])，而不是只对文件本体做 CRC。
      final header = buildMassHeader(
        dataType: dataType,
        fileMd5: fileMd5,
        fileLength: fileBytes.length,
        sentLength: sentLength,
      );
      final crc = crc32([...header, ...fileBytes.sublist(sentLength)]);
      final tail = ByteData(4)..setUint32(0, crc, Endian.little);
      body.addAll(tail.buffer.asUint8List());
    }
    pendingBodies.add(body);
    offset = end;
    pendingIndex++;
  }

  final total = pendingBodies.fold<int>(
    0,
    (count, body) => count + (body.length / bodyCapacity).ceil(),
  );
  if (total > 0xFFFF) {
    throw ArgumentError('分片数量超过协议 uint16 上限：$total');
  }

  final result = <MassSegment>[];
  var sequence = 1;
  for (final body in pendingBodies) {
    for (var offset = 0; offset < body.length; offset += bodyCapacity) {
      final take = math.min(bodyCapacity, body.length - offset);
      final packet = ByteData(4 + take)
        ..setUint16(0, total, Endian.little)
        ..setUint16(2, sequence, Endian.little);
      for (var i = 0; i < take; i++) {
        packet.setUint8(4 + i, body[offset + i]);
      }
      result.add(MassSegment(
        index: sequence,
        total: total,
        data: packet.buffer.asUint8List(),
        isFirst: sequence == 1,
        isLast: sequence == total,
      ));
      sequence++;
    }
  }
  return result;
}
