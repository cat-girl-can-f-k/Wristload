import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/domain/install_models.dart';
import 'package:wristload/domain/install_task.dart';
import 'package:wristload/domain/queue_file_importer.dart';

void main() {
  final metadata = InstallMetadata(
    fileName: 'fixture',
    fileSize: 1,
    md5Hex: '0' * 32,
    sha256Hex: '0' * 64,
  );

  test('recognizes watchfaces and quick apps by extension', () {
    expect(QueueFileImporter.kindForPath('watch.bin'), InstallKind.watchface);
    expect(QueueFileImporter.kindForPath('watch.FACE'), InstallKind.watchface);
    expect(QueueFileImporter.kindForPath('app.rpk'), InstallKind.quickApp);
    expect(QueueFileImporter.kindForPath('firmware.zip'), isNull);
  });

  test('filters existing, repeated and unsupported paths before enqueue',
      () async {
    final importer = QueueFileImporter(
      metadataLoader: (_, __) async => metadata,
    );

    final result = await importer.prepare(
      [
        r'C:\packages\exists.bin',
        r'C:\packages\watch.FACE',
        r'C:\packages\WATCH.face',
        r'C:\packages\app.rpk',
        r'C:\packages\unsupported.zip',
      ],
      existingPaths: [r'C:\packages\EXISTS.bin'],
    );

    expect(result.addedCount, 2);
    expect(result.requests.map((request) => request.kind), [
      InstallKind.watchface,
      InstallKind.quickApp,
    ]);
    expect(result.duplicateCount, 2);
    expect(result.unsupportedCount, 1);
    expect(result.failures, isEmpty);
  });

  test('reports metadata failures without losing valid requests', () async {
    final importer = QueueFileImporter(
      metadataLoader: (kind, path) async {
        if (path.endsWith('broken.bin')) {
          throw const FormatException('bad file');
        }
        return metadata;
      },
    );

    final result = await importer.prepare([
      r'C:\packages\broken.bin',
      r'C:\packages\valid.rpk',
    ]);

    expect(result.addedCount, 1);
    expect(result.failures, hasLength(1));
    expect(result.failures.single.error, isA<FormatException>());
  });
}
