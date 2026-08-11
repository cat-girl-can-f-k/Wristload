/// 本地 btsnoop/HCI 安装会话解码器。
///
/// 解析 btsnoop 记录的方向、ACL/L2CAP/RFCOMM 分段，再从 L1 流中恢复会话。
/// 它不访问网络、不保存 authkey，也不会产生任何蓝牙写入。
library;

import 'dart:typed_data';

import 'auth_handshake.dart';
import 'transport_constants.dart' show computeCrc16;
import 'session_cipher.dart';
import 'spp_protocol.dart';

/// Shared input ceiling for the UI and command-line decoder. HCI captures are
/// processed fully in memory, so callers must reject larger files before read.
const int maxHciCaptureBytes = 512 * 1024 * 1024;

class HciDecodeReport {
  const HciDecodeReport({
    required this.l1Frames,
    required this.sessions,
    required this.encryptedFrames,
    required this.massFrames,
    required this.lines,
  });
  final int l1Frames;
  final int sessions;
  final int encryptedFrames;
  final int massFrames;
  final List<String> lines;
}

class HciDecoder {
  const HciDecoder();

  HciDecodeReport decode({
    required Uint8List hciBytes,
    required String authKeyHex,
  }) {
    final secret = XiaomiAuth.secretKeyFromHex(authKeyHex);
    if (secret == null) throw const FormatException('authkey 必须为 32 位十六进制');
    final l1 = _extractL1Frames(hciBytes);
    final lines = <String>[];
    List<int>? appNonce;
    List<int>? watchNonce;
    SessionCipher? cipher;
    var sessions = 0;
    var encrypted = 0;
    var massFrames = 0;

    for (final frame in l1) {
      if (frame.type != SppProtocol.typeData || frame.payload.length < 2) {
        continue;
      }
      final channel = frame.payload[0] & 0x0f;
      final opCode = frame.payload[1];
      final data = frame.payload.sublist(2);
      if (channel == SppProtocol.channelMass) {
        massFrames++;
        _describeMassFrame(
          lines,
          seq: frame.seq,
          outbound: frame.outbound,
          opCode: opCode,
          data: data,
        );
        continue;
      }
      if (channel != SppProtocol.channelPb) continue;

      if (opCode == SppProtocol.opCodeWrite) {
        final command = XiaomiAuth.parse(data);
        if (frame.outbound &&
            command?.type == XiaomiAuth.commandType &&
            command?.subtype == XiaomiAuth.cmdNonce &&
            command?.appNonce != null) {
          appNonce = command!.appNonce;
          watchNonce = null;
          cipher = null;
          lines.add('发现 f=26 请求：等待同会话设备随机数。');
        } else if (!frame.outbound &&
            command?.type == XiaomiAuth.commandType &&
            command?.subtype == XiaomiAuth.cmdNonce &&
            command?.watchNonce != null &&
            appNonce != null) {
          watchNonce = command!.watchNonce;
          lines.add('发现 f=26 响应：设备随机数已匹配。');
        } else if (!frame.outbound &&
            command?.type == XiaomiAuth.commandType &&
            command?.subtype == XiaomiAuth.cmdAuth &&
            command?.authStatus == 1 &&
            appNonce != null &&
            watchNonce != null) {
          cipher = SessionCipher(SessionKeys.fromHkdf(
            XiaomiAuth.computeStep3Hmac(secret, appNonce, watchNonce),
          ));
          sessions++;
          lines.add('会话 #$sessions 已确认；开始只读检查 WRITE_ENC。');
        }
        continue;
      }

      if (opCode != SppProtocol.opCodeWriteEnc || cipher == null) continue;
      encrypted++;
      final hit = _decryptInstallCommand(
        cipher,
        data,
        outbound: frame.outbound,
      );
      if (hit != null) {
        final direction = frame.outbound ? '手机→设备' : '设备→手机';
        lines.add('安装业务命中：$direction，L1 seq=${frame.seq}，'
            'command=${hit.type}/${hit.subtype}，${data.length}B。');
        lines.add('  PB 明文：${hit.plaintextHex}');
      }
    }
    if (sessions == 0) lines.add('未找到可由该 authkey 配对的完整 f=26/f=27 会话。');
    if (encrypted == 0) {
      lines.add('未发现 PB WRITE_ENC 帧；该抓包可能不包含安装业务。');
    } else if (!lines.any((line) => line.startsWith('安装业务命中：'))) {
      lines.add('发现 $encrypted 个 WRITE_ENC 帧，但未命中已知安装命令。');
    }
    return HciDecodeReport(
        l1Frames: l1.length,
        sessions: sessions,
        encryptedFrames: encrypted,
        massFrames: massFrames,
        lines: lines);
  }

