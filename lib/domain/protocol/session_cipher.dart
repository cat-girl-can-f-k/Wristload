/// 已鉴权会话的业务帧密码工具。
///
/// 此文件只负责字节变换，不负责计数器持久化或发送。调用方必须从已经
/// 验证的会话中取得计数器，避免为了“猜中”计数器而向设备发送帧。
library;

import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/stream/ctr.dart';

/// WearAuthV2 派生出的四段会话材料。
///
/// HKDF 输出布局已由鉴权握手验证：DeviceKey、AppKey、DeviceIV、AppIV。
class SessionKeys {
  const SessionKeys({
    required this.deviceKey,
    required this.appKey,
    required this.deviceIv,
    required this.appIv,
  })  : assert(deviceKey.length == 16),
        assert(appKey.length == 16),
        assert(deviceIv.length == 4),
        assert(appIv.length == 4);

  factory SessionKeys.fromHkdf(List<int> hkdf) {
    if (hkdf.length < 40) {
      throw ArgumentError.value(hkdf.length, 'hkdf.length', '至少需要 40 字节');
    }
    return SessionKeys(
      deviceKey: hkdf.sublist(0, 16),
      appKey: hkdf.sublist(16, 32),
      deviceIv: hkdf.sublist(32, 36),
      appIv: hkdf.sublist(36, 40),
    );
  }

  final List<int> deviceKey;
  final List<int> appKey;
  final List<int> deviceIv;
  final List<int> appIv;
}

/// 构建 V2 AES-CTR 的 16B 初始计数块。
///
/// 固件/客户端的公开可观察布局为 `IV(4) | counter(LE32) | 0(8)`。
/// AES-CTR 在每个 AES 块后由底层 CTR 模式递增该 128 位计数块。
Uint8List buildSessionCounterBlock(List<int> iv, int counter) {
  if (iv.length != 4) {
    throw ArgumentError.value(iv.length, 'iv.length', '必须为 4 字节');
  }
  if (counter < 0 || counter > 0xffffffff) {
    throw ArgumentError.value(counter, 'counter', '必须为 uint32');
  }
  return Uint8List.fromList([
    ...iv,
    counter & 0xff,
    (counter >> 8) & 0xff,
    (counter >> 16) & 0xff,
    (counter >> 24) & 0xff,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ]);
}

/// 单个业务帧的 AES-CTR 编码器。
///
/// AES-CTR 加解密相同；发送方使用 AppKey/AppIV，接收方使用
/// DeviceKey/DeviceIV。每个调用明确要求 counter，避免本类隐式改变
/// 会话状态。
class SessionCipher {
  const SessionCipher(this.keys);

  final SessionKeys keys;

  List<int> encryptOutbound(List<int> plaintext, {required int counter}) =>
      _transform(plaintext, key: keys.appKey, iv: keys.appIv, counter: counter);

  List<int> decryptInbound(List<int> ciphertext, {required int counter}) =>
      _transform(ciphertext, key: keys.deviceKey, iv: keys.deviceIv, counter: counter);

  static List<int> _transform(
    List<int> input, {
    required List<int> key,
    required List<int> iv,
    required int counter,
  }) {
    final cipher = CTRStreamCipher(AESEngine())
      ..init(
        true,
        ParametersWithIV<KeyParameter>(
          KeyParameter(Uint8List.fromList(key)),
          buildSessionCounterBlock(iv, counter),
        ),
      );
    final source = Uint8List.fromList(input);
    final output = Uint8List(source.length);
    cipher.processBytes(source, 0, source.length, output, 0);
    return output;
  }
}
