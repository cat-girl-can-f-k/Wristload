/// 小米运动健康 SPP V2 鉴权握手。
///
/// 依据（2026-08-08 反编译/开源对照）：
/// 来源：官方 App 3.57.0 `WearAuthV2`、`abu`、`bc0`、`hc0`、`nc0`、`ec0`
/// 与用户提供的 n67cn 真机 SPP 日志。不得混用 Gadgetbridge 的直写消息结构。
///
/// 传输层：RFCOMM → L1START → L2(PB, 明文) → 本文件的 `abu` protobuf。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/ccm.dart';

import 'proto_wire.dart';

/// Xiaomi Command 类型与子类型（与 miwear 的 zau e=1 体系对应）。
abstract final class XiaomiAuth {
  static const int commandType = 1;
  static const int cmdSendUserId = 5; // WearAuthV1：直接发 userId
  static const int cmdNonce = 26; // WearAuthV2 step1：发 phoneNonce
  static const int cmdAuth = 27; // step3：发 AuthStep3

  /// 构建官方 `abu{e=1,f=26,bc0.field30=hc0}` 验证请求。
  ///
  /// 与 App WearAuthV2.i()（sendAppVerify）一致：始终发送 16 字节 phone
  /// nonce；只有显式 appDeviceId 存在时才发送 field 2 和 hasOob field 3。
  /// 官方 Classic SppConnection 会传入可空 appDeviceId，且 OOB 为空，
  /// 因此 nonce-only f=26 是有效分支。appDeviceId/OOB 绝不能从 MAC 或
  /// authkey 推导或替代。
  static List<int> buildNonceCommand(
    List<int> nonce, {
    String? appDeviceId,
    bool hasOob = false,
  }) {
    final verify = ProtoWriter()..writeBytes(1, nonce);
    final id = appDeviceId?.trim();
    if (id != null && id.isNotEmpty) {
      verify.writeString(2, id);
      if (hasOob) verify.writeBool(3, true);
    }
    final command = ProtoWriter()..writeMessage(30, verify.bytes);
    final envelope = ProtoWriter()
      ..writeInt(1, commandType)
      ..writeInt(2, cmdNonce)
      ..writeMessage(3, command.bytes);
    return envelope.bytes;
  }

  /// 构建 `Command{type=1, subtype=5, auth{userId}}`（明文鉴权）。
  static List<int> buildSendUserIdCommand(String userId) {
    final auth = ProtoWriter()..writeString(7, userId);
    final cmd = ProtoWriter()
      ..writeInt(1, commandType)
      ..writeInt(2, cmdSendUserId)
      ..writeMessage(3, auth.bytes);
    return cmd.bytes;
  }

