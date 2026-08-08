/// SAR 传输帧：L1（分段重组）/ L2（业务通道）构造与解析。
///
/// 依据逆向结论（`analysis/协议方法体级分析_小米运动健康_9.23.35.md`）：
///
/// L1 帧（8B 小端头 + payload）：
/// ```
/// off0 uint16 magic = 0xA525          (TransportL1.L1_HEADER_MAGIC)
/// off2 byte   (frx<<4)|type            type: 0=NAK 1=ACK 2=CMD 3=DATA; frx 0=NRX 1=FRX
/// off3 byte   seqNum
/// off4 uint16 dataLength
/// off6 uint16 crc
/// off8 payload
/// ```
///
/// L2 帧（2B 头 + payload）：
/// ```
/// off0 byte channel   (2=MASS, 4=FILE_SENSOR, 5=FILE_FITNESS, 6=OTA …)
/// off1 byte opCode    (1=WRITE, 2=WRITE_ENC, 3=READ)
/// off2 payload
/// ```
///
/// GATT：Service `0000fe95-0000-1000-8000-00805f9b34fb`
///       Write  `0000005f-0000-1000-8000-00805f9b34fb`
///       Notify `0000005e-0000-1000-8000-00805f9b34fb`
///
/// ⚠️ 注意：CRC 算法已由反编译确认（`CRCUtil` TABLE_16 = CRC-16/IBM 反射表，
/// poly 0xA001、初值 0、查表法）；L1START 载荷来自 `CMDPacket.createCmdData()`。
/// seq 窗口/重传细节仍待真机验证。
library;

/// GATT 常量（互操作必需，来自 r55/r8t）。
abstract final class SarGatt {
  static const String serviceUuid = '0000fe95-0000-1000-8000-00805f9b34fb';
  static const String versionUuid = '00000050-0000-1000-8000-00805f9b34fb';
  static const String writeUuid = '0000005f-0000-1000-8000-00805f9b34fb';
  static const String notifyUuid = '0000005e-0000-1000-8000-00805f9b34fb';
}

abstract final class L1Type {
  static const int nak = 0;
  static const int ack = 1;
  static const int cmd = 2;
  static const int data = 3;
}

abstract final class L1Cmd {
  static const int startReq = 1;
  static const int startRsp = 2;
  static const int stopReq = 3;
  static const int stopRsp = 4;
}

abstract final class L2Channel {
  static const int pb = 1;
  static const int mass = 2;
  static const int massVoice = 3;
  static const int fileSensor = 4;
  static const int fileFitness = 5;
  static const int ota = 6;
  static const int network = 7;
  static const int lyra = 8;
  static const int research = 9;
  static const int multiModal = 10;
}

abstract final class L2OpCode {
  static const int write = 1;
  static const int writeEnc = 2;
  static const int read = 3;
}

/// L1 帧。
class L1Frame {
  L1Frame({
    required this.type,
    required this.seqNum,
    required this.payload,
    this.frx = L1Frx.nrx,
    this.crc = 0,
  });

  static const int headerSize = 8;
  static const int magic = 0xA525;

  final int type;
  final int frx;
  final int seqNum;
  final int crc;
  final List<int> payload;

  /// 序列化（小端）。crc 字段默认按 [computeCrc16] 计算。
  List<int> encode({int? overrideCrc}) {
    final out = <int>[];
    final len = payload.length;
    final crcValue = overrideCrc ?? computeCrc16(payload, length: len);
    // magic
    out
      ..add(magic & 0xFF)
      ..add((magic >> 8) & 0xFF);
    // type | frx<<4
    out.add(((frx & 0x01) << 4) | (type & 0x0F));
    out.add(seqNum & 0xFF);
    // dataLength (uint16 LE)
    out
      ..add(len & 0xFF)
      ..add((len >> 8) & 0xFF);
    // crc (uint16 LE)
    out
      ..add(crcValue & 0xFF)
      ..add((crcValue >> 8) & 0xFF);
    out.addAll(payload);
    return out;
  }

  /// 解析 L1 帧。
  static L1Frame? parse(List<int> data) {
    if (data.length < headerSize) return null;
    final magic = data[0] | (data[1] << 8);
    if (magic != L1Frame.magic) return null;
    final typeFrx = data[2];
    final len = data[4] | (data[5] << 8);
    if (data.length < headerSize + len) return null;
    final crc = data[6] | (data[7] << 8);
    return L1Frame(
      type: typeFrx & 0x0F,
      frx: (typeFrx >> 4) & 0x01,
      seqNum: data[3],
      crc: crc,
      payload: data.sublist(headerSize, headerSize + len),
    );
  }
}

abstract final class L1Frx {
  static const int nrx = 0;
  static const int frx = 1;
}

/// L1START 请求帧（SAR 握手第一步）。
///
/// 载荷来自反编译 `CMDPacket.createCmdData()`（21B，LE）：
/// ```
/// [0x01] len=3 [1,0,0]          SAR 版本 1.0.0
/// [0x02] len=2 [0x00,0xFC]      MPS=64512
/// [0x03] len=2 [0x20,0x00]      TX_WIN=32
/// [0x04] len=2 [0x10,0x27]      SEND_TIMEOUT=10000ms
/// ```
/// CMD payload = [L1Cmd.startReq(0x01)] + 上述 21B；整帧 = 8B L1 头 + 22B payload。
class L1StartRequest {
  static const int configVersion = 0x01;
  static const int configMps = 0x02;
  static const int configTxWin = 0x03;
  static const int configSendTimeout = 0x04;

