import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miwearable_install_tool/domain/protocol/auth_handshake.dart';
import 'package:miwearable_install_tool/domain/protocol/hci_decoder.dart';
import 'package:miwearable_install_tool/domain/protocol/l1_l2_frame.dart';
import 'package:miwearable_install_tool/domain/protocol/mass_transfer.dart';
import 'package:miwearable_install_tool/domain/protocol/session_cipher.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/ccm.dart';
import 'package:miwearable_install_tool/domain/protocol/proto_wire.dart';
import 'package:miwearable_install_tool/domain/protocol/spp_protocol.dart';
import 'package:miwearable_install_tool/domain/protocol/zau.dart';
import 'package:miwearable_install_tool/domain/wear_protocol.dart';

void main() {
  test('private protocol remains disabled until real-device verification', () {
    expect(kProtocolVerified, isFalse);
    expect(() => const VerificationGate().ensureCanSend(), throwsStateError);
  });

  group('proto wire', () {
    test('varint 边界', () {
      final w = ProtoWriter()..writeInt(1, 300);
      expect(w.bytes, [0x08, 0xAC, 0x02]); // tag(1,varint)=0x08, 300=0xAC 0x02
    });

    test('roundtrip', () {
      final w = ProtoWriter();
      w.writeString(1, 'n66cn');
      w.writeInt(2, 42);
      w.writeBytes(3, [1, 2, 3]);
      final r = ProtoReader(w.bytes);
      final f1 = r.readFieldHeader();
      expect(f1, (1, 2));
      expect(r.readString(), 'n66cn');
      final f2 = r.readFieldHeader();
      expect(f2, (2, 0));
      expect(r.readVarint(), 42);
      final f3 = r.readFieldHeader();
      expect(f3, (3, 2));
      expect(r.readBytes(), [1, 2, 3]);
      expect(r.isAtEnd, isTrue);
    });
  });

  group('zau', () {
    test('表盘预装请求字段', () {
      final payload = A9u.withFileInfo(faceId: 'f1', fileSize: 4096);
      expect(payload.$1, 6); // a9u 是 zau 的 oneof field 6
      final zau = Zau(command: 4, sub: 4, payload: payload).encode();
      final parsed = Zau.parse(zau);
      expect(parsed.command, 4);
      expect(parsed.sub, 4);
      expect(parsed.payload!.$1, 6);
    });

    test('setFace', () {
      final zau =
          Zau(command: 4, sub: 1, payload: A9u.withFaceId('f2')).encode();
      final parsed = Zau.parse(zau);
      expect(parsed.command, 4);
      expect(parsed.sub, 1);
      expect(parsed.payload!.$1, 6);
    });

    test('RPK 预装请求', () {
      final zau = Zau(
        command: 20,
        sub: 1,
        payload: V8s.prepareRequest(
          packageName: 'com.example.app',
          versionCode: 3,
          packageSize: 2048,
        ),
      ).encode();
      final parsed = Zau.parse(zau);
      expect(parsed.command, 20);
      expect(parsed.sub, 1);
      expect(parsed.payload!.$1, 22); // v8s 是 zau 的 oneof field 22
    });

    test('MassPrepare 请求', () {
      final md5 = List<int>.generate(16, (i) => i);
      final zau = Zau(
        command: 22,
        sub: 0,
        payload: O1h.prepareRequest(dataType: 0x40, fileMd5: md5, fileLength: 1000),
      ).encode();
      final parsed = Zau.parse(zau);
      expect(parsed.command, 22);
      expect(parsed.payload!.$1, 24); // o1h 是 zau 的 oneof field 24
    });

    test('MassPrepare 响应读取状态、断点与协商分片长度', () {
      final response = ProtoWriter()
        ..writeInt(2, 0)
        ..writeInt(4, 123)
        ..writeInt(5, 4096);
      final parsed = O1h.parsePrepareResponse(response.bytes);
      expect(parsed.prepareStatus, 0);
      expect(parsed.remainLength, 123);
      expect(parsed.expectedSliceLength, 4096);
    });

    test('表盘安装结果解析', () {
      // 构造 x8u: field1=id(f1), field2=code(2)
      final w = ProtoWriter();
      w.writeString(1, 'f1');
      w.writeInt(2, 2);
      // a9u oneof field 7 = x8u
      final a9u = ProtoWriter()..writeBytes(7, w.bytes);
      final result = A9u.parse(a9u.bytes);
      expect(result.kind, 'installResult');
      expect(result.code, 2);
      expect(result.faceId, 'f1');
    });
  });

  group('L1/L2 帧', () {
    test('L1 编码/解析', () {
      final frame = L1Frame(type: L1Type.data, seqNum: 5, payload: [1, 2, 3]);
      final bytes = frame.encode();
      expect(bytes.length, L1Frame.headerSize + 3);
      expect(bytes[0], 0x25); // magic 0xA525 LE
      expect(bytes[1], 0xA5);
      expect(bytes[2], L1Type.data); // type
      expect(bytes[3], 5); // seq
      expect(bytes[4], 3); // dataLength LE
      expect(bytes[5], 0);
      final parsed = L1Frame.parse(bytes)!;
      expect(parsed.type, L1Type.data);
      expect(parsed.seqNum, 5);
      expect(parsed.payload, [1, 2, 3]);
    });

    test('L1 坏 magic 返回 null', () {
      final bytes = L1Frame(type: L1Type.data, seqNum: 0, payload: []).encode();
      bytes[0] = 0x00;
      expect(L1Frame.parse(bytes), isNull);
    });

    test('L2 编码/解析', () {
      final bytes =
          L2Frame(channel: L2Channel.mass, opCode: L2OpCode.writeEnc, payload: [9]).encode();
      expect(bytes, [L2Channel.mass, L2OpCode.writeEnc, 9]);
      final parsed = L2Frame.parse(bytes);
      expect(parsed.channel, L2Channel.mass);
      expect(parsed.opCode, L2OpCode.writeEnc);
      expect(parsed.payload, [9]);
    });
  });

  group('Mass 分片', () {
    test('首片头、尾 CRC 与每片 4B 序号头', () {
      final file = Uint8List.fromList(List<int>.generate(100, (i) => i));
      final md5 = List<int>.generate(16, (i) => 0x10 + i);
      final segs = splitMassFile(
        fileBytes: file,
        dataType: 0x10,
        fileMd5: md5,
        segmentLength: 64,
      );
      expect(segs.length, 3);
      expect(segs.first.isFirst, isTrue);
      expect(segs.last.isLast, isTrue);
      expect(segs.first.total, 3);
      expect(segs.first.index, 1);
      expect(segs.first.data.length, 64);
      expect(segs.first.data.sublist(0, 4), [3, 0, 1, 0]);
      // 分片头之后才是 22B Mass 头。
      expect(segs.first.data[4], 0x00);
      expect(segs.first.data[5], 0x10); // dataType
      // MD5 位置 2..17
      for (var i = 0; i < 16; i++) {
        expect(segs.first.data[6 + i], 0x10 + i);
      }
      // 长度 LE（100 - 0）
      expect(segs.first.data[22], 100);
      expect(segs.first.data[23], 0);
      expect(segs.first.data[24], 0);
      expect(segs.first.data[25], 0);
      // 最后一片为 2B 文件尾 + 4B CRC，另有 4B 分片头。
      expect(segs.last.data.length, 10);
      final expectedCrc = crc32([
        ...buildMassHeader(
          dataType: 0x10,
          fileMd5: md5,
          fileLength: 100,
          sentLength: 0,
        ),
        ...file,
      ]);
      final tail = segs.last.data.sublist(6);
      expect(tail, [
        expectedCrc & 0xFF,
        (expectedCrc >> 8) & 0xFF,
        (expectedCrc >> 16) & 0xFF,
        (expectedCrc >> 24) & 0xFF,
      ]);
    });

    test('单段文件（无头无尾合并）', () {
      final file = Uint8List.fromList(List<int>.generate(10, (i) => i));
      final md5 = List<int>.generate(16, (i) => i);
      final segs = splitMassFile(
        fileBytes: file,
        dataType: 0x40,
        fileMd5: md5,
        segmentLength: 100,
      );
      expect(segs.length, 1);
      expect(segs.single.data.length, 4 + 22 + 10 + 4); // 分片头+数据头+数据+CRC
      expect(segs.single.isFirst, isTrue);
      expect(segs.single.isLast, isTrue);
    });

    test('大文件按 10MB 大块分片', () {
      final file = Uint8List(massChunkSize + 10);
      final md5 = List<int>.generate(16, (i) => i);
      final segs = splitMassFile(
        fileBytes: file,
        dataType: 0x10,
        fileMd5: md5,
        segmentLength: 1024,
      );
      // 每片可容纳 1020B 正文；首块含 22B 头、末块含 4B CRC。
      expect(segs.length, 10282);
      expect(segs.where((s) => s.isFirst).length, 1);
      expect(segs.where((s) => s.isLast).length, 1);
    });

    test('断点续传的首头长度与 CRC 都从断点开始计算', () {
      final file = Uint8List.fromList(List<int>.generate(10, (i) => i));
      final md5 = List<int>.filled(16, 0x22);
      final segs = splitMassFile(
        fileBytes: file,
        dataType: 0x40,
        fileMd5: md5,
        segmentLength: 64,
        sentLength: 4,
      );
      expect(segs, hasLength(1));
      expect(segs.single.data[22], 6); // 4B 分片头后的剩余长度
      final expectedCrc = crc32([
        ...buildMassHeader(
          dataType: 0x40,
          fileMd5: md5,
          fileLength: 10,
          sentLength: 4,
        ),
        ...file.sublist(4),
      ]);
      expect(segs.single.data.sublist(segs.single.data.length - 4), [
        expectedCrc & 0xFF,
        (expectedCrc >> 8) & 0xFF,
        (expectedCrc >> 16) & 0xFF,
        (expectedCrc >> 24) & 0xFF,
      ]);
    });

    test('官方 RPK 日志中的 16384B 协商长度产生 40 片', () {
      // 官方 3.57.0 日志：652002B RPK、type=4/detail=0、切片长度 16384。
      final rpk = Uint8List(652002);
      final segs = splitMassFile(
        fileBytes: rpk,
        dataType: MassDataType.quickAppRpk,
        fileMd5: List<int>.filled(16, 0),
        segmentLength: 16384,
      );
      expect(segs, hasLength(40));
      expect(segs.first.data, hasLength(16384));
      expect(segs.last.data, hasLength(13212));
      expect(segs.last.data.sublist(0, 4), [40, 0, 40, 0]);
    });
  });

  group('L1 帧与 CRC16', () {
    test('CRC-16/IBM 标准向量 123456789 → 0xBB3D', () {
      final data = '123456789'.codeUnits;
      expect(computeCrc16(data), 0xBB3D);
      // 空数据 CRC=0
      expect(computeCrc16(const []), 0);
    });

    test('L1START 请求帧结构与载荷', () {
      final frame = L1StartRequest.build();
      final bytes = frame.encode();
      // 8B 头 + 22B payload
      expect(bytes.length, 30);
      // magic 0xA525 LE
      expect(bytes[0], 0x25);
      expect(bytes[1], 0xA5);
      // type=CMD(2)
      expect(bytes[2] & 0x0F, L1Type.cmd);
      // dataLength=22 LE
      expect(bytes[4], 22);
      expect(bytes[5], 0);
      // payload[0] = CMD_L1START_REQ
      expect(bytes[8], L1Cmd.startReq);
      // payload 21B 配置：VERSION(1) 3B [1,0,0]
      expect(bytes[9], 0x01);
      expect(bytes[12], 1);
      expect(bytes[13], 0);
      expect(bytes[14], 0);
      // MPS(2) 2B LE = 64512 (0xFC00)，位于 config[9..10] → bytes[18..19]
      expect(bytes[18], 0x00);
      expect(bytes[19], 0xFC);
      // 帧可回读
      final parsed = L1Frame.parse(bytes);
      expect(parsed, isNotNull);
      expect(parsed!.payload.length, 22);
      expect(parsed.payload.first, L1Cmd.startReq);
    });
  });

  group('会话 AES-CTR', () {
    test('计数块采用 IV + LE32 counter + 8B 零', () {
      expect(
        buildSessionCounterBlock([1, 2, 3, 4], 0x78563412),
        [1, 2, 3, 4, 0x12, 0x34, 0x56, 0x78, 0, 0, 0, 0, 0, 0, 0, 0],
      );
    });

    test('AES-CTR 使用正确方向的密钥且可逆', () {
      final keys = SessionKeys(
        deviceKey: List<int>.filled(16, 0x11),
        appKey: List<int>.filled(16, 0x22),
        deviceIv: [1, 2, 3, 4],
        appIv: [5, 6, 7, 8],
      );
      final cipher = SessionCipher(keys);
      final message = List<int>.generate(37, (index) => index);
      final encoded = cipher.encryptOutbound(message, counter: 1);
      expect(encoded, isNot(message));

      // CTR 同一 key/IV/counter 变换两次即可恢复明文。
      final appSide = SessionKeys(
        deviceKey: keys.appKey,
        appKey: keys.deviceKey,
        deviceIv: keys.appIv,
        appIv: keys.deviceIv,
      );
      expect(
        SessionCipher(appSide).decryptInbound(encoded, counter: 1),
        message,
      );
    });

    test('HKDF 输出可拆分为会话材料', () {
      final keys = SessionKeys.fromHkdf(List<int>.generate(64, (i) => i));
      expect(keys.deviceKey, List<int>.generate(16, (i) => i));
      expect(keys.appKey, List<int>.generate(16, (i) => 16 + i));
      expect(keys.deviceIv, [32, 33, 34, 35]);
      expect(keys.appIv, [36, 37, 38, 39]);
    });
  });

  group('离线 HCI 解码', () {
    test('重组 btsnoop 的 RFCOMM/L1 帧并识别 f=26 请求', () {
      final nonce = List<int>.generate(16, (i) => i);
      final l1 = SppProtocol.buildDataFrame(0, XiaomiAuth.buildNonceCommand(nonce));
      final rfcomm = <int>[0x2b, 0xff, (l1.length << 1) | 1, 1, ...l1, 0];
      final l2 = <int>[rfcomm.length, 0, 0x49, 0, ...rfcomm];
      final hci = <int>[2, 2, 0, l2.length, 0, ...l2];
      final record = <int>[
        0, 0, 0, hci.length, // original length, BE
        0, 0, 0, hci.length, // included length, BE
        0, 0, 0, 0, // outbound flag
        0, 0, 0, 0, // drops
        0, 0, 0, 0, 0, 0, 0, 0, // timestamp
        ...hci,
      ];
      final hciLike = Uint8List.fromList([
        ...'btsnoop\x00'.codeUnits,
        0, 0, 0, 1, 0, 0, 3, 0xea,
        ...record,
      ]);
      final report = const HciDecoder().decode(
        hciBytes: hciLike,
        authKeyHex: '00112233445566778899aabbccddeeff',
      );
      expect(report.l1Frames, 1);
      expect(report.sessions, 0);
      expect(report.lines, contains('发现 f=26 请求：等待同会话设备随机数。'));
    });
  });

  group('Xiaomi 直写鉴权握手', () {
    test('buildNonceCommand 编码与回读', () {
      final nonce = List<int>.generate(16, (i) => i);
      final cmd = XiaomiAuth.buildNonceCommand(nonce);
      // Command{type=1, subtype=26, auth{phoneNonce{nonce}}}
      final parsed = XiaomiAuth.parse(cmd);
      expect(parsed, isNotNull);
      expect(parsed!.type, 1);
      expect(parsed.subtype, 26);
      expect(parsed.watchNonce, isNull); // 自己发的没有 watchNonce
      // 用解析器读回非空 nonce 需要扩展；此处验证编码字节数合理
      expect(cmd.length, greaterThan(20));
    });

    test('buildSendUserIdCommand 编码', () {
      final cmd = XiaomiAuth.buildSendUserIdCommand('1234567890');
      final parsed = XiaomiAuth.parse(cmd);
      expect(parsed, isNotNull);
      expect(parsed!.type, 1);
      expect(parsed.subtype, 5);
    });

    test('secretKeyFromHex 解析 32 hex', () {
      expect(XiaomiAuth.secretKeyFromHex('067aac12' * 4), isNotNull);
      expect(XiaomiAuth.secretKeyFromHex('067aac12' * 4)!.length, 16);
      expect(XiaomiAuth.secretKeyFromHex('zz'), isNull);
      expect(XiaomiAuth.secretKeyFromHex('0' * 30), isNull);
    });

    test('computeStep3Hmac 输出 64B 且稳定', () {
      final sk = List<int>.generate(16, (i) => i);
      final pn = List<int>.generate(16, (i) => 0x10 + i);
      final wn = List<int>.generate(16, (i) => 0x20 + i);
      final out = XiaomiAuth.computeStep3Hmac(sk, pn, wn);
      expect(out.length, 64);
      final out2 = XiaomiAuth.computeStep3Hmac(sk, pn, wn);
      expect(out, out2);
    });

    test('parse 设备 watchNonce 回包', () {
      // 构造 Command{type=1, subtype=26, auth{watchNonce{nonce,hmac}}}
      final watchNonce = ProtoWriter()
        ..writeBytes(1, List<int>.generate(16, (i) => i))
        ..writeBytes(2, List<int>.generate(32, (i) => 0x80 + i));
      final auth = ProtoWriter()..writeMessage(31, watchNonce.bytes);
      final cmd = ProtoWriter()
        ..writeInt(1, 1)
        ..writeInt(2, 26)
        ..writeMessage(3, auth.bytes);
      final parsed = XiaomiAuth.parse(cmd.bytes);
      expect(parsed, isNotNull);
      expect(parsed!.type, 1);
      expect(parsed.subtype, 26);
      expect(parsed.watchNonce, isNotNull);
      expect(parsed.watchNonce!.length, 16);
      expect(parsed.watchHmac!.length, 32);
    });
  });

  group('Xiaomi f=27 sendAppConfirm', () {
    test('签名校验失败返回 null', () {
      final cmd = XiaomiAuth.buildAuthStep3Command(
        secretKey: List<int>.generate(16, (i) => i),
        phoneNonce: List<int>.generate(16, (i) => 0x10 + i),
        watchNonce: List<int>.generate(16, (i) => 0x20 + i),
        watchHmac: List<int>.generate(32, (i) => 0x40 + i), // 错误的 hmac
      );
      expect(cmd, isNull);
    });

    test('正确 watchHmac 生成 f=27 报文', () {
      final secretKey = List<int>.generate(16, (i) => i);
      final phoneNonce = List<int>.generate(16, (i) => 0x10 + i);
      final watchNonce = List<int>.generate(16, (i) => 0x20 + i);
      // 设备签名 = HMAC(DeviceKey, watchNonce‖phoneNonce)
      final okm = XiaomiAuth.computeStep3Hmac(secretKey, phoneNonce, watchNonce);
      final deviceKey = okm.sublist(0, 16);
      final watchHmac = XiaomiAuth.hmacSha256(deviceKey, [...watchNonce, ...phoneNonce]);
      final cmd = XiaomiAuth.buildAuthStep3Command(
        secretKey: secretKey,
        phoneNonce: phoneNonce,
        watchNonce: watchNonce,
        watchHmac: watchHmac,
      );
      expect(cmd, isNotNull);
      expect(cmd!.first, 0x08); // type=1 varint tag
      expect(cmd[1], 0x01); // type=1
      expect(cmd[2], 0x10); // field2 tag
      expect(cmd[3], 0x1b); // subtype=27
      // 长度应 > 60B（signApp 32B + CCM 密文 ~30B + 头）
      expect(cmd.length, greaterThan(60));
    });

    test('AES-CCM 加密可解', () {
      final key = List<int>.generate(16, (i) => i);
      final nonce = [0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0];
      final plain = [1, 2, 3, 4, 5];
      final enc = XiaomiAuth.ccmEncrypt(key, nonce, plain);
      expect(enc.length, greaterThanOrEqualTo(plain.length + 4));
      // 解密验证（用同一个 CCM 解密）
      final engine = AESEngine()..init(false, KeyParameter(Uint8List.fromList(key)));
      final cipher = CCMBlockCipher(engine)
        ..init(
          false,
          AEADParameters(
            KeyParameter(Uint8List.fromList(key)),
            32,
            Uint8List.fromList(nonce),
            Uint8List(0),
          ),
        );
      final out = Uint8List(cipher.getOutputSize(enc.length));
      final len = cipher.processBytes(Uint8List.fromList(enc), 0, enc.length, out, 0);
      cipher.doFinal(out, len);
      final dec = out.take(plain.length).toList();
      expect(dec, plain);
    });
  });

  group('SPP L1 帧（App TransportL1）', () {
    test('L1START_REQ 帧头 A5 A5、参数和官方 SPP 日志一致', () {
      final frame = SppProtocol.buildL1StartRequest();
      // 8B 头 + 1B cmd + 21B config = 30B
      expect(frame.length, 30);
      expect(frame[0], 0xa5);
      expect(frame[1], 0xa5);
      expect(frame[2], 0x02); // type=CMD
      expect(frame[3], 0x00); // seq=0
      final len = frame[4] | (frame[5] << 8);
      expect(len, 22);
      // 官方 3.57.0 / n67cn 日志：CMD size=22, crc=19741 (0x4D1D)。
      expect(frame[6] | (frame[7] << 8), 0x4d1d);
      expect(frame[8], 1); // cmd=L1START_REQ
    });

    test('DATA 帧 L2Packet 封装 channel=1 opCode=1', () {
      final frame = SppProtocol.buildDataFrame(1, [0x08, 0x01, 0x10, 0x1a]);
      expect(frame[0], 0xa5);
      expect(frame[1], 0xa5);
      expect(frame[2], 0x03); // type=DATA
      expect(frame[3], 0x01); // seq=1
      final len = frame[4] | (frame[5] << 8);
      expect(len, 2 + 4); // channel + opCode + protobuf
      expect(frame[8], 1); // channel=PB
      expect(frame[9], 1); // opCode=WRITE
      expect(frame[10], 0x08);
    });

    test('ACK 帧使用 V2 纯 type=1 格式', () {
      final frame = SppProtocol.buildAck(3);
      expect(frame.length, 8);
      expect(frame[2], 0x01);
      expect(frame[3], 3);
    });

    test('parse 增量解析', () {
      final acc = Accumulator();
      acc.buffer = [
        ...SppProtocol.buildL1StartRequest(),
        ...SppProtocol.buildDataFrame(1, [1, 2, 3]),
      ];
      final packets = SppProtocol.parse(acc);
      expect(packets.length, 2);
      expect(packets[0].type, 2);
      expect(packets[0].payload[0], 1);
      expect(packets[1].type, 3);
      expect(packets[1].seq, 1);
      expect(acc.buffer.length, 0);
    });
  });

  group('SPP 版本查询（SppPacket）', () {
    test('版本查询帧结构', () {
      final frame = SppProtocol.buildVersionQuery(1);
      expect(frame, [0xba, 0xdc, 0xfe, 0x00, 0xc0, 0x04, 0x00, 0x00, 0x00, 0x00, 0x01, 0xef]);
    });

    test('解析设备版本回包 type=106', () {
      // 14 字节：3 magic + 2 header + 2 dataLen(6) + 3 type/c/d + 3 payload + 1 end
      final resp = [0xba, 0xdc, 0xfe, 0x00, 0xc0, 0x06, 0x00, 0x6a, 0x00, 0x00, 0x01, 0x02, 0x03, 0xef];
      final packet = SppProtocol.parseSppPacket(resp);
      expect(packet, isNotNull);
      final (type, payload) = packet!;
      expect(type, 106);
      expect(payload, [1, 2, 3]);
    });
  });
}