  /// 解析官方 `abu → bc0` 回包（field31=verify 响应，field33=confirm 响应）。
  static ParsedAuthCommand? parse(List<int> data) {
    try {
      final r = ProtoReader(data);
      int? type;
      int? subtype;
      int? status;
      int? authStatus;
      List<int>? appNonce;
      List<int>? watchNonce;
      List<int>? watchHmac;
      String? appDeviceId;
      var hasOob = false;
      while (!r.isAtEnd) {
        final (field, wire) = r.readFieldHeader();
        if (field == 1 && wire == 0) {
          type = r.readVarint();
        } else if (field == 2 && wire == 0) {
          subtype = r.readVarint();
        } else if (field == 3 && wire == 2) {
          final command = ProtoReader(r.readBytes());
          while (!command.isAtEnd) {
            final (commandField, commandWire) = command.readFieldHeader();
            if (commandField == 3 && commandWire == 0) {
              authStatus = command.readVarint();
            } else if (commandField == 30 && commandWire == 2) {
              final verify = ProtoReader(command.readBytes());
              while (!verify.isAtEnd) {
                final (verifyField, verifyWire) = verify.readFieldHeader();
                if (verifyField == 1 && verifyWire == 2) {
                  appNonce = verify.readBytes();
                } else if (verifyField == 2 && verifyWire == 2) {
                  appDeviceId =
                      utf8.decode(verify.readBytes(), allowMalformed: true);
                } else if (verifyField == 3 && verifyWire == 0) {
                  hasOob = verify.readVarint() != 0;
                } else {
                  verify.skipField(verifyWire);
                }
              }
            } else if (commandField == 31 && commandWire == 2) {
              final verify = ProtoReader(command.readBytes());
              while (!verify.isAtEnd) {
                final (verifyField, verifyWire) = verify.readFieldHeader();
                if (verifyField == 1 && verifyWire == 2) {
                  watchNonce = verify.readBytes();
                } else if (verifyField == 2 && verifyWire == 2) {
                  watchHmac = verify.readBytes();
                } else {
                  verify.skipField(verifyWire);
                }
              }
            } else if (commandField == 33 && commandWire == 2) {
              final confirm = ProtoReader(command.readBytes());
              while (!confirm.isAtEnd) {
                final (confirmField, confirmWire) = confirm.readFieldHeader();
                if (confirmField == 1 && confirmWire == 0) {
                  authStatus = confirm.readVarint();
                } else {
                  confirm.skipField(confirmWire);
                }
              }
            } else {
              command.skipField(commandWire);
            }
          }
        } else if (field == 100 && wire == 0) {
          status = r.readVarint();
        } else {
          r.skipField(wire);
        }
      }
      return ParsedAuthCommand(
        type: type,
        subtype: subtype,
        status: status,
        authStatus: authStatus,
        appNonce: appNonce,
        appDeviceId: appDeviceId,
        hasOob: hasOob,
        watchNonce: watchNonce,
        watchHmac: watchHmac,
      );
    } catch (_) {
      return null;
    }
  }

  /// HKDF-SHA256（与 APK `WearAuthV2.m53570j` → `o6o.m83454i` →
  /// `nud.m82787f` 一致）：
  /// PRK = HMAC(key=phoneNonce‖watchNonce, data=authkey)，
  /// OKM = Expand(PRK, info="miwear-auth", 64B)，取 64B。
  static List<int> computeStep3Hmac(
    List<int> secretKey,
    List<int> phoneNonce,
    List<int> watchNonce,
  ) {
    final prk =
        Hmac(sha256, [...phoneNonce, ...watchNonce]).convert(secretKey).bytes;
    final info = utf8.encode('miwear-auth');
    final out = <int>[];
    var t = <int>[];
    var b = 1;
    while (out.length < 64) {
      t = Hmac(sha256, prk).convert([...t, ...info, b]).bytes;
      out.addAll(t);
      b++;
    }
    return out.sublist(0, 64);
  }

  static List<int> hmacSha256(List<int> key, List<int> data) =>
      Hmac(sha256, key).convert(data).bytes;

