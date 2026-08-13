import 'dart:typed_data';

import 'transport_constants.dart' show computeCrc16;

/// 手环 9 系 SPP（经典蓝牙 RFCOMM）协议——**App 版 L1 帧**（miwear-core
/// `TransportL1`/`L1Packet`/`CMDPacket`/`DataPacket`/`ACKPacket` 逆向还原）。
///
/// L1 帧（8 字节头 + payload，全部小端）：
/// ```
/// [A5 A5][(frx<<4)|type][seq][len(LE)][crc16(LE)] [payload]
/// type: 1=ACK, 2=CMD, 3=DATA
/// crc16: CRC-16/ARC（TABLE_16 首值 0xC0C1，与 computeCrc16 一致）
/// ```
/// CMD 帧 payload：`[cmd][config data]`；cmd: 1=L1START_REQ, 2=L1START_RSP
/// DATA 帧 payload：L2Packet = `[channel][opCode][protobuf]`
/// channel: 1=PB（protobuf 命令）, 2=Mass（文件分片）；
/// opCode: 1=WRITE(明文), 2=WRITE_ENC(加密)
///
/// 帧结构与字段取自官方 App 的 `TransportL1`；不能只凭相同 magic 假定
/// 其他项目的会话协商、加密和业务载荷也可直接互换。
abstract final class SppProtocol {
  static const int typeAck = 1;
  static const int typeCmd = 2;
  static const int typeData = 3;

  static const int cmdL1StartReq = 1;
  static const int cmdL1StartRsp = 2;

  static const int channelPb = 1;
  static const int channelMass = 2;

  /// Official V2 L2 channel reserved for firmware OTA traffic.
  ///
  /// This is intentionally only a protocol identifier. Firmware packages must
  /// not be sent through [channelMass], and callers must not use this channel
  /// until the OTA control frames, acknowledgements, and recovery flow have
  /// been verified from a device-specific capture.
  static const int channelOta = 6;
  static const int opCodeWrite = 1;
  static const int opCodeWriteEnc = 2;

  // L1 帧头：A5 A5（0xA5A5 = -23131 的 16 位有符号表示，小端字节 A5 A5）。
  // App 日志确认设备回包头 `A5A5020016006474`——magic 就是 A5 A5。
  static const List<int> magic = [0xa5, 0xa5];

  /// L1 帧头大小（8 字节）。
  static const int headerSize = 8;

  /// L1START_REQ 的 config payload（App `CMDPacket.Companion.createCmdData`）：
  /// VERSION=01 00 00、MPS、TX_WIN=32、SEND_TIMEOUT。
  static const int sarDefaultMps = 0xFC00;

  /// 组 L1 帧。
  static Uint8List encodeFrame(int type, int seq, List<int> payload,
      {int frx = 0}) {
    final crc = computeCrc16(payload);
    final out = BytesBuilder()
      ..add(magic)
      ..addByte(((frx & 0x0f) << 4) | (type & 0x0f))
      ..addByte(seq & 0xff)
      ..addByte(payload.length & 0xff)
      ..addByte((payload.length >> 8) & 0xff)
      ..addByte(crc & 0xff)
      ..addByte((crc >> 8) & 0xff)
      ..add(payload);
    return out.toBytes();
  }

  /// CMD 帧（type=2）：`[cmd][data]`。
  static Uint8List encodeCmd(int cmd, List<int> data) =>
      encodeFrame(typeCmd, 0, [cmd, ...data]);

  /// L1START_REQ（cmd=1 + 21B config）——App createCmdData 逐字节一致。
  static Uint8List buildL1StartRequest() {
    final config = BytesBuilder()
      ..addByte(1) // CONFIG_TYPE_VERSION
      ..addByte(0x03)
      ..addByte(0x00)
      ..addByte(0x01) // 版本 1.0.0
      ..addByte(0x00)
      ..addByte(0x00)
      ..addByte(2) // CONFIG_TYPE_MPS = 0xFC00
      ..addByte(0x02)
      ..addByte(0x00)
      ..addByte(0x00)
      ..addByte(0xfc)
      ..addByte(3) // CONFIG_TYPE_TX_WIN = 32
      ..addByte(0x02)
      ..addByte(0x00)
      ..addByte(0x20)
      ..addByte(0x00)
      ..addByte(4) // CONFIG_TYPE_SEND_TIMEOUT = 10000
      ..addByte(0x02)
      ..addByte(0x00)
      ..addByte(0x10)
      ..addByte(0x27);
    return encodeCmd(cmdL1StartReq, config.toBytes());
  }

