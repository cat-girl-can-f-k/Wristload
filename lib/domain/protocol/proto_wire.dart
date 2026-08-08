/// 最小 protobuf wire 编码器（与小米运动健康 APK 使用的 protobuf nano 兼容）。
///
/// 本项目不引入第三方 protobuf 库，仅实现本协议用到的 wire 类型：
/// varint、length-delimited（bytes/string/message）、fixed32。
///
/// 依据：`项目目录/analysis/协议方法体级分析_小米运动健康_9.23.35.md`
/// 逆向自 zau 等消息的序列化代码（`CodedOutputByteBufferNano`）。
library;

import 'dart:convert';
import 'dart:typed_data';

/// ⚠️ 编码语义待真机验证：
/// APK 中 int 字段分两种写入方式 `W(...)` 与 `p0(...)`，混淆后无法静态区分
/// `p0` 是普通 varint 还是 zigzag（sint）。本实现默认按 varint，
/// 通过 [IntEncoding] 保留切换能力；在 HCI 抓包验证前不得用于真实发送。

/// int 字段的编码方式（默认 varint；zigzag 待真机验证后按设备固件切换）。
enum IntEncoding { varint, zigzag }

/// 序列化缓冲。小端写入，方法名与 protobuf wire 语义一致。
class ProtoWriter {
  ProtoWriter();

  final List<int> _bytes = <int>[];

  List<int> get bytes => _bytes;

  void _varint(int value) {
    var v = value;
    while ((v & ~0x7F) != 0) {
      _bytes.add((v & 0x7F) | 0x80);
      v = (v >>> 7) & 0xFFFFFFFF;
    }
    _bytes.add(v & 0x7F);
  }

  /// 写 tag = (field << 3) | wireType。
  void writeTag(int field, int wireType) => _varint((field << 3) | wireType);

  /// int32/int64（varint）。
  void writeInt(int field, int value) {
    writeTag(field, 0);
    _varint(value);
  }

  /// sint（zigzag）编码的 int。
  void writeSInt(int field, int value) {
    writeTag(field, 0);
    _varint((value << 1) ^ (value >> 31));
  }

  /// 按 [IntEncoding] 写入 int 字段。
  void writeIntEncoded(int field, int value, IntEncoding enc) {
    if (enc == IntEncoding.zigzag) {
      writeSInt(field, value);
    } else {
      writeInt(field, value);
    }
  }

  /// length-delimited（bytes / string / 嵌套 message）。
  void writeBytes(int field, List<int> data) {
    writeTag(field, 2);
    _varint(data.length);
    _bytes.addAll(data);
  }

  void writeString(int field, String value) =>
      writeBytes(field, utf8.encode(value));

  /// 写 bool 字段（varint 0/1）。
  void writeBool(int field, bool value) => writeInt(field, value ? 1 : 0);

  /// 写 fixed32 字段（wire type 5，小端）。
  void writeFixed32(int field, int value) {
    writeTag(field, 5);
    _bytes.add(value & 0xff);
    _bytes.add((value >> 8) & 0xff);
    _bytes.add((value >> 16) & 0xff);
    _bytes.add((value >> 24) & 0xff);
  }

  /// 写 float 字段（fixed32，IEEE-754 位模式，小端）。
  void writeFloat(int field, double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    writeFixed32(field, data.getUint32(0, Endian.little));
  }

  void writeMessage(int field, List<int> encoded) => writeBytes(field, encoded);
}

/// protobuf wire 解析器（用于设备推送的响应解析）。
class ProtoReader {
  ProtoReader(this._data) : _pos = 0;

  final List<int> _data;
  int _pos;

  bool get isAtEnd => _pos >= _data.length;

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _data[_pos++];
      result |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
      if (shift > 35) throw const FormatException('varint too long');
    }
    return result;
  }

  List<int> readBytes() {
    final len = readVarint();
    if (_pos + len > _data.length) {
      throw const FormatException('length-delimited overrun');
    }
    final out = _data.sublist(_pos, _pos + len);
    _pos += len;
    return out;
  }

  String readString() => String.fromCharCodes(readBytes());

  /// 读取下一个字段：返回 (fieldNumber, wireType)。
  /// 遇到无法消费的 wireType 时跳过字段。
  (int, int) readFieldHeader() {
    final tag = readVarint();
    return (tag >> 3, tag & 0x07);
  }

  void skipField(int wireType) {
    switch (wireType) {
      case 0:
        readVarint();
      case 1:
        _pos += 8;
      case 2:
        readBytes();
      case 5:
        _pos += 4;
      default:
        throw FormatException('unsupported wireType $wireType');
    }
  }
}
