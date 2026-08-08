/// zau 命令消息及表盘 / RPK / Mass 载荷的构建与解析。
///
/// 与小米运动健康 APK 中 protobuf nano 消息一一对应（仅字段号与含义，
/// 全部独立实现，不复制任何 APK 代码）：
///
/// - `zau`   ：f1=命令号 e、f2=子命令 f、oneof 载荷（f6=a9u 表盘、f22=v8s RPK、f24=o1h Mass）
/// - `a9u`   ：表盘载荷。oneof：f2=faceId、f5=code、f6=y8u(预装)、f7=x8u(结果)、f9=z8u(错误)
/// - `y8u`   ：表盘文件信息。f1=faceId、f2=fileSize、f3=long、f4=int、f5=message
/// - `x8u`   ：表盘安装结果。id/code/canReplace（设备推送，解析用）
/// - `v8s`   ：RPK 载荷。oneof：f2=j8s(预装请求)、f3=k8s(预装响应)
/// - `j8s`   ：RPK 预装请求。f1=packageName、f2=versionCode、f3=packageSize
/// - `k8s`   ：RPK 预装响应。f1=status、f2=expectedSliceLength
/// - `o1h`   ：Mass 载荷。oneof：f1=s1h(MassPrepare 请求)、f2=u1h(响应)、f3=q1h(取消)
/// - `s1h`   ：MassPrepare 请求。f1=dataType、f2=md5、f3=fileLength、f4=0
/// - `u1h`   ：MassPrepare 响应。f1=bytes、f2=prepareStatus、f3=…、f4=remainLength、f5=expectedSliceLength
/// - `q1h`   ：Mass 取消。f1=code、f2=…
///
/// int 编码按 [IntEncoding]（见 proto_wire.dart 顶部说明，待真机验证）。
library;

import 'proto_wire.dart';

/// 表盘 / RPK / Mass 命令号（zau.e）。
abstract final class ZauCommand {
  static const int setFace = 4; // 表盘：预装(f=4) / setFace(f=1)
  static const int prepareInstallApp = 20; // RPK 预装
  static const int massTransfer = 22; // Mass 文件传输（MassPrepare/MassData 控制）
}

/// 业务 dataType（Mass 文件头，type*16+detailType）。
abstract final class MassDataType {
  static const int watchface = 0x10; // type=1, detailType=0
  static const int quickAppRpk = 0x40; // type=4, detailType=0
}

/// zau 外层命令。f1=e 命令号、f2=f 子命令、oneof 载荷。
class Zau {
  Zau({required this.command, this.sub = 0, this.payload});

  final int command;
  final int sub;

  /// oneof 载荷：值为 (fieldNumber, bytes)。
  final (int, List<int>)? payload;

  List<int> encode([IntEncoding enc = IntEncoding.varint]) {
    final w = ProtoWriter();
    w.writeInt(1, command);
    w.writeIntEncoded(2, sub, enc);
    final p = payload;
    if (p != null) {
      w.writeMessage(p.$1, p.$2);
    }
    return w.bytes;
  }

  static Zau parse(List<int> data, [IntEncoding enc = IntEncoding.varint]) {
    final r = ProtoReader(data);
    var command = 0;
    var sub = 0;
    (int, List<int>)? payload;
    while (!r.isAtEnd) {
      final (field, wt) = r.readFieldHeader();
      switch ((field, wt)) {
        case (1, 0):
          command = r.readVarint();
        case (2, 0):
          sub = r.readVarint();
        case (_, 2):
          payload = (field, r.readBytes());
        default:
          r.skipField(wt);
      }
    }
    return Zau(command: command, sub: sub, payload: payload);
  }
}

/// 表盘载荷 a9u（zau oneof field 6）。
abstract final class A9u {
  static (int, List<int>) withFileInfo({
    required String faceId,
    required int fileSize,
    IntEncoding enc = IntEncoding.varint,
  }) {
    final w = ProtoWriter();
    w.writeString(1, faceId);
    w.writeIntEncoded(2, fileSize, enc);
    return (6, w.bytes);
  }

  static (int, List<int>) withFaceId(String faceId) {
    final w = ProtoWriter();
    w.writeString(2, faceId);
    return (6, w.bytes);
  }

