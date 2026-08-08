/// Mass 文件传输：把本地文件按设备协商的分片长度切段，
/// 生成与小米运动健康 APK 一致的 MassData 载荷序列。
///
/// 数据布局（逆向自 MassDataDispatcher，全部独立实现）：
/// - 首大块前 22B 头：
///   `[0x00][dataTypeByte][fileMD5×16][(fileLength - sentLength) LE ×4]`
/// - 尾大块后 4B：文件 CRC32（LE）
/// - 文件先按 10MB 切大块，每大块再按设备 `expectedSliceLength` 切段；
///   段大小上限默认取 `segmentLength`，实际由 MassPrepare 响应给出。
///
/// 这里的「段」即一次 `sendMassData(channel, segment)` 的载荷。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 单个待发送段。
class MassSegment {
  MassSegment({required this.index, required this.data, required this.isFirst, required this.isLast});

  final int index;
  final List<int> data;
  final bool isFirst;
  final bool isLast;
}

/// 10MB 大块大小（与 APK 一致）。
const int massChunkSize = 10485760;

/// 构造 Mass 数据头（仅首大块）。
List<int> buildMassHeader({
  required int dataType,
  required List<int> fileMd5,
  required int fileLength,
  required int sentLength,
}) {
  if (fileMd5.length != 16) {
    throw ArgumentError('fileMd5 必须为 16 字节');
  }
  final remaining = fileLength - sentLength;
  final head = ByteData(22);
  head.setUint8(0, 0);
  head.setUint8(1, dataType);
  for (var i = 0; i < 16; i++) {
    head.setUint8(2 + i, fileMd5[i]);
  }
  head.setUint32(18, remaining, Endian.little);
  return head.buffer.asUint8List().toList();
}

/// 计算 CRC32（zlib 标准，与 Java CRCUtil.getFileCRC32 一致）。
int crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xEDB88320 : crc >>> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 把文件切分为 Mass 段序列。
///
/// [segmentLength] 为设备协商的「数据段」长度（MassPrepare 响应的
/// expectedSliceLength）。22B 首片头与 4B 尾 CRC 是附加在首尾段之外，
/// 不占用段内数据空间（与 APK 的段语义一致；细节仍待真机 HCI 确认）。
/// 返回的段不直接落盘，由上层逐段发送。
List<MassSegment> splitMassFile({
  required Uint8List fileBytes,
  required int dataType,
  required List<int> fileMd5,
  required int segmentLength,
}) {
  if (segmentLength <= 0) {
    throw ArgumentError('segmentLength 必须 > 0');
  }
  final segments = <MassSegment>[];
  var chunkOffset = 0;
  var segmentIndex = 0;
  final fileLength = fileBytes.length;

  while (chunkOffset < fileLength) {
    final chunkEnd = math.min(chunkOffset + massChunkSize, fileLength);
    final chunkLen = chunkEnd - chunkOffset;
    final isFirstChunk = chunkOffset == 0;
    final isLastChunk = chunkEnd == fileLength;

    var offsetInChunk = 0;
    while (offsetInChunk < chunkLen) {
      final take = math.min(segmentLength, chunkLen - offsetInChunk);
      final isFirstSegment = isFirstChunk && offsetInChunk == 0;
      final isLastSegment = isLastChunk && offsetInChunk + take >= chunkLen;

      final headerLen = isFirstSegment ? 22 : 0;
      final crcLen = isLastSegment ? 4 : 0;
      final seg = ByteData(headerLen + take + crcLen);
      var pos = 0;
      if (isFirstSegment) {
        final head = buildMassHeader(
          dataType: dataType,
          fileMd5: fileMd5,
          fileLength: fileLength,
          sentLength: chunkOffset,
        );
        for (final b in head) {
          seg.setUint8(pos++, b);
        }
      }
      for (var i = 0; i < take; i++) {
        seg.setUint8(pos++, fileBytes[chunkOffset + offsetInChunk + i]);
      }
      if (isLastSegment) {
        final tail = crc32(fileBytes.sublist(0, fileLength));
        seg.setUint32(pos, tail, Endian.little);
      }
      segments.add(MassSegment(
        index: segmentIndex++,
        data: seg.buffer.asUint8List(),
        isFirst: isFirstSegment,
        isLast: isLastSegment,
      ));
      offsetInChunk += take;
    }
    chunkOffset = chunkEnd;
  }
  return segments;
}
