import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miwearable_install_tool/domain/firmware_package_inspector.dart';
import 'package:miwearable_install_tool/presentation/firmware_inspection_dialog.dart';

void main() {
  testWidgets('固件检查弹窗展示本地检查结果与禁止传输提示', (tester) async {
    final inspection = FirmwarePackageInspection(
      fileName: 'firmware.bin',
      fileSize: 4096,
      entryCount: 5,
      declaredExpandedBytes: 8192,
      manifestName: 'ota.json',
      target: 'n66',
      softwareVersion: '3.1.26',
      firmwareType: 'all',
      partitionFiles: const ['system.bin'],
      referencedFiles: const ['system.bin'],
      missingFiles: const [],
      signatureFiles: const ['META-INF/CERT.RSA'],
      warnings: const ['仅发现签名材料，尚未验证证书链或包签名'],
      errors: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FirmwareInspectionDialog(inspection: inspection)),
      ),
    );

    expect(find.text('固件包检查完成'), findsOneWidget);
    expect(find.text('n66'), findsOneWidget);
    expect(find.text('3.1.26'), findsOneWidget);
    expect(find.textContaining('未向设备发送任何数据'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('firmware-no-transfer-notice')),
      findsOneWidget,
    );
    expect(inspection.transmissionSupported, isFalse);
  });
}
