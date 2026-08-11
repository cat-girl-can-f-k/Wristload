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
/// 外层 SPP/L2 与 Mass channel 已由真机抓包确认；调用方仍必须在已认证会话
/// 和集中协议门控内使用。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 单个可交给底层 Mass 数据通道的 payload。
class MassSegment {
  const MassSegment({
    required this.index,
    required this.total,
    required this.data,
    required this.fileByteCount,
    required this.isFirst,
    required this.isLast,
  });

  /// 设备使用的 1 起始片序号。
  final int index;
  final int total;

  /// 包含 4B 分片头的数据；L1/L2 外层由传输控制器统一封装。
  final List<int> data;

  /// 本片实际承载的源文件字节数；不包含 Mass 分片头、22B 文件头和 CRC32。
  final int fileByteCount;
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

int _crc32HeaderAndFile(
  List<int> header,
  Uint8List fileBytes,
  int sentLength,
) {
  var crc = 0xFFFFFFFF;

  void addByte(int byte) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xEDB88320 : crc >>> 1;
    }
  }

  for (final byte in header) {
    addByte(byte);
  }
  for (var i = sentLength; i < fileBytes.length; i++) {
    addByte(fileBytes[i]);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 惰性 Mass 传输计划。
///
/// 计划只保留源文件引用和少量元数据；遍历 [segments] 时才构造当前分片，避免
/// 为大文件同时创建 10 MiB pending 副本、CRC 拼接副本和全部分片副本。
class MassTransferPlan {
  MassTransferPlan._({
    required this.fileBytes,
    required this.sentLength,
    required this.segmentLength,
    required this.header,
    required this.crcTail,
    required this.totalSegments,
  });

  final Uint8List fileBytes;
  final int sentLength;
  final int segmentLength;
  final List<int> header;
  final List<int> crcTail;
  final int totalSegments;

  int get remainingFileBytes => fileBytes.length - sentLength;

  Iterable<MassSegment> get segments sync* {
    final bodyCapacity = segmentLength - 4;
    final pendingCount = (remainingFileBytes / massChunkSize).ceil();
    var sequence = 1;

    for (var pendingIndex = 0; pendingIndex < pendingCount; pendingIndex++) {
      final fileStart = sentLength + pendingIndex * massChunkSize;
      final fileEnd = math.min(fileStart + massChunkSize, fileBytes.length);
      final fileLength = fileEnd - fileStart;
      final prefixLength = pendingIndex == 0 ? header.length : 0;
      final suffixLength =
          pendingIndex == pendingCount - 1 ? crcTail.length : 0;
      final bodyLength = prefixLength + fileLength + suffixLength;

      for (var bodyOffset = 0;
          bodyOffset < bodyLength;
          bodyOffset += bodyCapacity) {
        final take = math.min(bodyCapacity, bodyLength - bodyOffset);
        final packet = ByteData(4 + take)
          ..setUint16(0, totalSegments, Endian.little)
          ..setUint16(2, sequence, Endian.little);

        for (var i = 0; i < take; i++) {
          final bodyIndex = bodyOffset + i;
          final int byte;
          if (bodyIndex < prefixLength) {
            byte = header[bodyIndex];
          } else if (bodyIndex < prefixLength + fileLength) {
            byte = fileBytes[fileStart + bodyIndex - prefixLength];
          } else {
            byte = crcTail[bodyIndex - prefixLength - fileLength];
          }
          packet.setUint8(4 + i, byte);
        }

        final overlapStart = math.max(bodyOffset, prefixLength);
        final overlapEnd = math.min(
          bodyOffset + take,
          prefixLength + fileLength,
        );
        yield MassSegment(
          index: sequence,
          total: totalSegments,
          data: packet.buffer.asUint8List(),
          fileByteCount: math.max(0, overlapEnd - overlapStart),
          isFirst: sequence == 1,
          isLast: sequence == totalSegments,
        );
        sequence++;
      }
    }
  }
}

/// 创建不复制文件正文的惰性传输计划。
MassTransferPlan planMassFile({
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

  final header = buildMassHeader(
    dataType: dataType,
    fileMd5: fileMd5,
    fileLength: fileBytes.length,
    sentLength: sentLength,
  );
  final crc = _crc32HeaderAndFile(header, fileBytes, sentLength);
  final crcData = ByteData(4)..setUint32(0, crc, Endian.little);
  final bodyCapacity = segmentLength - 4;
  final remaining = fileBytes.length - sentLength;
  final pendingCount = (remaining / massChunkSize).ceil();
  var totalSegments = 0;
  for (var pendingIndex = 0; pendingIndex < pendingCount; pendingIndex++) {
    final chunkLength = math.min(
      massChunkSize,
      remaining - pendingIndex * massChunkSize,
    );
    final bodyLength = chunkLength +
        (pendingIndex == 0 ? header.length : 0) +
        (pendingIndex == pendingCount - 1 ? 4 : 0);
    totalSegments += (bodyLength / bodyCapacity).ceil();
  }
  if (totalSegments > 0xFFFF) {
    throw ArgumentError('分片数量超过协议 uint16 上限：$totalSegments');
  }

  return MassTransferPlan._(
    fileBytes: fileBytes,
    sentLength: sentLength,
    segmentLength: segmentLength,
    header: header,
    crcTail: crcData.buffer.asUint8List(),
    totalSegments: totalSegments,
  );
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
  return planMassFile(
    fileBytes: fileBytes,
    dataType: dataType,
    fileMd5: fileMd5,
    segmentLength: segmentLength,
    sentLength: sentLength,
  ).segments.toList(growable: false);
}
