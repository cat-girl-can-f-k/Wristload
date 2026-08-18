import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/domain/install_metadata_reader.dart';
import 'package:wristload/domain/install_task.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('quick-app-bin-');
  });

  tearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  Future<File> writeBin(Map<String, String> entries) async {
    final archive = Archive();
    for (final entry in entries.entries) {
      archive.addFile(ArchiveFile.string(entry.key, entry.value));
    }
    final file = File('${directory.path}/quick-app.bin');
    await file.writeAsBytes(Uint8List.fromList(ZipEncoder().encode(archive)!));
    return file;
  }

  test(
    'BIN Quick App metadata rejects a valid manifest without runtime',
    () async {
      final file = await writeBin({
        'manifest.json': '{"package":"com.example.quick"}',
      });

      await expectLater(
        InstallMetadataReader().read(InstallKind.quickApp, file.path),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'BIN Quick App metadata rejects runtime without a valid package name',
    () async {
      final file = await writeBin({
        'manifest.json': '{"name":"missing-package"}',
        'app.jsc': 'compiled runtime',
      });

      await expectLater(
        InstallMetadataReader().read(InstallKind.quickApp, file.path),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
