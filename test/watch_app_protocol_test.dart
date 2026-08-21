import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/domain/protocol/proto_wire.dart';
import 'package:wristload/domain/protocol/zau.dart';

void main() {
  test('parses installed quick app metadata', () {
    final app = ProtoWriter()
      ..writeString(1, 'com.example.demo')
      ..writeBytes(2, [0x01, 0xab, 0xff])
      ..writeInt(3, 17)
      ..writeBool(4, true)
      ..writeString(5, 'Demo');
    final appList = ProtoWriter()..writeMessage(1, app.bytes);
    final v8s = ProtoWriter()..writeMessage(1, appList.bytes);

    final parsed = V8s.parseInstalledApps(v8s.bytes);
    expect(parsed, hasLength(1));
    expect(parsed.single.packageName, 'com.example.demo');
    expect(parsed.single.displayName, 'Demo');
    expect(parsed.single.versionCode, 17);
    expect(parsed.single.canRemove, isTrue);
    expect(parsed.single.fingerprint, [0x01, 0xab, 0xff]);
  });

  test('decodes UTF-8 quick app names', () {
    final app = ProtoWriter()
      ..writeString(1, 'com.anemo.cn')
      ..writeString(5, '小米运动');
    final appList = ProtoWriter()..writeMessage(1, app.bytes);
    final v8s = ProtoWriter()..writeMessage(1, appList.bytes);

    final parsed = V8s.parseInstalledApps(v8s.bytes);

    expect(parsed.single.displayName, '小米运动');
  });

  test('parses every entry in the installed quick app list wrapper', () {
    final first = ProtoWriter()
      ..writeString(1, 'com.anemo.first')
      ..writeBytes(2, [0x01])
      ..writeInt(3, 1)
      ..writeBool(4, true);
    final second = ProtoWriter()
      ..writeString(1, 'com.anemo.second')
      ..writeBytes(2, [0x02])
      ..writeInt(3, 2)
      ..writeBool(4, false)
      ..writeString(5, 'Second');
    final appList = ProtoWriter()
      ..writeMessage(1, first.bytes)
      ..writeMessage(1, second.bytes);
    final v8s = ProtoWriter()..writeMessage(1, appList.bytes);

    final parsed = V8s.parseInstalledApps(v8s.bytes);

    expect(parsed.map((app) => app.packageName), [
      'com.anemo.first',
      'com.anemo.second',
    ]);
    expect(parsed[1].displayName, 'Second');
    expect(parsed[1].canRemove, isFalse);
  });

  test('accepts an empty installed quick app list wrapper', () {
    final v8s = ProtoWriter()..writeMessage(1, const []);

    expect(V8s.parseInstalledApps(v8s.bytes), isEmpty);
  });

  test('rejects a response without an installed quick app list wrapper', () {
    final v8s = ProtoWriter()..writeMessage(2, [0x01]);

    expect(
      () => V8s.parseInstalledApps(v8s.bytes),
      throwsA(isA<FormatException>()),
    );
  });

  test('encodes uninstall request with original fingerprint', () {
    final payload = V8s.uninstallRequest(
      packageName: 'com.example.demo',
      fingerprint: [0x01, 0xab, 0xff],
    );
    expect(payload.$1, 22);
    final v8s = ProtoReader(payload.$2);
    expect(v8s.readFieldHeader(), (5, 2));
    final request = ProtoReader(v8s.readBytes());
    expect(request.readFieldHeader(), (1, 2));
    expect(request.readString(), 'com.example.demo');
    expect(request.readFieldHeader(), (2, 2));
    expect(request.readBytes(), [0x01, 0xab, 0xff]);
    expect(request.isAtEnd, isTrue);
  });

  test('encodes a launch request with package fingerprint and root URI', () {
    final payload = V8s.launchRequest(
      packageName: 'com.example.demo',
      fingerprint: [0x01, 0xab, 0xff],
    );

    expect(payload.$1, 22);
    final v8s = ProtoReader(payload.$2);
    expect(v8s.readFieldHeader(), (6, 2));

    final launch = ProtoReader(v8s.readBytes());
    expect(launch.readFieldHeader(), (1, 2));
    final app = ProtoReader(launch.readBytes());
    expect(app.readFieldHeader(), (1, 2));
    expect(app.readString(), 'com.example.demo');
    expect(app.readFieldHeader(), (2, 2));
    expect(app.readBytes(), [0x01, 0xab, 0xff]);
    expect(app.isAtEnd, isTrue);
    expect(launch.readFieldHeader(), (2, 2));
    expect(launch.readString(), '/');
    expect(launch.isAtEnd, isTrue);
    expect(v8s.isAtEnd, isTrue);
  });

  test('omits an unavailable fingerprint from a launch request', () {
    final payload = V8s.launchRequest(
      packageName: 'com.example.system',
      fingerprint: const [],
    );

    final v8s = ProtoReader(payload.$2);
    expect(v8s.readFieldHeader(), (6, 2));
    final launch = ProtoReader(v8s.readBytes());
    expect(launch.readFieldHeader(), (1, 2));
    final app = ProtoReader(launch.readBytes());
    expect(app.readFieldHeader(), (1, 2));
    expect(app.readString(), 'com.example.system');
    expect(app.isAtEnd, isTrue);
  });

  test('rejects an installed app entry without package name', () {
    final app = ProtoWriter()..writeInt(3, 1);
    final appList = ProtoWriter()..writeMessage(1, app.bytes);
    final v8s = ProtoWriter()..writeMessage(1, appList.bytes);
    expect(
      () => V8s.parseInstalledApps(v8s.bytes),
      throwsA(isA<FormatException>()),
    );
  });
}
