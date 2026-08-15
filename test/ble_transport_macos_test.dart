import 'dart:async';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/platform/ble_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('wristload/rfcomm');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('passes the complete Darwin identity to pair and connect', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'confirmIdentity') return null;
      return <String, Object>{
        'address': 'AA:BB:CC:DD:EE:FF',
        'name': 'Xiaomi Smart Band 9',
      };
    });
    final transport = BleTransport();
    final identifier =
        UUID.fromString('12345678-90ab-cdef-1234-567890abcdef');

    expect(
      await transport.pairDevice(
        identifier,
        advertisedName: ' Xiaomi Smart Band 9 ',
      ),
      'AA:BB:CC:DD:EE:FF',
    );
    expect(
      await transport.connectRfcomm(
        identifier,
        advertisedName: 'Xiaomi Smart Band 9',
      ),
      'AA:BB:CC:DD:EE:FF',
    );
    await transport.confirmRfcommIdentity(
      identifier,
      advertisedName: 'Xiaomi Smart Band 9',
    );

    expect(
      calls.map((call) => call.method),
      ['pair', 'connect', 'confirmIdentity'],
    );
    for (final call in calls) {
      final identity = call.arguments as Map<Object?, Object?>;
      expect(
        identity['peripheralId'],
        '12345678-90ab-cdef-1234-567890abcdef',
      );
      expect(identity['name'], 'Xiaomi Smart Band 9');
      expect(identity.containsKey('address'), isFalse);
    }
  });

  test('requires an advertised name before invoking native macOS code', () async {
    var invoked = false;
    messenger.setMockMethodCallHandler(channel, (_) async {
      invoked = true;
      return null;
    });
    final transport = BleTransport();
    final identifier =
        UUID.fromString('12345678-90ab-cdef-1234-567890abcdef');

    await expectLater(
      transport.pairDevice(identifier),
      throwsA(isA<ArgumentError>()),
    );
    expect(invoked, isFalse);
  });

  test('forgets only the saved Darwin-to-classic identity mapping', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final transport = BleTransport();
    final identifier =
        UUID.fromString('12345678-90ab-cdef-1234-567890abcdef');

    await transport.forgetRfcommIdentity(identifier);

    expect(received?.method, 'forgetIdentity');
    expect(received?.arguments, <String, Object>{
      'peripheralId': '12345678-90ab-cdef-1234-567890abcdef',
    });
  });

  test('a reconnect does not wait for writes queued by the old session',
      () async {
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    final nativeWrites = <int>[];
    addTearDown(() {
      if (!releaseFirstWrite.isCompleted) releaseFirstWrite.complete();
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'connect') {
        return <String, Object>{
          'address': 'AA:BB:CC:DD:EE:FF',
          'name': 'Xiaomi Smart Band 9',
        };
      }
      if (call.method == 'write') {
        final bytes = call.arguments as Uint8List;
        nativeWrites.add(bytes.first);
        if (bytes.first == 1) {
          firstWriteStarted.complete();
          await releaseFirstWrite.future;
        }
        return null;
      }
      return null;
    });

    final transport = BleTransport();
    final identifier =
        UUID.fromString('12345678-90ab-cdef-1234-567890abcdef');
    await transport.connectRfcomm(
      identifier,
      advertisedName: 'Xiaomi Smart Band 9',
    );

    final inFlight = transport.rfcommWrite(identifier, [1]);
    await firstWriteStarted.future;
    final queued = transport.rfcommWrite(identifier, [2]);
    final inFlightFailure = expectLater(inFlight, throwsStateError);
    final queuedFailure = expectLater(queued, throwsStateError);

    await transport.connectRfcomm(
      identifier,
      advertisedName: 'Xiaomi Smart Band 9',
    );
    await transport.rfcommWrite(identifier, [3]);
    expect(nativeWrites, [1, 3]);

    releaseFirstWrite.complete();
    await inFlightFailure;
    await queuedFailure;
    expect(nativeWrites, [1, 3]);
  });
}
