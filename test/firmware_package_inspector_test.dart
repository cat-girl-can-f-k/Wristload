import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/domain/firmware_package_inspector.dart';

void main() {
  late Directory tempDirectory;

  setUp(() async {
    tempDirectory =
        await Directory.systemTemp.createTemp('miwear-firmware-test-');
  });

  tearDown(() async {
    if (tempDirectory.existsSync()) {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('读取 ota.json 元数据、分区引用与签名材料，但不开放传输', () async {
    final file = await _writeFirmware(
      tempDirectory,
      'firmware.bin',
      {
        'ota.json': jsonEncode({
          'magic_string': 'n66',
          'sw_version': '3.1.26',
          'firmware_type': 'all',
          'sections': [
            {'location_path': 'recovery.bin'},
            {'location_path': 'images/system.bin'},
          ],
        }),
        'recovery.bin': [1, 2, 3],
        'images/system.bin': [4, 5, 6],
        'META-INF/MANIFEST.MF': 'Manifest-Version: 1.0\r\n',
        'META-INF/CERT.SF': 'signature manifest',
        'META-INF/CERT.RSA': [7, 8, 9],
      },
    );

    final result = await const FirmwarePackageInspector().inspect(file.path);

    expect(result.fileName, 'firmware.bin');
    expect(result.manifestName, 'ota.json');
    expect(result.target, 'n66');
    expect(result.softwareVersion, '3.1.26');
    expect(result.firmwareType, 'all');
    expect(result.referencedFiles, ['recovery.bin', 'images/system.bin']);
    expect(result.partitionFiles, ['recovery.bin', 'images/system.bin']);
    expect(result.missingFiles, isEmpty);
    expect(result.hasSignatureMaterial, isTrue);
    expect(result.hasCompleteSignatureSet, isTrue);
    expect(result.packageStructureValid, isTrue);
    expect(result.transmissionSupported, isFalse);
  });

  test('ota.json 引用缺失分区时明确标记无效', () async {
    final file = await _writeFirmware(
      tempDirectory,
      'missing.zip',
      {
        'ota.json': jsonEncode({
          'sections': [
            {'location_path': 'missing.bin'},
          ],
        }),
        'present.bin': [1],
      },
    );

    final result = const FirmwarePackageInspector().inspectSync(file.path);

    expect(result.missingFiles, ['missing.bin']);
    expect(result.errors, contains('清单引用了 1 个不存在的文件'));
    expect(result.packageStructureValid, isFalse);
    expect(result.transmissionSupported, isFalse);
  });

  test('读取 ota.sh 中的分区路径且不解压其他分区内容', () async {
    final file = await _writeFirmware(
      tempDirectory,
      'shell.zip',
      {
        'ota.sh': 'dd if=/ota/vela_system.bin of=/dev/system\n'
            'dd if=/ota/vela_app.bin of=/dev/app\n',
        'vela_system.bin': [1, 2],
        'vela_app.bin': [3, 4],
      },
    );

    final result = const FirmwarePackageInspector().inspectSync(file.path);

    expect(result.manifestName, 'ota.sh');
    expect(result.referencedFiles, ['vela_system.bin', 'vela_app.bin']);
    expect(result.partitionFiles, ['vela_system.bin', 'vela_app.bin']);
    expect(result.packageStructureValid, isTrue);
  });

  test('拒绝伪装成 .bin 的非 ZIP 文件', () async {
    final file = File(
      '${tempDirectory.path}${Platform.pathSeparator}not-firmware.bin',
    );
    await file.writeAsString('not a zip');

    expect(
      () => const FirmwarePackageInspector().inspectSync(file.path),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('不是 ZIP 固件容器'),
        ),
      ),
    );
  });

  test('拒绝超过声明解压总量安全上限的包', () async {
    final file = await _writeFirmware(
      tempDirectory,
      'oversized.zip',
      {
        'ota.json': '{}',
        'partition.bin': List<int>.filled(32, 0),
      },
    );

    expect(
      () => const FirmwarePackageInspector(maxExpandedBytes: 16)
          .inspectSync(file.path),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('解压总量'),
        ),
      ),
    );
  });
}

Future<File> _writeFirmware(
  Directory directory,
  String fileName,
  Map<String, Object> entries,
) async {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = switch (entry.value) {
      final String value => utf8.encode(value),
      final List<int> value => value,
      _ => throw ArgumentError.value(entry.value),
    };
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  final encoded = ZipEncoder().encode(archive)!;
  final file = File('${directory.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(encoded, flush: true);
  return file;
}
