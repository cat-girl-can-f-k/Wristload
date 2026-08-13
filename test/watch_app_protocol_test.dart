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
    final v8s = ProtoWriter()..writeMessage(1, app.bytes);

    final parsed = V8s.parseInstalledApps(v8s.bytes);
    expect(parsed, hasLength(1));
    expect(parsed.single.packageName, 'com.example.demo');
    expect(parsed.single.displayName, 'Demo');
    expect(parsed.single.versionCode, 17);
    expect(parsed.single.canRemove, isTrue);
    expect(parsed.single.fingerprint, [0x01, 0xab, 0xff]);
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

  test('rejects an installed app entry without package name', () {
    final app = ProtoWriter()..writeInt(3, 1);
    final v8s = ProtoWriter()..writeMessage(1, app.bytes);
    expect(
      () => V8s.parseInstalledApps(v8s.bytes),
      throwsA(isA<FormatException>()),
    );
  });
}
