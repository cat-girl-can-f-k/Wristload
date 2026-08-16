/// zau 命令消息及表盘 / RPK / Mass 载荷的构建与解析。
///
/// 与小米运动健康 APK 中 protobuf nano 消息一一对应（仅字段号与含义，
/// 全部独立实现，不复制任何 APK 代码）：
///
/// - `zau`   ：f1=命令号 e、f2=子命令 f、oneof 载荷（f6=a9u 表盘、f22=v8s RPK、f24=o1h Mass）
/// - `a9u`   ：表盘载荷。oneof：f2=faceId、f5=code、f6=y8u(预装)、f7=x8u(结果)、f9=z8u(错误)
/// - `y8u`   ：表盘文件信息。f1=faceId、f2=fileSize、f3=long、f4=int、f5=message
/// - `x8u`   ：表盘安装结果。id/code/canReplace（设备推送，解析用）
/// - `v8s`   ：RPK 载荷。oneof：f2=j8s(预装请求)、f3=k8s(预装响应)、f4=l8s(安装结果)
/// - `j8s`   ：RPK 预装请求。f1=packageName、f2=versionCode、f3=packageSize
/// - `k8s`   ：RPK 预装响应。f1=status、f2=expectedSliceLength
/// - `o1h`   ：Mass 载荷。oneof：f1=s1h(MassPrepare 请求)、f2=u1h(响应)、f3=q1h(取消)
/// - `s1h`   ：MassPrepare 请求。f1=dataType、f2=md5、f3=fileLength、f4=0
/// - `u1h`   ：MassPrepare 响应。f1=bytes、f2=prepareStatus、f3=…、f4=remainLength、f5=expectedSliceLength
/// - `q1h`   ：Mass 取消。f1=code、f2=…
///
/// int 编码按 [IntEncoding]（见 proto_wire.dart 顶部说明，待真机验证）。
library;

import 'dart:typed_data';

import '../watch_app.dart';
import 'proto_wire.dart';

/// 表盘 / RPK / Mass 命令号（zau.e）。
abstract final class ZauCommand {
  /// Debug transfer cleanup status query. The device returns status 1 while
  /// the previous transfer is still being disposed.
  static const int debugTransfer = 13;
  /// Factory/debug build-mode switch. The device restarts immediately after
  /// receiving this command, so the official client does not wait for a
  /// business response.
  static const int debugTransferBootModeSub = 0;
  /// FactoryTestFragment.dumpDeviceLog() is fire-and-forget.
  static const int debugTransferDeviceLogSub = 2;
  static const int debugTransferStatusSub = 6;
  static const int debugTransferControlSub = 7;
  static const int debugTransferSelfCheckResultSub = 8;

  static const int appList = 20;
  static const int appListSub = 0;
  static const int uninstallAppSub = 3;

  /// Device basic-status requests. Battery is sub-command 1 and storage is
  /// sub-command 62.
  static const int basicStatus = 2;
  static const int storageStatus = 62;

  /// Official Vela system-time sync request (TimeSyncer): command=2, sub=3.
  static const int setSystemTime = 2;

  /// Official device-log request and completion notification.
  static const int deviceLog = 2;
  static const int deviceLogStartSub = 80;
  static const int deviceLogResultSub = 81;

  static const int setFace = 4; // 表盘：预装(f=4) / setFace(f=1)
  static const int prepareInstallApp = 20; // RPK 预装
  static const int massTransfer = 22; // Mass 文件传输（MassPrepare/MassData 控制）
}

/// Boot modes accepted by the official Xiaomi Fitness factory-test page.
///
/// `FactoryTestFragment.doFactoryMode` sends command/sub `13/0` and assigns
/// the selected value through `r8a.field1`. The values intentionally have a
/// gap because they are device firmware enum values, not a sequential UI index.
enum DeviceBootMode {
  user(0, 'user'),
  userdebug(1, 'userdebug'),
  eng(2, 'eng'),
  medicalMeter(4, 'medical_meter');

  const DeviceBootMode(this.value, this.label);

  final int value;
  final String label;
}

abstract final class BootModePayload {
  /// Encodes `r8a.field1`, as used by the official factory-test command.
  static (int, List<int>) switchRequest(DeviceBootMode mode) {
    final debug = ProtoWriter()..writeInt(1, mode.value);
    return (15, debug.bytes);
  }
}

