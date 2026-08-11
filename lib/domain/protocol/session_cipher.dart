/// 已鉴权会话的业务帧密码工具。
///
/// 此文件只负责字节变换，不负责发送。V2 业务通道的 AES-CTR 初始块为
/// 同方向 16B 密钥本身；没有额外的包计数器字段。
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

/// 单个业务帧的 AES-CTR 编码器。
///
/// V2 的 Android 实现等价于 `AES/CTR/NoPadding(key, key, data)`：发送
/// 使用 AppKey，接收使用 DeviceKey。保留 IV 字段是因为会话派生材料也供
/// 旧版本通道使用；它们不参与这里的 V2 变换。
class SessionCipher {
  const SessionCipher(this.keys);

  final SessionKeys keys;

  List<int> encryptOutbound(List<int> plaintext) =>
      _transform(plaintext, directionKey: keys.appKey);

  List<int> decryptInbound(List<int> ciphertext) =>
      _transform(ciphertext, directionKey: keys.deviceKey);

  static List<int> _transform(
    List<int> input, {
    required List<int> directionKey,
  }) {
    final cipher = CTRStreamCipher(AESEngine())
      ..init(
        true,
        ParametersWithIV<KeyParameter>(
          KeyParameter(Uint8List.fromList(directionKey)),
          Uint8List.fromList(directionKey),
        ),
      );
    final source = Uint8List.fromList(input);
    final output = Uint8List(source.length);
    cipher.processBytes(source, 0, source.length, output, 0);
    return output;
  }
}