  /// DATA 帧（type=3）：L2Packet = `[channel][opCode][payload]`。
  static Uint8List buildDataFrame(
    int seq,
    List<int> payload, {
    int channel = channelPb,
    int opCode = opCodeWrite,
  }) {
    final l2Payload = BytesBuilder()
      ..addByte(channel)
      ..addByte(opCode)
      ..add(payload);
    return encodeFrame(typeData, seq, l2Payload.toBytes());
  }

  /// ACK 帧（type=1，无 payload；V2 固定使用 `A5 A5 01`）。
  static Uint8List buildAck(int seq) => encodeFrame(typeAck, seq, const []);

  // ---- SppPacket 版本查询协议（先于 L1START，App SppVersionReader）----
  // 帧：{BA DC FE}[header 2B][dataLen 2B][type][c][d][payload][EF]
  // App 版本查询：header=00 C0（needResponse=1,flag=1 → 0xC000 LE），
  // type=0，payload=递增 1 字节序号（b1r.b()），dataLen=payload+3。

  /// 版本查询帧（seq 为递增序号；官方 b1r.b() 首次返回 1）。
  static Uint8List buildVersionQuery(int seq) => Uint8List.fromList([
        0xba, 0xdc, 0xfe, // magic
        0x00, 0xc0, // header：channelType=0, needResponse=1, flag=1
        0x04, 0x00, // dataLen = 1(payload) + 3
        0x00, 0x00, 0x00, // type, c, d
        seq & 0xff, // payload（序号）
        0xef, // end
      ]);

  /// 解析 SppPacket 帧（设备回包）。返回 (type, payload)。
  static (int, List<int>)? parseSppPacket(List<int> data) {
    if (data.length < 11) return null;
    if (data[0] != 0xba || data[1] != 0xdc || data[2] != 0xfe) return null;
    final len = data[5] | (data[6] << 8);
    if (data.length < 10 + (len - 3) + 1) return null;
    final type = data[7];
    final payload = data.sublist(10, 10 + (len - 3));
    return (type, payload);
  }

  /// 增量解析 L1 帧流。返回完整帧并保留未消费余量。
  static List<SppPacket> parse(Accumulator acc) {
    final packets = <SppPacket>[];
    final buf = acc.buffer;
    var i = 0;
    while (true) {
      var start = -1;
      for (; i + 1 < buf.length; i++) {
        if (buf[i] == 0xa5 && buf[i + 1] == 0xa5) {
          start = i;
          break;
        }
      }
      if (start < 0) {
        // 只保留可能构成 magic（A5 A5）前缀的尾部字节。
        var keep = 0;
        final n = buf.length;
        if (n >= 1 && buf[n - 1] == 0xa5) keep = 1;
        if (n >= 2 && buf[n - 2] == 0xa5 && buf[n - 1] == 0xa5) keep = 2;
        acc.buffer = buf.sublist(n - keep);
        return packets;
      }
      if (buf.length < start + headerSize) {
        acc.buffer = buf.sublist(start);
        return packets;
      }
      final typeFrx = buf[start + 2];
      final type = typeFrx & 0x0f;
      final seq = buf[start + 3] & 0xff;
      final len = buf[start + 4] | (buf[start + 5] << 8);
      final givenCrc = buf[start + 6] | (buf[start + 7] << 8);
      if (buf.length < start + headerSize + len) {
        acc.buffer = buf.sublist(start);
        return packets;
      }
      final payload = buf.sublist(start + headerSize, start + headerSize + len);
      final calcCrc = computeCrc16(payload);
      if (calcCrc != givenCrc) {
        // 坏帧：跳到帧尾继续（避免 payload 内伪 magic 误判）。
        i = start + headerSize + len;
        continue;
      }
      packets.add(SppPacket(type, seq, payload));
      i = start + headerSize + len;
    }
  }
}

class SppPacket {
  const SppPacket(this.type, this.seq, this.payload);
  final int type;
  final int seq;
  final List<int> payload;
}

/// 增量接收缓冲。
class Accumulator {
  List<int> buffer = const [];
}
