import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:wristload_tui/src/domain/protocol/auth_handshake.dart';

void main() {
  test('f=26 encodes and parses APK hc0 appDeviceId and hasOob fields', () {
    final nonce = List<int>.generate(16, (index) => index);
    final command = XiaomiAuth.buildNonceCommand(
      nonce,
      appDeviceId: 'app-device-7',
      hasOob: true,
    );

    final parsed = XiaomiAuth.parse(command);
    expect(parsed, isNotNull);
    expect(parsed!.appNonce, nonce);
    expect(parsed.appDeviceId, 'app-device-7');
    expect(parsed.hasOob, isTrue);
  });

  test('f=26 without optional material contains only the phone nonce', () {
    final nonce = List<int>.generate(16, (index) => index + 16);
    final parsed = XiaomiAuth.parse(XiaomiAuth.buildNonceCommand(nonce));

    expect(parsed, isNotNull);
    expect(parsed!.appNonce, nonce);
    expect(parsed.appDeviceId, isNull);
    expect(parsed.hasOob, isFalse);
  });

  test('HKDF extract uses nonce pair as HMAC key and authkey as data', () {
    final authkey = List<int>.generate(16, (index) => index);
    final phoneNonce = List<int>.generate(16, (index) => 0x10 + index);
    final watchNonce = List<int>.generate(16, (index) => 0x20 + index);
    final actual = XiaomiAuth.computeStep3Hmac(
      authkey,
      phoneNonce,
      watchNonce,
    );

    final prk =
        Hmac(sha256, [...phoneNonce, ...watchNonce]).convert(authkey).bytes;
    final info = utf8.encode('miwear-auth');
    final expected = <int>[];
    var previous = <int>[];
    for (var counter = 1; expected.length < 64; counter++) {
      previous =
          Hmac(sha256, prk).convert([...previous, ...info, counter]).bytes;
      expected.addAll(previous);
    }
    expect(actual, expected.sublist(0, 64));

    // HMAC is directional. This guards against the previously inverted
    // extract arguments, which would derive different session material.
    final reversedPrk =
        Hmac(sha256, authkey).convert([...phoneNonce, ...watchNonce]).bytes;
    final reversed = <int>[];
    previous = <int>[];
    for (var counter = 1; reversed.length < 64; counter++) {
      previous = Hmac(sha256, reversedPrk)
          .convert([...previous, ...info, counter]).bytes;
      reversed.addAll(previous);
    }
    expect(actual, isNot(reversed.sublist(0, 64)));
  });

  test('f=27 device signature uses only independent oob, never appDeviceId',
      () {
    final secret = List<int>.generate(16, (index) => index);
    final phoneNonce = List<int>.generate(16, (index) => 0x10 + index);
    final watchNonce = List<int>.generate(16, (index) => 0x20 + index);
    final keyMaterial = XiaomiAuth.computeStep3Hmac(
      secret,
      phoneNonce,
      watchNonce,
    );
    final deviceKey = keyMaterial.sublist(0, 16);
    final baseInput = [...watchNonce, ...phoneNonce];
    final baseHmac = XiaomiAuth.hmacSha256(deviceKey, baseInput);

    // appDeviceId is intentionally absent from this API: it belongs only to
    // f=26. A signature without OOB must use only watchNonce || phoneNonce.
    expect(
      XiaomiAuth.buildAuthStep3Command(
        secretKey: secret,
        phoneNonce: phoneNonce,
        watchNonce: watchNonce,
        watchHmac: baseHmac,
        oob: null,
      ),
      isNotNull,
    );

    const oob = 'oob-token';
    final oobHmac = XiaomiAuth.hmacSha256(
      deviceKey,
      [...baseInput, ...utf8.encode(oob)],
    );
    expect(
      XiaomiAuth.buildAuthStep3Command(
        secretKey: secret,
        phoneNonce: phoneNonce,
        watchNonce: watchNonce,
        watchHmac: oobHmac,
        oob: oob,
      ),
      isNotNull,
    );
    expect(
      XiaomiAuth.buildAuthStep3Command(
        secretKey: secret,
        phoneNonce: phoneNonce,
        watchNonce: watchNonce,
        watchHmac: oobHmac,
        oob: null,
      ),
      isNull,
    );
  });
}
