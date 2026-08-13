import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:wristload/domain/protocol/auth_handshake.dart';
import 'package:wristload/domain/protocol/hci_decoder.dart';
import 'package:wristload/domain/protocol/mass_transfer.dart';
import 'package:wristload/domain/protocol/session_cipher.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/ccm.dart';
import 'package:wristload/domain/protocol/proto_wire.dart';
import 'package:wristload/domain/protocol/spp_protocol.dart';
import 'package:wristload/domain/protocol/transport_constants.dart';
import 'package:wristload/domain/protocol/zau.dart';
import 'package:wristload/domain/verification_gate.dart';
import 'package:wristload/domain/device_profile.dart';
import 'package:wristload/domain/install_metadata_reader.dart';
import 'package:wristload/domain/install_models.dart';
import 'package:wristload/domain/install_task.dart';
import 'package:wristload/domain/mass_ack_idle_timeout.dart';

void main() {
  setUp(() {
    // Metadata parsing is platform-independent. Use a non-sandboxed target so
    // these parser fixtures do not bypass or mock macOS security bookmarks.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('OTA channel is reserved separately from Mass transfers', () {
    expect(SppProtocol.channelOta, 6);
    expect(SppProtocol.channelOta, isNot(SppProtocol.channelMass));
  });

  group('Mass ACK 空闲超时', () {
    test('每次确认进度都会续期，而不是限制整个窗口总时长', () async {
      final first = Completer<void>();
      final second = Completer<void>();
      final third = Completer<void>();
      final waiting = waitForMassAcknowledgements(
        [first.future, second.future, third.future],
        idleTimeout: const Duration(milliseconds: 500),
        timeoutMessage: (acknowledged, total) => '$acknowledged/$total',
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));
      first.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      second.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      third.complete();

      await expectLater(waiting, completes);
    });

    test('连续无进度才超时，并报告确认数量', () async {
      final first = Completer<void>()..complete();
      final pending = Completer<void>();
      final waiting = waitForMassAcknowledgements(
        [first.future, pending.future],
        idleTimeout: const Duration(milliseconds: 50),
        timeoutMessage: (acknowledged, total) => '已确认 $acknowledged/$total',
      );

      await expectLater(
        waiting,
        throwsA(isA<TimeoutException>().having(
          (error) => error.message,
          'message',
          '已确认 1/2',
        )),
      );
    });
  });

  test('表盘元数据识别 Lua 与二进制分辨率', () async {
    final bytes = Uint8List(128);
    bytes[0] = 0x5a;
    bytes[1] = 0xa5;
    bytes.setRange(40, 49, ascii.encode('367310001'));
    bytes.setRange(64, 68, [0x50, 0x01, 0xe0, 0x01]); // 336×480 U16LE
    bytes.setRange(80, 92, ascii.encode('main.Lua.bin'));
    final directory = await Directory.systemTemp.createTemp('miwear-test-');
    final file = File('${directory.path}${Platform.pathSeparator}face.bin');
    try {
      await file.writeAsBytes(bytes);
      final metadata =
          await InstallMetadataReader().read(InstallKind.watchface, file.path);
      expect(metadata.faceId, '367310001');
      expect(metadata.containsLua, isTrue);
      expect(metadata.watchfaceResolutions,
          contains(const WatchfaceResolution(336, 480)));
      expect(metadata.md5Hex, hasLength(32));
      expect(metadata.sha256Hex, hasLength(64));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('表盘缺失 faceId 时保留元数据并交由安装前确认补充', () async {
    final bytes = Uint8List(128);
    bytes[0] = 0x5a;
    bytes[1] = 0xa5;
    bytes.setRange(64, 68, [0xb0, 0x01, 0x02, 0x02]); // 432×514 U16LE
    final directory = await Directory.systemTemp.createTemp('miwear-face-');
    final file = File('${directory.path}${Platform.pathSeparator}missing.face');
    try {
      await file.writeAsBytes(bytes);
      final metadata =
          await InstallMetadataReader().read(InstallKind.watchface, file.path);
      expect(metadata.faceId, isNull);
      expect(
        metadata.watchfaceResolutions,
        contains(const WatchfaceResolution(432, 514)),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('RPK 拒绝超过安全上限的清单条目', () async {
    final manifest =
        List<int>.filled(InstallMetadataReader.maxManifestBytes + 1, 0x20);
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', manifest.length, manifest));
    final encoded = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final directory = await Directory.systemTemp.createTemp('miwear-rpk-');
    final file = File('${directory.path}${Platform.pathSeparator}large.rpk');
    try {
      await file.writeAsBytes(encoded);
      await expectLater(
        InstallMetadataReader().read(InstallKind.quickApp, file.path),
        throwsA(isA<FormatException>()),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('RPK 跳过无包名清单并读取唯一有效包名', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('manifest.json', '{"name":"demo"}'))
      ..addFile(ArchiveFile.string('src/manifest.json',
          '{"package":"com.example.valid","versionCode":7}'));
    final encoded = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final directory = await Directory.systemTemp.createTemp('miwear-rpk-');
    final file = File('${directory.path}${Platform.pathSeparator}valid.rpk');
    try {
      await file.writeAsBytes(encoded);
      final metadata =
          await InstallMetadataReader().read(InstallKind.quickApp, file.path);
      expect(metadata.packageName, 'com.example.valid');
      expect(metadata.versionCode, 7);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('RPK 拒绝多个互相冲突的有效包名', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string(
          'manifest.json', '{"package":"com.example.first","versionCode":1}'))
      ..addFile(ArchiveFile.string('src/manifest.json',
          '{"package":"com.example.second","versionCode":1}'));
    final encoded = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final directory = await Directory.systemTemp.createTemp('miwear-rpk-');
    final file = File('${directory.path}${Platform.pathSeparator}conflict.rpk');
    try {
      await file.writeAsBytes(encoded);
      await expectLater(
        InstallMetadataReader().read(InstallKind.quickApp, file.path),
        throwsA(isA<FormatException>()),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('private protocol is enabled after frame-level verification', () {
    expect(kProtocolVerified, isTrue);
    expect(() => const VerificationGate().ensureCanSend(), returnsNormally);
  });

  test('安装检查点拒绝缺失 SHA-256 或越界字段', () {
    final valid = <String, Object?>{
      'kind': 'quickApp',
      'path': r'D:\demo.rpk',
      'fileSize': 1024,
      'md5Hex': List.filled(32, '0').join(),
      'sha256Hex': List.filled(64, '1').join(),
      'dataType': 0x40,
      'lastAcknowledgedSegment': 3,
      'phase': 'transferring',
    };
    expect(InstallCheckpoint.fromJson(valid), isNotNull);
    expect(InstallCheckpoint.fromJson({...valid}..remove('sha256Hex')), isNull);
    expect(InstallCheckpoint.fromJson({...valid}..remove('kind')), isNull);
    expect(InstallCheckpoint.fromJson({...valid}..remove('path')), isNull);
    expect(InstallCheckpoint.fromJson({...valid, 'kind': 'other'}), isNull);
    expect(InstallCheckpoint.fromJson({...valid, 'phase': 'done'}), isNull);
    expect(
      InstallCheckpoint.fromJson({...valid, 'dataType': 0x10}),
      isNull,
    );
    expect(
      InstallCheckpoint.fromJson({...valid, 'md5Hex': 'not-a-digest'}),
      isNull,
    );
    expect(InstallCheckpoint.fromJson({...valid, 'dataType': 0x7f}), isNull);
    expect(InstallCheckpoint.fromJson({...valid, 'fileSize': -1}), isNull);
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

    test('malformed payloads fail with FormatException instead of RangeError',
        () {
      expect(() => ProtoReader([0x80]).readVarint(),
          throwsA(isA<FormatException>()));
      expect(() => ProtoReader([0x0a, 0x04, 0x01]).readFieldHeader(),
          returnsNormally);
      final truncated = ProtoReader([0x0a, 0x04, 0x01]);
      truncated.readFieldHeader();
      expect(() => truncated.readBytes(), throwsA(isA<FormatException>()));
      expect(() => ProtoReader([0x00]).readFieldHeader(),
          throwsA(isA<FormatException>()));
      final fixed32 = ProtoReader([0x0d, 0x01]);
      final header = fixed32.readFieldHeader();
      expect(header, (1, 5));
      expect(
          () => fixed32.skipField(header.$2), throwsA(isA<FormatException>()));
    });
  });

  group('zau', () {
    test('官方 V2 电量查询请求与 protobuf 字节向量一致', () {
      expect(
        Zau(command: ZauCommand.basicStatus, sub: 1).encode(),
        [0x08, 0x02, 0x10, 0x01],
      );
    });

    test('V2 电量响应按官方嵌套字段解析 0、37、100', () {
      (int, List<int>) payloadFor(int battery) {
        final status = ProtoWriter()..writeInt(1, battery);
        final asr = ProtoWriter()..writeMessage(1, status.bytes);
        final ysr = ProtoWriter()..writeMessage(2, asr.bytes);
        return (4, ysr.bytes);
      }

      expect(BatteryStatusPayload.parse(payloadFor(0)), 0);
      expect(BatteryStatusPayload.parse(payloadFor(37)), 37);
      expect(BatteryStatusPayload.parse(payloadFor(100)), 100);
    });

    test('V2 电量响应缺字段、字段错误、畸形或越界时保持未知', () {
      (int, List<int>) payloadFor(int battery) {
        final status = ProtoWriter()..writeInt(1, battery);
        final asr = ProtoWriter()..writeMessage(1, status.bytes);
        final ysr = ProtoWriter()..writeMessage(2, asr.bytes);
        return (4, ysr.bytes);
      }

      expect(BatteryStatusPayload.parse(null), isNull);
      expect(BatteryStatusPayload.parse((3, const [])), isNull);
      expect(BatteryStatusPayload.parse((4, const [])), isNull);
      expect(BatteryStatusPayload.parse((4, const [0x12, 0x04, 0x0a])), isNull);
      expect(BatteryStatusPayload.parse(payloadFor(101)), isNull);
    });

    test('官方音乐页存储查询是无载荷 ZAU 2/62', () {
      final encoded = Zau(
        command: ZauCommand.basicStatus,
        sub: ZauCommand.storageStatus,
      ).encode();

      expect(encoded, [0x08, 0x02, 0x10, 0x3e]);
      final parsed = Zau.parse(encoded);
      expect(parsed.command, 2);
      expect(parsed.sub, 62);
      expect(parsed.payload, isNull);
    });

    test('存储响应按 field4/field44 解析日志中的真实容量', () {
      (int, List<int>) payloadFor(int usedBytes, int totalBytes) {
        final storage = ProtoWriter()
          ..writeInt(1, usedBytes)
          ..writeInt(2, totalBytes);
        final ysr = ProtoWriter()..writeMessage(44, storage.bytes);
        return (4, ysr.bytes);
      }

      expect(
        StorageStatusPayload.parse(payloadFor(489160704, 2181824512)),
        (usedBytes: 489160704, totalBytes: 2181824512),
      );
      expect(
        StorageStatusPayload.parse(payloadFor(500695040, 2181824512)),
        (usedBytes: 500695040, totalBytes: 2181824512),
      );
    });

    test('存储响应不能把 zau.field4 误判为 command=4', () {
      final storage = ProtoWriter()
        ..writeInt(1, 489160704)
        ..writeInt(2, 2181824512);
      final ysr = ProtoWriter()..writeMessage(44, storage.bytes);
      final response = Zau(
        command: ZauCommand.basicStatus,
        sub: ZauCommand.storageStatus,
        payload: (4, ysr.bytes),
      );
      final parsed = Zau.parse(response.encode());

      expect(parsed.command, 2);
      expect(parsed.sub, 62);
      expect(parsed.payload!.$1, 4);
      expect(
        StorageStatusPayload.parse(parsed.payload),
        (usedBytes: 489160704, totalBytes: 2181824512),
      );
    });

    test('存储响应缺字段、畸形或容量关系无效时保持未知', () {
      (int, List<int>) payloadFor(int usedBytes, int totalBytes) {
        final storage = ProtoWriter()
          ..writeInt(1, usedBytes)
          ..writeInt(2, totalBytes);
        final ysr = ProtoWriter()..writeMessage(44, storage.bytes);
        return (4, ysr.bytes);
      }

      expect(StorageStatusPayload.parse(null), isNull);
      expect(StorageStatusPayload.parse((3, const [])), isNull);
      expect(StorageStatusPayload.parse((4, const [])), isNull);
      expect(StorageStatusPayload.parse((4, const [0xe2, 0x02, 0x04, 0x08])),
          isNull);
      expect(StorageStatusPayload.parse(payloadFor(1, 0)), isNull);
      expect(StorageStatusPayload.parse(payloadFor(101, 100)), isNull);
    });

    test('官方 V2 时间同步命令与 protobuf 字节向量一致', () {
      final payload = TimeSyncPayload.encode(
        localTime: DateTime(2026, 8, 11, 18, 30, 45, 123),
        standardOffsetMinutes: 480,
        daylightOffsetMinutes: 0,
        timezoneId: 'Asia/Shanghai',
        use24Hour: true,
      );
      final encoded = Zau(
        command: ZauCommand.setSystemTime,
        sub: 3,
        payload: payload,
      ).encode();

      expect(encoded, [
        0x08, 0x02, 0x10, 0x03, // zau command=2/sub=3
        0x22, 0x28, // zau.field4 = ysr
        0x22, 0x26, // ysr.field4 = btr
        0x0a, 0x07, 0x08, 0xea, 0x0f, 0x10, 0x08, 0x18, 0x0b,
        0x12, 0x08, 0x08, 0x12, 0x10, 0x1e, 0x18, 0x2d, 0x20, 0x7b,
        0x1a, 0x11, 0x08, 0x40, 0x1a, 0x0d,
        ...'Asia/Shanghai'.codeUnits,
      ]);
      final parsed = Zau.parse(encoded);
      expect(parsed.command, 2);
      expect(parsed.sub, 3);
      expect(parsed.payload!.$1, 4);
    });

    test('时间同步使用 zigzag 编码负 UTC 偏移并携带夏令时与 12 小时制', () {
      final payload = TimeSyncPayload.encode(
        localTime: DateTime(2026, 1, 2, 3, 4),
        standardOffsetMinutes: -480,
        daylightOffsetMinutes: 60,
        timezoneId: 'America/Los_Angeles',
        use24Hour: false,
      );
      final ysr = ProtoReader(payload.$2);
      expect(ysr.readFieldHeader(), (4, 2));
      final btr = ProtoReader(ysr.readBytes());
      expect(btr.readFieldHeader(), (1, 2));
      btr.readBytes();
      expect(btr.readFieldHeader(), (2, 2));
      final time = ProtoReader(btr.readBytes());
      expect(time.readFieldHeader(), (1, 0));
      expect(time.readVarint(), 3);
      expect(time.readFieldHeader(), (2, 0));
      expect(time.readVarint(), 4);
      expect(time.isAtEnd, isTrue); // 官方 nano 编码会省略为 0 的秒和毫秒
      expect(btr.readFieldHeader(), (3, 2));
      final timezone = ProtoReader(btr.readBytes());
      expect(timezone.readFieldHeader(), (1, 0));
      expect(timezone.readVarint(), 63); // zigzag(-32)
      expect(timezone.readFieldHeader(), (2, 0));
      expect(timezone.readVarint(), 8); // zigzag(+4)
      expect(timezone.readFieldHeader(), (3, 2));
      expect(timezone.readString(), 'America/Los_Angeles');
      expect(btr.readFieldHeader(), (4, 0));
      expect(btr.readVarint(), 1);
      expect(btr.isAtEnd, isTrue);
    });

    test('时间同步拒绝协议无法表示的非 15 分钟时区偏移', () {
      expect(
        () => TimeSyncPayload.encode(
          localTime: DateTime(2026, 8, 11),
          standardOffsetMinutes: 17,
          daylightOffsetMinutes: 0,
          timezoneId: 'Invalid/Offset',
          use24Hour: true,
        ),
        throwsArgumentError,
      );
    });

    test('表盘预装请求字段', () {
      final payload = A9u.withFileInfo(faceId: '120917350569', fileSize: 4096);
      expect(payload.$1, 6); // a9u 是 zau 的 oneof field 6
      final zau = Zau(command: 4, sub: 4, payload: payload).encode();
      final parsed = Zau.parse(zau);
      expect(parsed.command, 4);
      expect(parsed.sub, 4);
      expect(parsed.payload!.$1, 6);
      final a9u = ProtoReader(parsed.payload!.$2);
      expect(a9u.readFieldHeader(), (6, 2));
      final y8u = ProtoReader(a9u.readBytes());
      expect(y8u.readFieldHeader(), (1, 2));
      expect(y8u.readString(), '120917350569');
      expect(y8u.readFieldHeader(), (2, 0));
      expect(y8u.readVarint(), 4096);
      expect(y8u.isAtEnd, isTrue);
      expect(
        zau,
        [
          0x08,
          0x04,
          0x10,
          0x04,
          0x32,
          0x13,
          0x32,
          0x11,
          0x0a,
          0x0c,
          ...'120917350569'.codeUnits,
          0x10,
          0x80,
          0x20,
        ],
      );
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
      final v8s = ProtoReader(parsed.payload!.$2);
      expect(v8s.readFieldHeader(), (2, 2));
      final j8s = ProtoReader(v8s.readBytes());
      expect(j8s.readFieldHeader(), (1, 2));
      expect(j8s.readString(), 'com.example.app');
    });

    test('RPK 安装成功结果从应用信息读取包名', () {
      final appItem = ProtoWriter()
        ..writeString(1, 'com.example.app')
        ..writeInt(3, 7);
      final result = ProtoWriter()
        ..writeInt(1, 0)
        ..writeMessage(3, appItem.bytes);
      final v8s = ProtoWriter()..writeMessage(4, result.bytes);

      final parsed = V8s.parseInstallResult(v8s.bytes);
      expect(parsed.code, 0);
      expect(parsed.packageName, 'com.example.app');
    });

    test('RPK 安装失败结果直接读取包名和状态', () {
      final result = ProtoWriter()
        ..writeInt(1, 2)
        ..writeString(2, 'com.example.failed');
      final v8s = ProtoWriter()..writeMessage(4, result.bytes);

      final parsed = V8s.parseInstallResult(v8s.bytes);
      expect(parsed.code, 2);
      expect(parsed.packageName, 'com.example.failed');
    });

    test('RPK 畸形安装结果不会被误判为设备明确失败', () {
      expect(
        () => V8s.parseInstallResult(const []),
        throwsA(isA<FormatException>()),
      );
      final withoutPackage = ProtoWriter()
        ..writeMessage(4, (ProtoWriter()..writeInt(1, 0)).bytes);
      expect(
        () => V8s.parseInstallResult(withoutPackage.bytes),
        throwsA(isA<FormatException>()),
      );
    });

    test('MassPrepare 请求', () {
      final md5 = List<int>.generate(16, (i) => i);
      final zau = Zau(
        command: 22,
        sub: 0,
        payload:
            O1h.prepareRequest(dataType: 0x40, fileMd5: md5, fileLength: 1000),
      ).encode();
      final parsed = Zau.parse(zau);
      expect(parsed.command, 22);
      expect(parsed.payload!.$1, 24); // o1h 是 zau 的 oneof field 24
      final o1h = ProtoReader(parsed.payload!.$2);
      expect(o1h.readFieldHeader(), (1, 2));
      final s1h = ProtoReader(o1h.readBytes());
      expect(s1h.readFieldHeader(), (1, 0));
      expect(s1h.readVarint(), 0x40);
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
      expect(
          segs.map((segment) => segment.fileByteCount).reduce((a, b) => a + b),
          file.length);
      expect(segs.first.fileByteCount, 38); // 60B 正文减去 22B Mass 头
      expect(segs.last.fileByteCount, 2); // 不把末尾 CRC32 计入文件进度
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
      expect(segs.single.fileByteCount, 10);
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
      expect(segs.single.fileByteCount, 6);
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

  group('CRC16', () {
    test('CRC-16/IBM 标准向量 123456789 → 0xBB3D', () {
      final data = '123456789'.codeUnits;
      expect(computeCrc16(data), 0xBB3D);
      // 空数据 CRC=0
      expect(computeCrc16(const []), 0);
    });
  });

  group('会话 AES-CTR', () {
    test('V2 AES-CTR 使用同方向密钥作为 key 和 IV，且可逆', () {
      final keys = SessionKeys(
        deviceKey: List<int>.filled(16, 0x11),
        appKey: List<int>.filled(16, 0x22),
        deviceIv: [1, 2, 3, 4],
        appIv: [5, 6, 7, 8],
      );
      final cipher = SessionCipher(keys);
      final message = List<int>.generate(37, (index) => index);
      final encoded = cipher.encryptOutbound(message);
      expect(encoded, isNot(message));

      // CTR 同一方向密钥变换两次即可恢复明文。
      final appSide = SessionKeys(
        deviceKey: keys.appKey,
        appKey: keys.deviceKey,
        deviceIv: keys.appIv,
        appIv: keys.deviceIv,
      );
      expect(
        SessionCipher(appSide).decryptInbound(encoded),
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
      final l1 =
          SppProtocol.buildDataFrame(0, XiaomiAuth.buildNonceCommand(nonce));
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
        0,
        0,
        0,
        1,
        0,
        0,
        3,
        0xea,
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
      final okm =
          XiaomiAuth.computeStep3Hmac(secretKey, phoneNonce, watchNonce);
      final deviceKey = okm.sublist(0, 16);
      final watchHmac =
          XiaomiAuth.hmacSha256(deviceKey, [...watchNonce, ...phoneNonce]);
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
      final engine = AESEngine()
        ..init(false, KeyParameter(Uint8List.fromList(key)));
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
      final len =
          cipher.processBytes(Uint8List.fromList(enc), 0, enc.length, out, 0);
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
      expect(frame, [
        0xba,
        0xdc,
        0xfe,
        0x00,
        0xc0,
        0x04,
        0x00,
        0x00,
        0x00,
        0x00,
        0x01,
        0xef
      ]);
    });

    test('解析设备版本回包 type=106', () {
      // 14 字节：3 magic + 2 header + 2 dataLen(6) + 3 type/c/d + 3 payload + 1 end
      final resp = [
        0xba,
        0xdc,
        0xfe,
        0x00,
        0xc0,
        0x06,
        0x00,
        0x6a,
        0x00,
        0x00,
        0x01,
        0x02,
        0x03,
        0xef
      ];
      final packet = SppProtocol.parseSppPacket(resp);
      expect(packet, isNotNull);
      final (type, payload) = packet!;
      expect(type, 106);
      expect(payload, [1, 2, 3]);
    });
  });
}