  void _describeMassFrame(
    List<String> lines, {
    required int seq,
    required bool outbound,
    required int opCode,
    required List<int> data,
  }) {
    // Mass 的外层在官方 TaskQueueV2 中属于 channel=2；文件分片本身是
    // 明文 payload（[total:uint16LE][index:uint16LE] ...）。这里只读展示，
    // 不将未知帧当作可发送模板。
    if (opCode != SppProtocol.opCodeWrite || data.length < 4) return;
    final total = data[0] | (data[1] << 8);
    final index = data[2] | (data[3] << 8);
    if (total == 0 || index == 0 || index > total) return;
    final direction = outbound ? '手机→设备' : '设备→手机';
    if (index == 1 && data.length >= 26) {
      final type = data[5];
      final length =
          data[22] | (data[23] << 8) | (data[24] << 16) | (data[25] << 24);
      lines.add('Mass 首片：$direction，L1 seq=$seq，$index/$total，'
          'dataType=0x${type.toRadixString(16).padLeft(2, '0')}，'
          '声明剩余=$length B。');
    }
  }

  _DecryptHit? _decryptInstallCommand(SessionCipher cipher, List<int> encrypted,
      {required bool outbound}) {
    final plaintext = outbound
        ? cipher.encryptOutbound(encrypted) // CTR 解密=加密
        : cipher.decryptInbound(encrypted);
    final command = XiaomiAuth.parse(plaintext);
    if (command == null || !_isInstallCommand(command)) return null;
    return _DecryptHit(
      command.type!,
      command.subtype!,
      plaintext.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' '),
    );
  }

  bool _isInstallCommand(ParsedAuthCommand command) {
    final type = command.type;
    final sub = command.subtype;
    return (type == 4 && (sub == 1 || sub == 4 || sub == 5)) ||
        (type == 20 && sub == 1) ||
        (type == 22 && (sub == 0 || sub == 1));
  }

  List<_L1Frame> _extractL1Frames(Uint8List bytes) {
    final records = _btsnoopRecords(bytes);
    final pending = <String, _L2Pending>{};
    final rfcommStreams = <String, List<int>>{};
    final frames = <_L1Frame>[];
    for (final record in records) {
      final data = record.data;
      if (data.length < 5 || data[0] != 2) continue; // HCI ACL
      final handleFlags = _le16(data, 1);
      final handle = handleFlags & 0x0fff;
      final pb = (handleFlags >> 12) & 0x03;
      final aclLength = _le16(data, 3);
      if (data.length < 5 + aclLength) continue;
      final acl = data.sublist(5, 5 + aclLength);
      final key = '${record.outbound}:$handle';
      if (pb != 1) {
        if (acl.length < 4) continue;
        final length = _le16(acl, 0);
        pending[key] =
            _L2Pending(record.outbound, _le16(acl, 2), length, acl.sublist(4));
      } else {
        final partial = pending[key];
        if (partial == null) continue;
        partial.data.addAll(acl);
      }
      final complete = pending[key];
      if (complete == null || complete.data.length < complete.length) continue;
      pending.remove(key);
      _consumeRfcomm(complete, rfcommStreams, frames);
    }
    return frames;
  }

  void _consumeRfcomm(
      _L2Pending pdu, Map<String, List<int>> streams, List<_L1Frame> frames) {
    final bytes = pdu.data.sublist(0, pdu.length);
    for (var offset = 0; offset + 4 <= bytes.length;) {
      final address = bytes[offset];
      final control = bytes[offset + 1];
      final firstLength = bytes[offset + 2];
      final header = (firstLength & 1) == 1 ? 3 : 4;
      if (offset + header > bytes.length) break;
      final length = header == 3
          ? firstLength >> 1
          : (firstLength >> 1) | (bytes[offset + 3] << 7);
      // UIH 的 P/F 位为 1 时，信息段前还有 1B credit。该字节不属于 L1。
      final creditBytes = (control & 0x10) != 0 ? 1 : 0;
      final dataStart = offset + header + creditBytes;
      final end = dataStart + length + 1; // + RFCOMM FCS
      if (end > bytes.length) break;
      if ((control & 0xef) == 0xef && length > 0) {
        final streamKey = '${pdu.outbound}:${pdu.cid}:${address >> 2}';
        final stream = streams.putIfAbsent(streamKey, () => <int>[]);
        stream.addAll(bytes.sublist(dataStart, dataStart + length));
        _consumeL1Stream(stream, pdu.outbound, frames);
      }
      offset = end;
    }
  }

  void _consumeL1Stream(
      List<int> stream, bool outbound, List<_L1Frame> frames) {
    var offset = 0;
    while (offset + SppProtocol.headerSize <= stream.length) {
      if (stream[offset] != 0xa5 || stream[offset + 1] != 0xa5) {
        offset++;
        continue;
      }
      final length = stream[offset + 4] | (stream[offset + 5] << 8);
      final end = offset + SppProtocol.headerSize + length;
      if (length > 64512 || end > stream.length) break;
      final payload = stream.sublist(offset + SppProtocol.headerSize, end);
      final crc = stream[offset + 6] | (stream[offset + 7] << 8);
      if (computeCrc16(payload) == crc) {
        frames.add(_L1Frame(
            stream[offset + 2] & 0x0f, stream[offset + 3], payload, outbound));
      }
      offset = end;
    }
    // 已完整消费的帧不能在下一个 RFCOMM 分段到来时再次解析；保留不完整尾帧。
    if (offset > 0) stream.removeRange(0, offset);
    // 无完整帧时只保留可能构成 L1 头的尾部，限制损坏抓包的内存占用。
    if (stream.length > 70000) stream.removeRange(0, stream.length - 70000);
  }

  List<_SnoopRecord> _btsnoopRecords(Uint8List bytes) {
    final out = <_SnoopRecord>[];
    for (var offset = 16; offset + 24 <= bytes.length;) {
      final original = _be32(bytes, offset);
      final included = _be32(bytes, offset + 4);
      final flags = _be32(bytes, offset + 8);
      if (original != included ||
          included < 3 ||
          included > 70000 ||
          flags > 3 ||
          offset + 24 + included > bytes.length) {
        offset++;
        continue;
      }
      final data = bytes.sublist(offset + 24, offset + 24 + included);
      if (!_validHciRecord(data)) {
        offset++;
        continue;
      }
      out.add(_SnoopRecord(flags == 0, data));
      offset += 24 + included;
    }
    return out;
  }

  bool _validHciRecord(List<int> data) {
    if (data.isEmpty) return false;
    return switch (data[0]) {
      1 when data.length >= 4 => data.length == 4 + data[3],
      2 when data.length >= 5 => data.length == 5 + _le16(data, 3),
      3 when data.length >= 4 => data.length == 4 + data[3],
      4 when data.length >= 3 => data.length == 3 + data[2],
      _ => false,
    };
  }

  int _le16(List<int> data, int offset) =>
      data[offset] | (data[offset + 1] << 8);
  int _be32(List<int> data, int offset) =>
      (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];
}

class _SnoopRecord {
  const _SnoopRecord(this.outbound, this.data);
  final bool outbound;
  final List<int> data;
}

class _L2Pending {
  _L2Pending(this.outbound, this.cid, this.length, List<int> first)
      : data = [...first];
  final bool outbound;
  final int cid;
  final int length;
  final List<int> data;
}

class _L1Frame {
  const _L1Frame(this.type, this.seq, this.payload, this.outbound);
  final int type;
  final int seq;
  final List<int> payload;
  final bool outbound;
}

class _DecryptHit {
  const _DecryptHit(this.type, this.subtype, this.plaintextHex);
  final int type;
  final int subtype;
  final String plaintextHex;
}