/// Device-log messages confirmed from the official Xiaomi Fitness debug APK.
///
/// The request is command/sub `2/80` with `zau.field4 -> ysr.field50 ->
/// tsr.field1 = 1`. The device later reports command/sub `2/81` through
/// `ysr.field51 -> tsr`, whose fields 1 and 2 identify the result kind and
/// status code. The actual log bytes arrive separately on the raw data path.
abstract final class DeviceLogPayload {
  /// Official FactoryTest dump request (`command=13`, `sub=2`) has no
  /// protobuf oneof payload. Returning null keeps field 0 out of the wire
  /// message; field numbers are one-based in protobuf.
  static (int, List<int>)? dumpRequest() => null;

  static (int, List<int>) startRequest() {
    final request = ProtoWriter()..writeInt(1, 1);
    final envelope = ProtoWriter()..writeMessage(50, request.bytes);
    return (4, envelope.bytes);
  }

  static DeviceLogControlResult? parseResult((int, List<int>)? payload) {
    if (payload == null || payload.$1 != 4) return null;
    try {
      final envelope = ProtoReader(payload.$2);
      while (!envelope.isAtEnd) {
        final (field, wire) = envelope.readFieldHeader();
        if (field != 51 || wire != 2) {
          envelope.skipField(wire);
          continue;
        }
        final result = ProtoReader(envelope.readBytes());
        int? type;
        int? code;
        while (!result.isAtEnd) {
          final (resultField, resultWire) = result.readFieldHeader();
          if (resultWire != 0) {
            result.skipField(resultWire);
          } else if (resultField == 1) {
            type = result.readVarint();
          } else if (resultField == 2) {
            code = result.readVarint();
          } else {
            result.skipField(resultWire);
          }
        }
        return code == null ? null : DeviceLogControlResult(type: type, code: code);
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}

class DeviceLogControlResult {
  const DeviceLogControlResult({required this.type, required this.code});

  final int? type;
  final int code;
}

/// Debug self-check messages confirmed from Xiaomi Fitness Debug.
///
/// The start request is command/sub `13/7` with `zau.field15` containing
/// `r8a.field7 -> z8a.field1 = 1`. The device later pushes command/sub
/// `13/8` with `r8a.field9 -> b9a` carrying the individual check results.
abstract final class SelfCheckPayload {
  static (int, List<int>) modeQueryRequest() => (15, const <int>[]);

  /// Switches the device from its normal mode into self-check mode. This is
  /// distinct from [startRequest], which starts the check after entry.
  static (int, List<int>) enterModeRequest() => modeChangeRequest(0);

  static (int, List<int>) modeChangeRequest(int mode) {
    if (mode < 0 || mode > 3) {
      throw ArgumentError.value(mode, 'mode', 'must be between 0 and 3');
    }
    final control = ProtoWriter()..writeInt(1, mode);
    final debug = ProtoWriter()..writeMessage(7, control.bytes);
    return (15, debug.bytes);
  }

  static (int, List<int>) startRequest() {
    final control = ProtoWriter()..writeInt(1, 1);
    final debug = ProtoWriter()..writeMessage(7, control.bytes);
    return (15, debug.bytes);
  }

  /// Parses `r8a.field8 -> a9a.field2`, the official control result code.
  static int? parseControlResult((int, List<int>)? payload) {
    if (payload == null || payload.$1 != 15) return null;
    try {
      final debug = ProtoReader(payload.$2);
      while (!debug.isAtEnd) {
        final (field, wire) = debug.readFieldHeader();
        if (field != 8 || wire != 2) {
          debug.skipField(wire);
          continue;
        }
        final result = ProtoReader(debug.readBytes());
        while (!result.isAtEnd) {
          final (resultField, resultWire) = result.readFieldHeader();
          if (resultField == 2 && resultWire == 0) {
            return result.readVarint();
          }
          result.skipField(resultWire);
        }
        return null;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// Parses the mode returned by the official 13/6 request. The obfuscated
  /// protobuf wrapper has changed nesting across firmware revisions, so walk
  /// only embedded protobuf messages and accept the first mode value 0..3.
  static int? parseMode((int, List<int>)? payload) {
    if (payload == null || payload.$1 != 15) return null;
    return _findMode(payload.$2, 0);
  }

  static int? _findMode(List<int> bytes, int depth) {
    if (depth > 5) return null;
    try {
      final reader = ProtoReader(bytes);
      while (!reader.isAtEnd) {
        final (field, wire) = reader.readFieldHeader();
        if (wire == 0) {
          final value = reader.readVarint();
          if (value >= 0 && value <= 3) return value;
        } else if (wire == 2) {
          final nested = _findMode(reader.readBytes(), depth + 1);
          if (nested != null) return nested;
        } else {
          reader.skipField(wire);
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  static ({List<SelfCheckDeviceItem> items, bool completed})? parseReport(
    (int, List<int>)? payload,
  ) {
    if (payload == null || payload.$1 != 15) return null;
    try {
      final debug = ProtoReader(payload.$2);
      while (!debug.isAtEnd) {
        final (field, wire) = debug.readFieldHeader();
        if (field != 9 || wire != 2) {
          debug.skipField(wire);
          continue;
        }
        final report = ProtoReader(debug.readBytes());
        final items = <SelfCheckDeviceItem>[];
        var completed = false;
        while (!report.isAtEnd) {
          final (reportField, reportWire) = report.readFieldHeader();
          if (reportField == 1 && reportWire == 2) {
            final item = _parseItem(report.readBytes());
            if (item != null) items.add(item);
          } else if (reportField == 2 && reportWire == 0) {
            completed = report.readVarint() != 0;
          } else {
            report.skipField(reportWire);
          }
        }
        return (items: items, completed: completed);
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  static SelfCheckDeviceItem? _parseItem(List<int> bytes) {
    final reader = ProtoReader(bytes);
    int? id;
    var passed = false;
    while (!reader.isAtEnd) {
      final (field, wire) = reader.readFieldHeader();
      if (field == 1 && wire == 0) {
        id = reader.readVarint();
      } else if (field == 2 && wire == 0) {
        passed = reader.readVarint() != 0;
      } else {
        reader.skipField(wire);
      }
    }
    return id == null ? null : SelfCheckDeviceItem(id: id, passed: passed);
  }
}

class SelfCheckDeviceItem {
  const SelfCheckDeviceItem({required this.id, required this.passed});

  final int id;
  final bool passed;
}

/// Parses the status response used by the debug transfer-cleanup probe.
///
/// Firmware revisions wrap this value in different protobuf messages, so the
/// parser accepts a direct varint or a bounded chain of embedded messages and
/// returns the first status-like integer. Missing/invalid responses stay null.
abstract final class DebugCleanupStatusPayload {
  static int? parse((int, List<int>)? payload) {
    if (payload == null) return null;
    return _firstVarint(payload.$2, 0);
  }

  static int? _firstVarint(List<int> bytes, int depth) {
    if (depth > 4) return null;
    try {
      final reader = ProtoReader(bytes);
      while (!reader.isAtEnd) {
        final (field, wire) = reader.readFieldHeader();
        if (wire == 0) return reader.readVarint();
        if (wire == 2) {
          final nested = _firstVarint(reader.readBytes(), depth + 1);
          if (nested != null) return nested;
        } else {
          reader.skipField(wire);
        }
      }
    } on FormatException {
      return null;
    }
    return null;
  }
}

/// Parses the battery percentage returned by the official V2 basic-status
/// request (`command=2`, `sub=1`).
///
/// Response layout: `zau.field4=ysr`, `ysr.field2=asr`,
/// `asr.field1=status`, `status.field1=batteryPercent`. Missing, malformed, or
/// out-of-range values remain unknown instead of being presented as 0%.
abstract final class BatteryStatusPayload {
  static int? parse((int, List<int>)? payload) {
    if (payload == null || payload.$1 != 4) return null;
    try {
      final asrBytes = _messageField(payload.$2, 2);
      if (asrBytes == null) return null;
      final statusBytes = _messageField(asrBytes, 1);
      if (statusBytes == null) return null;
      final battery = _intField(statusBytes, 1);
      if (battery == null || battery < 0 || battery > 100) return null;
      return battery;
    } on FormatException {
      return null;
    }
  }

  static List<int>? _messageField(List<int> bytes, int expectedField) {
    final reader = ProtoReader(bytes);
    while (!reader.isAtEnd) {
      final (field, wire) = reader.readFieldHeader();
      if (field == expectedField && wire == 2) return reader.readBytes();
      reader.skipField(wire);
    }
    return null;
  }

  static int? _intField(List<int> bytes, int expectedField) {
    final reader = ProtoReader(bytes);
    while (!reader.isAtEnd) {
      final (field, wire) = reader.readFieldHeader();
      if (field == expectedField && wire == 0) return reader.readVarint();
      reader.skipField(wire);
    }
    return null;
  }
}

/// Parses the storage usage returned by the official music-page query
/// (`command=2`, `sub=62`).
///
/// The complete log from Xiaomi Fitness 9.23.35 confirms this wire layout:
/// `zau.field4=ysr`, `ysr.field44=xsr`, where `xsr.field1` is used bytes and
/// `xsr.field2` is total bytes. The response is still an outer `2/62` ZAU
/// message; field 4 selects the payload and is not a response command.
abstract final class StorageStatusPayload {
  static ({int usedBytes, int totalBytes})? parse((int, List<int>)? payload) {
    if (payload == null || payload.$1 != 4) return null;
    try {
      final ysr = ProtoReader(payload.$2);
      List<int>? storageBytes;
      while (!ysr.isAtEnd) {
        final (field, wire) = ysr.readFieldHeader();
        if (field == 44 && wire == 2) {
          storageBytes = ysr.readBytes();
        } else {
          ysr.skipField(wire);
        }
      }
      if (storageBytes == null) return null;

      final storage = ProtoReader(storageBytes);
      int? usedBytes;
      int? totalBytes;
      while (!storage.isAtEnd) {
        final (field, wire) = storage.readFieldHeader();
        if (field == 1 && wire == 0) {
          usedBytes = storage.readVarint();
        } else if (field == 2 && wire == 0) {
          totalBytes = storage.readVarint();
        } else {
          storage.skipField(wire);
        }
      }
      if (usedBytes == null ||
          totalBytes == null ||
          totalBytes <= 0 ||
          usedBytes > totalBytes) {
        return null;
      }
      return (usedBytes: usedBytes, totalBytes: totalBytes);
    } on FormatException {
      return null;
    }
  }
}

/// Payload used by the official V2/Vela TimeSyncer.
///
/// Wire layout (from the APK nano messages): zau.field4=ysr,
/// ysr.field4=btr, btr={date:ht4,time:nt4,timezone:pt4,is12Hour}.
abstract final class TimeSyncPayload {
  static (int, List<int>) encode({
    required DateTime localTime,
    required int standardOffsetMinutes,
    required int daylightOffsetMinutes,
    required String timezoneId,
    required bool use24Hour,
  }) {
    if (localTime.isUtc) {
      throw ArgumentError.value(localTime, 'localTime', 'must be local time');
    }
    if (standardOffsetMinutes % 15 != 0 || daylightOffsetMinutes % 15 != 0) {
      throw ArgumentError('timezone offsets must be multiples of 15 minutes');
    }
    if (timezoneId.isEmpty) {
      throw ArgumentError.value(timezoneId, 'timezoneId', 'must not be empty');
    }
    final date = ProtoWriter()
      ..writeInt(1, localTime.year)
      ..writeInt(2, localTime.month)
      ..writeInt(3, localTime.day);
    final time = ProtoWriter()
      ..writeInt(1, localTime.hour)
      ..writeInt(2, localTime.minute);
    if (localTime.second != 0) {
      time.writeInt(3, localTime.second);
    }
    if (localTime.millisecond != 0) {
      time.writeInt(4, localTime.millisecond);
    }
    final timezone = ProtoWriter()
      // pt4 uses nano i0(), which is sint32/zigzag, for both offsets.
      ..writeSInt(1, standardOffsetMinutes ~/ 15);
    if (daylightOffsetMinutes != 0) {
      timezone.writeSInt(2, daylightOffsetMinutes ~/ 15);
    }
    timezone.writeString(3, timezoneId);
    final btr = ProtoWriter()
      ..writeMessage(1, date.bytes)
      ..writeMessage(2, time.bytes)
      ..writeMessage(3, timezone.bytes);
    if (!use24Hour) {
      // The APK stores `!DateFormat.is24HourFormat(...)` in btr.field4.
      btr.writeBool(4, true);
    }
    final ysr = ProtoWriter()..writeMessage(4, btr.bytes);
    return (4, ysr.bytes);
  }
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

  /// 设备可能在重启或非本协议服务时返回无关数据；调用方用此方法避免把
  /// 解析异常误判为设备的安装失败。
  static Zau? tryParse(List<int> data, [IntEncoding enc = IntEncoding.varint]) {
    try {
      return parse(data, enc);
    } on Object {
      return null;
    }
  }
}

/// 表盘载荷 a9u（zau oneof field 6）。
abstract final class A9u {
  static (int, List<int>) withFileInfo({
    required String faceId,
    required int fileSize,
    IntEncoding enc = IntEncoding.varint,
  }) {
    // zau.field6 = a9u, a9u.field6 = y8u. Skipping the a9u oneof wrapper
    // makes the device reject the control frame and close RFCOMM.
    final y8u = ProtoWriter()
      ..writeString(1, faceId)
      ..writeIntEncoded(2, fileSize, enc);
    final a9u = ProtoWriter()..writeMessage(6, y8u.bytes);
    return (6, a9u.bytes);
  }

  static (int, List<int>) withFaceId(String faceId) {
    final w = ProtoWriter();
    w.writeString(2, faceId);
    return (6, w.bytes);
  }

  /// 解析表盘预装响应/结果。返回 (kind, code/id…)。
  /// kind：success → code；error → errorCode；installResult → (id, code)。
  static ({String kind, int code, String? faceId}) parse(
    List<int> data, [
    IntEncoding enc = IntEncoding.varint,
  ]) {
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
  /// command=20/sub=3 carries v8s.field5=o8s.
  static (int, List<int>) uninstallRequest({
    required String packageName,
    required List<int> fingerprint,
  }) {
    if (packageName.trim().isEmpty) {
      throw ArgumentError.value(
        packageName,
        'packageName',
        'must not be empty',
      );
    }
    final app = ProtoWriter()
      ..writeString(1, packageName)
      ..writeBytes(2, fingerprint);
    final v8s = ProtoWriter()..writeMessage(5, app.bytes);
    return (22, v8s.bytes);
  }

  /// Parses command=20/sub=0 response data.
  ///
  /// The RPK oneof uses `v8s.field1` as a list wrapper. Each installed app is
  /// then carried by a repeated `field1` inside that wrapper. Keeping the two
  /// levels explicit prevents the wrapper bytes from being decoded as an app
  /// package name.
  static List<WatchAppItem> parseInstalledApps(List<int> data) {
    final apps = <WatchAppItem>[];
    final v8s = ProtoReader(data);
    var foundListWrapper = false;
    while (!v8s.isAtEnd) {
      final (field, wire) = v8s.readFieldHeader();
      if (field == 1 && wire == 2) {
        foundListWrapper = true;
        final wrapper = ProtoReader(v8s.readBytes());
        while (!wrapper.isAtEnd) {
          final (entryField, entryWire) = wrapper.readFieldHeader();
          if (entryField == 1 && entryWire == 2) {
            apps.add(_parseInstalledApp(wrapper.readBytes()));
          } else {
            wrapper.skipField(entryWire);
          }
        }
      } else {
        v8s.skipField(wire);
      }
    }
    if (!foundListWrapper) {
      throw const FormatException('设备快应用列表缺少列表容器');
    }
    return apps;
  }

  static WatchAppItem _parseInstalledApp(List<int> data) {
    final reader = ProtoReader(data);
    var packageName = '';
    var fingerprint = Uint8List(0);
    var versionCode = 0;
    var canRemove = false;
    var appName = '';
    while (!reader.isAtEnd) {
      final (field, wire) = reader.readFieldHeader();
      switch ((field, wire)) {
        case (1, 2):
          packageName = reader.readString();
        case (2, 2):
          fingerprint = Uint8List.fromList(reader.readBytes());
        case (3, 0):
          versionCode = reader.readVarint();
        case (4, 0):
          canRemove = reader.readVarint() != 0;
        case (5, 2):
          appName = reader.readString();
        default:
          reader.skipField(wire);
      }
    }
    if (packageName.isEmpty) {
      throw const FormatException('设备快应用列表缺少包名');
    }
    return WatchAppItem(
      packageName: packageName,
      fingerprint: fingerprint,
      versionCode: versionCode,
      canRemove: canRemove,
      appName: appName,
    );
  }

  static (int, List<int>) prepareRequest({
    required String packageName,
    required int versionCode,
    required int packageSize,
    IntEncoding enc = IntEncoding.varint,
  }) {
    final j8s = ProtoWriter()
      ..writeString(1, packageName)
      ..writeIntEncoded(2, versionCode, enc)
      ..writeIntEncoded(3, packageSize, enc);
    final v8s = ProtoWriter()..writeMessage(2, j8s.bytes);
    return (22, v8s.bytes); // zau.field22=v8s, v8s.field2=j8s
  }

  /// 解析预装响应 k8s：返回 (status, expectedSliceLength)。
  static ({int status, int expectedSliceLength}) parsePrepareResponse(
    List<int> data, [
    IntEncoding enc = IntEncoding.varint,
  ]) {
    // v8s response is normally carried as v8s.field3 = k8s.
    final outer = ProtoReader(data);
    while (!outer.isAtEnd) {
      final (field, wire) = outer.readFieldHeader();
      if (field == 3 && wire == 2) {
        return parsePrepareResponse(outer.readBytes(), enc);
      }
      outer.skipField(wire);
    }
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

  /// 解析设备主动推送的 RPK 安装结果 `20/2`。
  ///
  /// v8s.field4=l8s；l8s.field1 是结果码，oneof field2 是失败时包名，
  /// field3=m8s 是成功时应用信息（m8s.field1 同样是包名）。
  static ({int code, String packageName}) parseInstallResult(List<int> data) {
    final outer = ProtoReader(data);
    List<int>? resultBytes;
    while (!outer.isAtEnd) {
      final (field, wire) = outer.readFieldHeader();
      if (field == 4 && wire == 2) {
        resultBytes = outer.readBytes();
      } else {
        outer.skipField(wire);
      }
    }
    if (resultBytes == null) {
      throw const FormatException('RPK 安装结果缺少 v8s.field4');
    }

    final result = ProtoReader(resultBytes);
    var code = -1;
    var packageName = '';
    while (!result.isAtEnd) {
      final (field, wire) = result.readFieldHeader();
      switch ((field, wire)) {
        case (1, 0):
          code = result.readVarint();
        case (2, 2):
          packageName = result.readString();
        case (3, 2):
          final appItem = ProtoReader(result.readBytes());
          while (!appItem.isAtEnd) {
            final (appField, appWire) = appItem.readFieldHeader();
            if (appField == 1 && appWire == 2) {
              packageName = appItem.readString();
            } else {
              appItem.skipField(appWire);
            }
          }
        default:
          result.skipField(wire);
      }
    }
    if (code < 0) {
      throw const FormatException('RPK 安装结果缺少状态码');
    }
    if (packageName.isEmpty) {
      throw const FormatException('RPK 安装结果缺少包名');
    }
    return (code: code, packageName: packageName);
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
    final s1h = ProtoWriter()
      ..writeIntEncoded(1, dataType, enc)
      ..writeBytes(2, fileMd5)
      ..writeIntEncoded(3, fileLength, enc)
      ..writeIntEncoded(4, 0, enc);
    final o1h = ProtoWriter()..writeMessage(1, s1h.bytes);
    return (24, o1h.bytes); // zau.field24=o1h, o1h.field1=s1h
  }

  /// 解析 MassPrepare 响应 u1h：返回 (prepareStatus, remainLength, expectedSliceLength)。
  static ({int prepareStatus, int remainLength, int expectedSliceLength})
  parsePrepareResponse(List<int> data, [IntEncoding enc = IntEncoding.varint]) {
    // o1h response is normally carried as o1h.field2 = u1h.
    final outer = ProtoReader(data);
    while (!outer.isAtEnd) {
      final (field, wire) = outer.readFieldHeader();
      if (field == 2 && wire == 2) {
        return parsePrepareResponse(outer.readBytes(), enc);
      }
      outer.skipField(wire);
    }
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
