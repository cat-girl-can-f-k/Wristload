import 'package:test/test.dart';
import 'package:wristload_tui/src/backend_next/tui_mac_bluetooth_transport.dart';

void main() {
  test('identity candidate requires explicit exact-address direction intent',
      () {
    final strict = TuiIdentityCandidate(
      candidateId: 'strict',
      advertisedName: 'Xiaomi Smart Band 10',
      address: 'AA-BB-CC-DD-EE-09',
    );
    final directed = TuiIdentityCandidate(
      candidateId: 'directed',
      advertisedName: strict.advertisedName,
      address: strict.address,
      directedExactAddress: true,
    );

    expect(strict.addressKey, 'AABBCCDDEE09');
    expect(strict.directedExactAddress, isFalse);
    expect(directed.addressKey, strict.addressKey);
    expect(directed.directedExactAddress, isTrue);
  });

  test('snapshot preserves structured native transport evidence', () {
    const snapshot = TuiMacTransportSnapshot(
      helperState: TuiMacHelperState.ready,
      scanning: false,
      connected: true,
      transport: 'classic-rfcomm',
      endpoint: '/dev/cu.Xiaomi',
      serviceUuid: '00001101-0000-1000-8000-00805f9b34fb',
      channel: 7,
      mtu: 990,
      helperSessionId: 'helper-1',
      connectionId: 'helper-1-c1',
      addressKey: 'AABBCCDDEEFF',
      stage: 'rfcomm.open.completed',
      stageCode: 'connected',
      stageDetail: 'RFCOMM channel opened',
    );

    final decoded = TuiMacTransportSnapshot.fromJson(snapshot.toJson());
    expect(decoded.helperState, TuiMacHelperState.ready);
    expect(decoded.connected, isTrue);
    expect(decoded.transport, 'classic-rfcomm');
    expect(decoded.endpoint, '/dev/cu.Xiaomi');
    expect(decoded.serviceUuid, contains('00001101'));
    expect(decoded.channel, 7);
    expect(decoded.mtu, 990);
    expect(decoded.helperSessionId, 'helper-1');
    expect(decoded.connectionId, 'helper-1-c1');
    expect(decoded.addressKey, 'AABBCCDDEEFF');
    expect(decoded.activeSessionId, 'helper-1-c1');
    expect(decoded.stage, 'rfcomm.open.completed');
    expect(decoded.stageCode, 'connected');
    expect(decoded.stageDetail, 'RFCOMM channel opened');
  });

  test('snapshot parser accepts native mtuBytes and stageMessage aliases', () {
    final snapshot = TuiMacTransportSnapshot.fromJson({
      'helperState': 'failed',
      'scanning': false,
      'connected': false,
      'mtuBytes': 512,
      'stage': 'rfcomm.open.timeout',
      'stageMessage': 'open callback timeout',
    });

    expect(snapshot.helperState, TuiMacHelperState.failed);
    expect(snapshot.mtu, 512);
    expect(snapshot.stageDetail, 'open callback timeout');
  });

  test('native exception preserves domain/code and correlation evidence', () {
    final error = TuiNativeTransportException.fromJson({
      'errorCode': 'rfcomm_open_failed',
      'errorMessage': 'RFCOMM open failed',
      'errorDomain': 'IOBluetoothErrorDomain',
      'nativeCode': 0x1234,
      'helperSessionId': 'helper-2',
      'connectionId': 'helper-2-c3',
      'addressKey': '001122334455',
      'transport': 'classic-rfcomm',
      'endpoint': 'channel:9',
      'channel': 9,
      'stage': 'rfcomm.open.failed',
      'stageCode': 'open_failed',
    });

    expect(error.code, 'rfcomm_open_failed');
    expect(error.message, 'RFCOMM open failed');
    expect(error.domain, 'IOBluetoothErrorDomain');
    expect(error.errorDomain, 'IOBluetoothErrorDomain');
    expect(error.nativeCode, 0x1234);
    expect(error.errorCodeValue, 0x1234);
    expect(error.activeSessionId, 'helper-2-c3');
    expect(error.connectionId, 'helper-2-c3');
    expect(error.endpoint, 'channel:9');
    expect(error.channel, 9);
    expect(error.stage, 'rfcomm.open.failed');
  });

  test('legacy constructors remain source compatible', () {
    const snapshot = TuiMacTransportSnapshot(
      helperState: TuiMacHelperState.stopped,
      scanning: false,
      connected: false,
      message: 'stopped',
    );
    const error = TuiNativeTransportException('native_error', 'failed');

    expect(snapshot.message, 'stopped');
    expect(snapshot.transport, isNull);
    expect(error.code, 'native_error');
    expect(error.message, 'failed');
    expect(error.domain, isNull);
    expect(error.nativeCode, isNull);
  });
}
