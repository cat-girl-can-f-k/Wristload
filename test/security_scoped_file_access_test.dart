import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/domain/install_metadata_reader.dart';
import 'package:wristload/domain/install_task.dart';
import 'package:wristload/platform/security_scoped_file_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('wristload/security_scope');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('uses a replacement bookmark and stops the lease exactly once', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'startAccess') {
        return <String, Object>{
          'started': true,
          'token': 'lease-1',
          'path': '/resolved/dial.bin',
          'bookmark': Uint8List.fromList([4, 5, 6]),
        };
      }
      return null;
    });

    final lease = await SecurityScopedFileAccess.instance.acquire(
      ScopedFileRef(
        path: '/old/dial.bin',
        bookmark: Uint8List.fromList([1, 2, 3]),
      ),
    );

    expect(lease.file.path, '/resolved/dial.bin');
    expect(lease.file.bookmark, [4, 5, 6]);
    await lease.close();
    await lease.close();

    expect(calls.map((call) => call.method), ['startAccess', 'stopAccess']);
    expect((calls.last.arguments as Map<Object?, Object?>)['token'], 'lease-1');
  });

  test('macOS rejects an unbookmarked path before calling native code',
      () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    await expectLater(
      SecurityScopedFileAccess.instance.acquire(
        const ScopedFileRef(path: '/tmp/unscoped.bin'),
      ),
      throwsStateError,
    );

    expect(calls, isEmpty);
  });

  test('direct macOS metadata reads reject a missing bookmark', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    await expectLater(
      InstallMetadataReader().read(
        InstallKind.watchface,
        '/tmp/unscoped.bin',
      ),
      throwsStateError,
    );

    expect(calls, isEmpty);
  });

  test('non-macOS unbookmarked paths remain no-op leases', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    final lease = await SecurityScopedFileAccess.instance.acquire(
      const ScopedFileRef(path: '/tmp/plain.bin'),
    );
    expect(lease.file.path, '/tmp/plain.bin');
    await lease.close();

    expect(calls, isEmpty);
  });

  test('stops a native token when the response is malformed', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'startAccess') {
        return <String, Object>{
          'started': true,
          'token': 'lease-2',
          'path': '/resolved/dial.bin',
          'bookmark': 'not-bytes',
        };
      }
      return null;
    });

    await expectLater(
      SecurityScopedFileAccess.instance.acquire(
        ScopedFileRef(
          path: '/old/dial.bin',
          bookmark: Uint8List.fromList([1]),
        ),
      ),
      throwsStateError,
    );

    expect(methods, ['startAccess', 'stopAccess']);
  });

  test('withAccess stops the lease when the action throws', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'startAccess') {
        return <String, Object>{
          'started': true,
          'token': 'lease-3',
          'path': '/resolved/app.rpk',
        };
      }
      return null;
    });

    await expectLater(
      SecurityScopedFileAccess.instance.withAccess<void>(
        ScopedFileRef(
          path: '/old/app.rpk',
          bookmark: Uint8List.fromList([9]),
        ),
        (_) async => throw StateError('read failed'),
      ),
      throwsStateError,
    );

    expect(methods, ['startAccess', 'stopAccess']);
  });

  test('withAccess propagates a cleanup failure after a successful action',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startAccess') {
        return <String, Object>{
          'started': true,
          'token': 'lease-cleanup',
          'path': '/resolved/app.rpk',
        };
      }
      throw PlatformException(code: 'stop_failed');
    });

    await expectLater(
      SecurityScopedFileAccess.instance.withAccess<int>(
        ScopedFileRef(
          path: '/old/app.rpk',
          bookmark: Uint8List.fromList([9]),
        ),
        (_) async => 42,
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'stop_failed',
        ),
      ),
    );
  });

  test('withAccess preserves the action failure when cleanup also fails',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startAccess') {
        return <String, Object>{
          'started': true,
          'token': 'lease-primary-error',
          'path': '/resolved/app.rpk',
        };
      }
      throw PlatformException(code: 'stop_failed');
    });

    await expectLater(
      SecurityScopedFileAccess.instance.withAccess<void>(
        ScopedFileRef(
          path: '/old/app.rpk',
          bookmark: Uint8List.fromList([9]),
        ),
        (_) async => throw StateError('read failed'),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'read failed',
        ),
      ),
    );
  });

  test('retries stopAccess after a close failure', () async {
    var stopAttempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startAccess') {
        return <String, Object>{
          'started': true,
          'token': 'lease-4',
          'path': '/resolved/app.rpk',
        };
      }
      stopAttempts++;
      if (stopAttempts == 1) {
        throw PlatformException(code: 'stop_failed');
      }
      return null;
    });

    final lease = await SecurityScopedFileAccess.instance.acquire(
      ScopedFileRef(
        path: '/old/app.rpk',
        bookmark: Uint8List.fromList([8]),
      ),
    );

    await expectLater(lease.close(), throwsA(isA<PlatformException>()));
    await lease.close();
    await lease.close();
    expect(stopAttempts, 2);
  });

  test('stops a valid token when startAccess returns an empty path', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'startAccess') {
        return <String, Object>{
          'started': true,
          'token': 'lease-5',
          'path': '',
        };
      }
      return null;
    });

    await expectLater(
      SecurityScopedFileAccess.instance.acquire(
        ScopedFileRef(
          path: '/old/app.rpk',
          bookmark: Uint8List.fromList([7]),
        ),
      ),
      throwsStateError,
    );
    expect(methods, ['startAccess', 'stopAccess']);
  });
}
