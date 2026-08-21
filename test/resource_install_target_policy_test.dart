import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/domain/resource_install_target_policy.dart';

void main() {
  test('defaults resource installation routing to manual selection', () {
    const policy = ResourceInstallTargetPolicy();

    expect(policy.mode, ResourceInstallTargetMode.manual);
    expect(policy.automaticDeviceId, isNull);
  });
}