  static const int sarVersionMajor = 1;
  static const int sarVersionMinor = 0;
  static const int sarVersionRevision = 0;
  static const int sarDefaultMps = 64512;
  static const int sarDefaultTxWinLocal = 32;
  static const int sarSendTimeout = 10000;

  /// 21B SAR 配置载荷。
  static List<int> sarConfigPayload() {
    final out = <int>[];
    // type, len(LE), data(LE)
    out
      ..add(configVersion)
      ..add(3)
      ..add(0)
      ..add(sarVersionMajor)
      ..add(sarVersionMinor)
      ..add(sarVersionRevision)
      ..add(configMps)
      ..add(2)
      ..add(0)
      ..add(sarDefaultMps & 0xFF)
      ..add((sarDefaultMps >> 8) & 0xFF)
      ..add(configTxWin)
      ..add(2)
      ..add(0)
      ..add(sarDefaultTxWinLocal & 0xFF)
      ..add((sarDefaultTxWinLocal >> 8) & 0xFF)
      ..add(configSendTimeout)
      ..add(2)
      ..add(0)
      ..add(sarSendTimeout & 0xFF)
      ..add((sarSendTimeout >> 8) & 0xFF);
    assert(out.length == 21, 'L1START config payload must be 21 bytes');
    return out;
  }

  /// 完整 L1 帧（8B 头 + 22B payload）。
  static L1Frame build() {
    final payload = <int>[L1Cmd.startReq, ...sarConfigPayload()];
    return L1Frame(type: L1Type.cmd, seqNum: 0, payload: payload);
  }

  /// 实验变体（用于真机试错，验证设备对哪些参数/帧有响应）：
  /// - 0：标准（同 [build]）
  /// - 1：seq=1
  /// - 2：最小载荷（仅 VERSION+MPS，12B）
  /// - 4：MPS=247（小 MPS）
  /// - 5：空 DATA 帧（探测 ACK）
  /// - 3（写通道变体）由 controller 层选择 5e 特征，帧同 0。
  static L1Frame buildVariant(int variant, {int seq = 0}) {
    switch (variant) {
      case 1:
        return L1Frame(
          type: L1Type.cmd,
          seqNum: 1,
          payload: <int>[L1Cmd.startReq, ...sarConfigPayload()],
        );
      case 2:
        // VERSION(1.0.0) + MPS(64512)
        return L1Frame(
          type: L1Type.cmd,
          seqNum: 0,
          payload: <int>[
            L1Cmd.startReq,
            configVersion, 3, 0, sarVersionMajor, sarVersionMinor, sarVersionRevision,
            configMps, 2, 0, sarDefaultMps & 0xFF, (sarDefaultMps >> 8) & 0xFF,
          ],
        );
      case 4:
        final cfg = sarConfigPayload();
        cfg[9] = 247 & 0xFF; // MPS=247
        cfg[10] = (247 >> 8) & 0xFF;
        return L1Frame(
          type: L1Type.cmd,
          seqNum: 0,
          payload: <int>[L1Cmd.startReq, ...cfg],
        );
      case 5:
        return L1Frame(type: L1Type.data, seqNum: 0, payload: const []);
      default:
        return build();
    }
  }
}

/// L2 帧。
class L2Frame {
  L2Frame({required this.channel, required this.opCode, required this.payload});

  static const int headerSize = 2;

  final int channel;
  final int opCode;
  final List<int> payload;

  List<int> encode() => <int>[channel & 0xFF, opCode & 0xFF, ...payload];

  static L2Frame parse(List<int> data) {
    if (data.length < headerSize) {
      throw const FormatException('L2 frame too short');
    }
    return L2Frame(
      channel: data[0],
      opCode: data[1],
      payload: data.sublist(headerSize),
    );
  }
}

/// L1 CRC：CRC-16/IBM（反射，poly 0xA001，初值 0，无输出异或）。
///
/// 反编译确认（`com.xiaomi.wearable.utils.CRCUtil`，classes3）：
/// `i = TABLE_16[(i ^ byte) & 0xFF] ^ (i >>> 8)`，初值 0；
/// 表头 `[0, 0xC0C1, 0xC181, 0x0140, ...]` 即标准 CRC-16/IBM 反射表。
/// L1 帧头 crc 字段 = CRC16(dataLength, payload)，小端写入。
int computeCrc16(List<int> data, {int? length}) {
  final len = length ?? data.length;
  var crc = 0;
  for (var i = 0; i < len; i++) {
    crc = (_crc16Table[(crc ^ data[i]) & 0xFF]) ^ (crc >>> 8);
  }
  return crc & 0xFFFF;
}

/// CRC-16/IBM 反射查表（poly 0xA001）。
final List<int> _crc16Table = List<int>.generate(256, (index) {
  var crc = index;
  for (var bit = 0; bit < 8; bit++) {
    crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xA001 : crc >>> 1;
  }
  return crc & 0xFFFF;
});
