import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:miwearable_install_tool/domain/protocol/auth_handshake.dart';
import 'package:miwearable_install_tool/domain/protocol/l1_l2_frame.dart';
import 'package:miwearable_install_tool/domain/protocol/mass_transfer.dart';
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
    test('首片头 22B + 尾 CRC 4B', () {
      final file = Uint8List.fromList(List<int>.generate(100, (i) => i));
      final md5 = List<int>.generate(16, (i) => 0x10 + i);
      final segs = splitMassFile(
        fileBytes: file,
        dataType: 0x10,
        fileMd5: md5,
        segmentLength: 64,
      );
      expect(segs.length, 2);
      expect(segs.first.isFirst, isTrue);
      expect(segs.last.isLast, isTrue);
      // 首片：22B 头 + 64B 数据（数据段长=segmentLength，头附加在外）
      expect(segs.first.data.length, 22 + 64);
      expect(segs.first.data[0], 0x00);
      expect(segs.first.data[1], 0x10); // dataType
      // MD5 位置 2..17
      for (var i = 0; i < 16; i++) {
        expect(segs.first.data[2 + i], 0x10 + i);
      }
      // 长度 LE（100 - 0）
      expect(segs.first.data[18], 100);
      expect(segs.first.data[19], 0);
      expect(segs.first.data[20], 0);
      expect(segs.first.data[21], 0);
      // 尾片：36B 数据 + 4B CRC（首段已带走 64B）
      expect(segs.last.data.length, 36 + 4);
      final expectedCrc = crc32(List<int>.generate(100, (i) => i));
      final tail = segs.last.data.sublist(36);
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
      expect(segs.single.data.length, 22 + 10 + 4); // 头+数据+CRC
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
      // 10MB/1024 = 10240 段 + 第二块 1 段
      expect(segs.length, 10241);
      expect(segs.where((s) => s.isFirst).length, 1);
      expect(segs.where((s) => s.isLast).length, 1);
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
