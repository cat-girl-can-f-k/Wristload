import 'package:flutter_test/flutter_test.dart';

import 'package:wristload/domain/protocol/proto_wire.dart';
import 'package:wristload/domain/protocol/zau.dart';

void main() {
  group('Watchface protocol', () {
    test('parses the device-installed watchface list', () {
      final current = ProtoWriter()
        ..writeString(1, '42')
        ..writeString(2, 'Classic')
        ..writeBool(3, true)
        ..writeBool(4, true)
        ..writeInt(5, 9);
      final system = ProtoWriter()
        ..writeString(1, 'system')
        ..writeString(2, 'System face')
        ..writeBool(3, false)
        ..writeBool(4, false)
        ..writeInt(5, 1);
      final wrapper = ProtoWriter()
        ..writeMessage(1, current.bytes)
        ..writeMessage(1, system.bytes);
      final a9u = ProtoWriter()..writeMessage(1, wrapper.bytes);

      final parsed = A9u.parseInstalledWatchfaces(a9u.bytes);

      expect(parsed, hasLength(2));
      expect(parsed.first.id, '42');
      expect(parsed.first.name, 'Classic');
      expect(parsed.first.isCurrent, isTrue);
      expect(parsed.first.canRemove, isTrue);
      expect(parsed.first.versionCode, 9);
      expect(parsed.last.id, 'system');
      expect(parsed.last.isCurrent, isFalse);
      expect(parsed.last.canRemove, isFalse);
    });

    test('rejects a watchface response without the list wrapper', () {
      expect(
        () => A9u.parseInstalledWatchfaces(const <int>[]),
        throwsA(isA<FormatException>()),
      );
    });

    test('parses the explicit watchface deletion result', () {
      final succeeded = ProtoWriter()..writeBool(4, true);
      final rejected = ProtoWriter()..writeBool(4, false);

      expect(A9u.parseWatchfaceDeletionResult(succeeded.bytes), isTrue);
      expect(A9u.parseWatchfaceDeletionResult(rejected.bytes), isFalse);
      expect(A9u.parseWatchfaceDeletionResult(const <int>[]), isNull);
    });

    test('parses the explicit watchface activation result', () {
      final succeeded = ProtoWriter()..writeBool(4, true);
      final rejected = ProtoWriter()..writeBool(4, false);

      expect(A9u.parseWatchfaceActivationResult(succeeded.bytes), isTrue);
      expect(A9u.parseWatchfaceActivationResult(rejected.bytes), isFalse);
      expect(A9u.parseWatchfaceActivationResult(const <int>[]), isNull);
    });

    test('parses a replaceable duplicate preinstall response', () {
      final z8u = ProtoWriter()
        ..writeString(1, '42')
        ..writeInt(2, 3)
        ..writeInt(4, 4096)
        ..writeBool(5, true);
      final a9u = ProtoWriter()..writeMessage(9, z8u.bytes);

      final parsed = A9u.parse(a9u.bytes);

      expect(parsed.kind, 'error');
      expect(parsed.code, 3);
      expect(parsed.faceId, '42');
      expect(parsed.expectedSliceLength, 4096);
      expect(parsed.canReplace, isTrue);
    });

    test('serializes an uninstall request with the face ID payload', () {
      final encoded = Zau(
        command: ZauCommand.setFace,
        sub: ZauCommand.uninstallWatchfaceSub,
        payload: A9u.withFaceId('42'),
      ).encode();

      final parsed = Zau.parse(encoded);
      expect(parsed.command, ZauCommand.setFace);
      expect(parsed.sub, ZauCommand.uninstallWatchfaceSub);
      expect(parsed.payload!.$1, 6);
      final a9u = ProtoReader(parsed.payload!.$2);
      expect(a9u.readFieldHeader(), (2, 2));
      expect(a9u.readString(), '42');
      expect(a9u.isAtEnd, isTrue);
    });

    test('serializes an activation request with the face ID payload', () {
      final encoded = Zau(
        command: ZauCommand.setFace,
        sub: ZauCommand.activateWatchfaceSub,
        payload: A9u.withFaceId('42'),
      ).encode();

      final parsed = Zau.parse(encoded);
      expect(parsed.command, ZauCommand.setFace);
      expect(parsed.sub, ZauCommand.activateWatchfaceSub);
      expect(parsed.payload!.$1, 6);
      final a9u = ProtoReader(parsed.payload!.$2);
      expect(a9u.readFieldHeader(), (2, 2));
      expect(a9u.readString(), '42');
      expect(a9u.isAtEnd, isTrue);
    });
  });
}