  /// 构建官方 `abu{e=1,f=27,bc0.field32=ec0}` 确认请求。
  ///
  /// 与 App `WearAuthV2.j()+h()` / Gadgetbridge `handleWatchNonce` 一致：
  /// 1. HKDF 派生 DeviceKey/AppKey(16B)+DeviceIV/AppIV(4B)
  /// 2. 校验设备签名 `HMAC(DeviceKey, watchNonce‖phoneNonce)` == watchHmac
  /// 3. signApp = `HMAC(AppKey, phoneNonce‖watchNonce)`
  /// 4. AES-CCM(AppKey, nonce=AppIV‖0‖0, mac=32bit) 加密设备信息
  /// 5. 组装 protobuf。
  ///
  /// 返回 null 表示设备签名校验失败（密钥不匹配）。
  static List<int>? buildAuthStep3Command({
    required List<int> secretKey,
    required List<int> phoneNonce,
    required List<int> watchNonce,
    required List<int> watchHmac,
    int sdkInt = 34,
    String phoneModel = 'XiaoMi',
    String region = 'CN',
    String? oob,
    // 表盘自定义工具在 SPP 模式只声明 0xE0。此前沿用官方完整 App 的
    // 25237220 会向设备宣称本工具并未实现的大量常驻能力；设备确认鉴权后
    // 会立即终止该不完整客户端。跨平台安装器应只声明实际支持的最小集合。
    int appCapability = 224,
  }) {
    final okm = computeStep3Hmac(secretKey, phoneNonce, watchNonce);
    final deviceKey = okm.sublist(0, 16);
    final appKey = okm.sublist(16, 32);
    final appIv = okm.sublist(36, 40);

    // APK appends the independent OOB value to the device-sign input when
    // present. appDeviceId belongs only to f=26 hc0 and must not be reused.
    final deviceSignInput = <int>[...watchNonce, ...phoneNonce];
    final oobValue = oob?.trim();
    if (oobValue != null && oobValue.isNotEmpty) {
      deviceSignInput.addAll(utf8.encode(oobValue));
    }
    final expectedDeviceSign = hmacSha256(deviceKey, deviceSignInput);
    if (!_constTimeEquals(expectedDeviceSign, watchHmac)) {
      return null;
    }

    // signApp = HMAC(AppKey, phoneNonce‖watchNonce)
    final signApp = hmacSha256(appKey, [...phoneNonce, ...watchNonce]);

    // 官方 pe0{field1=0, field2=SDK(float), field3=model,
    // field4=appCapability, field5=region}。
    final deviceInfo = ProtoWriter()
      ..writeInt(1, 0)
      ..writeFloat(2, sdkInt.toDouble())
      ..writeString(3, phoneModel)
      ..writeInt(4, appCapability)
      ..writeString(5, region);

    // AES-CCM：key=AppKey, nonce=AppIV(4B)+0x00000000+0x00000000, mac=32bit
    final nonce = [...appIv, 0, 0, 0, 0, 0, 0, 0, 0];
    final encryptedDeviceInfo = ccmEncrypt(appKey, nonce, deviceInfo.bytes);

    // ec0{signApp=1, encryptedCompanionDevice=2} → bc0.field32.
    final confirm = ProtoWriter()
      ..writeBytes(1, signApp)
      ..writeBytes(2, encryptedDeviceInfo);
    final command = ProtoWriter()..writeMessage(32, confirm.bytes);
    final envelope = ProtoWriter()
      ..writeInt(1, commandType)
      ..writeInt(2, cmdAuth)
      ..writeMessage(3, command.bytes);
    return envelope.bytes;
  }

  /// AES-CCM 加密（AESEngine + CCMBlockCipher，mac 32bit）——pointycastle。
  static List<int> ccmEncrypt(
    List<int> key,
    List<int> nonce,
    List<int> payload,
  ) {
    final engine = AESEngine()
      ..init(true, KeyParameter(Uint8List.fromList(key)));
    final cipher = CCMBlockCipher(engine)
      ..init(
        true,
        AEADParameters(
          KeyParameter(Uint8List.fromList(key)),
          32,
          Uint8List.fromList(nonce),
          Uint8List(0),
        ),
      );
    final out = Uint8List(cipher.getOutputSize(payload.length));
    final len = cipher.processBytes(
        Uint8List.fromList(payload), 0, payload.length, out, 0);
    cipher.doFinal(out, len);
    return out.toList();
  }

  /// 常数时间比较（防时序侧信道，签名校验用）。
  static bool _constTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// 解析 32 hex authkey → 16 字节 secretKey。非法返回 null。
  static List<int>? secretKeyFromHex(String hex) {
    final clean = hex.trim();
    if (clean.length != 32 || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(clean)) {
      return null;
    }
    return [
      for (var i = 0; i < 32; i += 2)
        int.parse(clean.substring(i, i + 2), radix: 16),
    ];
  }
}

/// 解析后的设备回包。
class ParsedAuthCommand {
  const ParsedAuthCommand({
    this.type,
    this.subtype,
    this.status,
    this.authStatus,
    this.appNonce,
    this.appDeviceId,
    this.hasOob = false,
    this.watchNonce,
    this.watchHmac,
  });

  final int? type;
  final int? subtype;
  final int? status;
  final int? authStatus;
  final List<int>? appNonce;
  final String? appDeviceId;
  final bool hasOob;
  final List<int>? watchNonce;
  final List<int>? watchHmac;
}
