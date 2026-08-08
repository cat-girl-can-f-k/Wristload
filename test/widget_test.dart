import 'package:flutter_test/flutter_test.dart';

import 'package:miwearable_install_tool/domain/device_profile.dart';

void main() {
  test('known profile hints stay restricted to verified observations', () {
    final hints = DeviceProfile.supported.expand((profile) => profile.modelHints);
    expect(hints, contains('miwear.watch.n66'));
    expect(hints, contains('miwear.watch.o63'));
  });
}
