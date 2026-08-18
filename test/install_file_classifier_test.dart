import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/domain/install_file_classifier.dart';
import 'package:wristload/domain/install_models.dart';
import 'package:wristload/domain/install_task.dart';
import 'package:wristload/domain/queue_file_importer.dart';
import 'package:wristload/platform/security_scoped_file_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const securityScopeChannel = MethodChannel('wristload/security_scope');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('install-classifier-');
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(securityScopeChannel, null);
    debugDefaultTargetPlatformOverride = null;
    if (directory.existsSync()) await directory.delete(recursive: true);
  });

  Future<File> writeZip(String name, Map<String, Object> entries) async {
    final archive = Archive();
    for (final item in entries.entries) {
      final bytes = switch (item.value) {
        String value => utf8.encode(value),
        List<int> value => value,
        _ => throw ArgumentError.value(item.value),
      };
      archive.addFile(ArchiveFile(item.key, bytes.length, bytes));
    }
    final file = File('${directory.path}/$name');
    await file.writeAsBytes(ZipEncoder().encode(archive)!);
    return file;
  }

  test('classifies manifest plus app.js as Quick App', () async {
    final file = await writeZip('quick-js.bin', {
      'pkg/manifest.json': '{}',
      'pkg/app.js': 'App({})',
    });
    expect(
      await const InstallFileClassifier().classifyResolvedPath(file.path),
      InstallableFileType.quickApp,
    );
  });

  test('classifies manifest plus app.jsc as Quick App', () async {
    final file = await writeZip('quick-jsc.bin', {
      'manifest.json': '{}',
      'dist/app.jsc': [1, 2, 3],
    });
    expect(
      await const InstallFileClassifier().classifyResolvedPath(file.path),
      InstallableFileType.quickApp,
    );
  });

  test('requires both manifest and runtime', () async {
    final manifest = await writeZip('manifest-only.bin', {
      'manifest.json': '{}',
    });
    final runtime = await writeZip('runtime-only.bin', {'app.js': 'App({})'});
    final classifier = const InstallFileClassifier();
    expect(
      await classifier.classifyResolvedPath(manifest.path),
      InstallableFileType.watchface,
    );
    expect(
      await classifier.classifyResolvedPath(runtime.path),
      InstallableFileType.watchface,
    );
  });

  test('ota.sh has firmware precedence and .zip requires it', () async {
    final firmwareBin = await writeZip('firmware.bin', {
      'ota.sh': 'dd if=/ota/system.bin of=/dev/system',
      'manifest.json': '{}',
      'app.js': 'App({})',
    });
    final firmwareZip = await writeZip('firmware.zip', {
      'release/ota.sh': 'echo ota',
    });
    final ordinaryZip = await writeZip('ordinary.zip', {'file.txt': 'x'});
    final classifier = const InstallFileClassifier();
    expect(
      await classifier.classifyResolvedPath(firmwareBin.path),
      InstallableFileType.firmware,
    );
    expect(
      await classifier.classifyResolvedPath(firmwareZip.path),
      InstallableFileType.firmware,
    );
    expect(
      await classifier.classifyResolvedPath(ordinaryZip.path),
      InstallableFileType.unsupported,
    );
  });

  test('applies content precedence to .face and .rpk archives', () async {
    final firmwareFace = await writeZip('firmware.face', {
      'ota.sh': 'echo update',
      'manifest.json': '{}',
      'app.js': 'App({})',
    });
    final quickAppFace = await writeZip('quick.face', {
      'manifest.json': '{}',
      'app.jsc': [1, 2, 3],
    });
    final firmwareRpk = await writeZip('firmware.rpk', {
      'release/ota.sh': 'echo update',
      'manifest.json': '{}',
      'app.js': 'App({})',
    });
    final classifier = const InstallFileClassifier();

    expect(
      await classifier.classifyResolvedPath(firmwareFace.path),
      InstallableFileType.firmware,
    );
    expect(
      await classifier.classifyResolvedPath(quickAppFace.path),
      InstallableFileType.quickApp,
    );
    expect(
      await classifier.classifyResolvedPath(firmwareRpk.path),
      InstallableFileType.firmware,
    );
  });

  test('keeps raw .bin and .face resources as watchfaces', () async {
    final rawBin = File('${directory.path}/raw.bin')
      ..writeAsBytesSync([1, 2, 3]);
    final rawFace = File('${directory.path}/raw.face')
      ..writeAsBytesSync([4, 5, 6]);
    final classifier = const InstallFileClassifier();

    expect(
      await classifier.classifyResolvedPath(rawBin.path),
      InstallableFileType.watchface,
    );
    expect(
      await classifier.classifyResolvedPath(rawFace.path),
      InstallableFileType.watchface,
    );
  });

  test('rejects unsafe archive paths and invalid zip files', () async {
    final unsafe = await writeZip('unsafe.bin', {
      '../manifest.json': '{}',
      'app.js': 'x',
    });
    final invalid = File('${directory.path}/invalid.zip')
      ..writeAsStringSync('not zip');
    final classifier = const InstallFileClassifier();
    expect(
      classifier.classifyResolvedPath(unsafe.path),
      throwsA(isA<FormatException>()),
    );
    expect(
      classifier.classifyResolvedPath(invalid.path),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'classification returns a refreshed macOS bookmark for later import',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final file = File('${directory.path}/watch.face');
      await file.writeAsBytes([1, 2, 3]);
      final usedBookmarks = <List<int>>[];
      var accessCount = 0;
      messenger.setMockMethodCallHandler(securityScopeChannel, (call) async {
        if (call.method == 'startAccess') {
          usedBookmarks.add(
            List<int>.from(
              (call.arguments as Map<Object?, Object?>)['bookmark']!
                  as List<int>,
            ),
          );
          accessCount++;
          return <String, Object>{
            'started': true,
            'token': 'lease-$accessCount',
            'path': file.path,
            'bookmark': Uint8List.fromList(accessCount == 1 ? [4, 5] : [6, 7]),
          };
        }
        return null;
      });

      final classified = await const InstallFileClassifier().classifySource(
        ScopedFileRef(path: file.path, bookmark: Uint8List.fromList([1, 2])),
      );
      final metadata = InstallMetadata(
        fileName: 'watch.face',
        fileSize: 3,
        md5Hex: '0' * 32,
        sha256Hex: '0' * 64,
      );
      final request = await QueueFileImporter(
        metadataLoader: (_, __) async => metadata,
      ).prepareSingle(classified.source, expectedKind: InstallKind.watchface);

      expect(classified.type, InstallableFileType.watchface);
      expect(usedBookmarks, [
        [1, 2],
        [4, 5],
      ]);
      expect(request.source?.bookmark, [6, 7]);
    },
  );
}