  /// 解析表盘预装响应/结果。返回 (kind, code/id…)。
  /// kind：success → code；error → errorCode；installResult → (id, code)。
  static ({String kind, int code, String? faceId}) parse(
      List<int> data, [IntEncoding enc = IntEncoding.varint]) {
    final r = ProtoReader(data);
    while (!r.isAtEnd) {
      final (field, wt) = r.readFieldHeader();
      switch ((field, wt)) {
        case (5, 0): // 成功：code
          return (kind: 'success', code: r.readVarint(), faceId: null);
        case (7, 2): // 安装结果 x8u：{id, code}
          final sub = ProtoReader(r.readBytes());
          String? id;
          var code = -1;
          while (!sub.isAtEnd) {
            final (f2, w2) = sub.readFieldHeader();
            switch ((f2, w2)) {
              case (1, 2):
                id = sub.readString();
              case (2, 0):
                code = sub.readVarint();
              default:
                sub.skipField(w2);
            }
          }
          return (kind: 'installResult', code: code, faceId: id);
        case (9, 2): // 错误 z8u：{id, code, canReplace}
          final sub = ProtoReader(r.readBytes());
          String? id;
          var code = -1;
          while (!sub.isAtEnd) {
            final (f2, w2) = sub.readFieldHeader();
            switch ((f2, w2)) {
              case (1, 2):
                id = sub.readString();
              case (2, 0):
                code = sub.readVarint();
              default:
                sub.skipField(w2);
            }
          }
          return (kind: 'error', code: code, faceId: id);
        default:
          r.skipField(wt);
      }
    }
    return (kind: 'unknown', code: -1, faceId: null);
  }
}

/// RPK 载荷 v8s（zau oneof field 22）。
abstract final class V8s {
  static (int, List<int>) prepareRequest({
    required String packageName,
    required int versionCode,
    required int packageSize,
    IntEncoding enc = IntEncoding.varint,
  }) {
    final w = ProtoWriter();
    w.writeString(1, packageName);
    w.writeIntEncoded(2, versionCode, enc);
    w.writeIntEncoded(3, packageSize, enc);
    return (22, w.bytes); // v8s oneof f2 = j8s
  }

  /// 解析预装响应 k8s：返回 (status, expectedSliceLength)。
  static ({int status, int expectedSliceLength}) parsePrepareResponse(
      List<int> data, [IntEncoding enc = IntEncoding.varint]) {
    final r = ProtoReader(data);
    var status = -1;
    var slice = 0;
    while (!r.isAtEnd) {
      final (field, wt) = r.readFieldHeader();
      switch ((field, wt)) {
        case (1, 0):
          status = r.readVarint();
        case (2, 0):
          slice = r.readVarint();
        default:
          r.skipField(wt);
      }
    }
    return (status: status, expectedSliceLength: slice);
  }
}

/// Mass 载荷 o1h（zau oneof field 24）。
abstract final class O1h {
  /// MassPrepare 请求：dataType、文件 MD5(16B)、文件总长。
  static (int, List<int>) prepareRequest({
    required int dataType,
    required List<int> fileMd5,
    required int fileLength,
    IntEncoding enc = IntEncoding.varint,
  }) {
    final w = ProtoWriter();
    w.writeIntEncoded(1, dataType, enc);
    w.writeBytes(2, fileMd5);
    w.writeIntEncoded(3, fileLength, enc);
    w.writeIntEncoded(4, 0, enc);
    return (24, w.bytes); // o1h oneof f1 = s1h
  }

  /// 解析 MassPrepare 响应 u1h：返回 (prepareStatus, remainLength, expectedSliceLength)。
  static ({int prepareStatus, int remainLength, int expectedSliceLength})
      parsePrepareResponse(List<int> data, [IntEncoding enc = IntEncoding.varint]) {
    final r = ProtoReader(data);
    var status = -1;
    var remain = 0;
    var slice = 0;
    while (!r.isAtEnd) {
      final (field, wt) = r.readFieldHeader();
      switch ((field, wt)) {
        case (2, 0):
          status = r.readVarint();
        case (4, 0):
          remain = r.readVarint();
        case (5, 0):
          slice = r.readVarint();
        default:
          r.skipField(wt);
      }
    }
    return (
      prepareStatus: status,
      remainLength: remain,
      expectedSliceLength: slice,
    );
  }

  /// 解析设备推送的取消命令 q1h：返回 code（3 = 取消）。
  static ({int code}) parseCancel(List<int> data) {
    final r = ProtoReader(data);
    var code = -1;
    while (!r.isAtEnd) {
      final (field, wt) = r.readFieldHeader();
      if (field == 1 && wt == 0) {
        code = r.readVarint();
      } else {
        r.skipField(wt);
      }
    }
    return (code: code);
  }
}
