import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/domain/install_models.dart';
import 'package:wristload/domain/install_task.dart';
import 'package:wristload/domain/queue_file_importer.dart';
import 'package:wristload/platform/security_scoped_file_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('wristload/security_scope');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  final metadata = InstallMetadata(
    fileName: 'fixture',
    fileSize: 1,
    md5Hex: '0' * 32,
    sha256Hex: '0' * 64,
  );

  test('recognizes deterministic legacy file types without reading .bin', () {
    expect(QueueFileImporter.kindForPath('watch.bin'), InstallKind.watchface);
    expect(QueueFileImporter.kindForPath('watch.FACE'), InstallKind.watchface);
    expect(QueueFileImporter.kindForPath('app.rpk'), InstallKind.quickApp);
    expect(QueueFileImporter.kindForPath('firmware.zip'), isNull);
  });

  test(
    'filters existing, repeated and unsupported paths before enqueue',
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
    },
  );

  test(
    'non-macOS imports .bin as a watchface without content inspection',
    () async {
      final importer = QueueFileImporter(
        metadataLoader: (kind, _) async {
          expect(kind, InstallKind.watchface);
          return metadata;
        },
        classificationLoader: (_) async {
          fail('non-macOS .bin must not be content-classified');
        },
      );

      final result = await importer.prepare([r'C:\packages\watch.bin']);

      expect(result.addedCount, 1);
      expect(result.requests.single.kind, InstallKind.watchface);
      expect(result.failures, isEmpty);
    },
  );

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

  test('macOS rejects every supported source without a bookmark', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    var metadataReads = 0;
    final importer = QueueFileImporter(
      metadataLoader: (_, __) async {
        metadataReads++;
        return metadata;
      },
    );

    final result = await importer.prepare([
      '/tmp/plain.bin',
      const ScopedFileRef(path: '/tmp/ref.rpk'),
    ]);

    expect(result.addedCount, 0);
    expect(result.failures, hasLength(2));
    expect(
      result.failures.map((failure) => failure.error),
      everyElement(isA<StateError>()),
    );
    expect(metadataReads, 0);
  });

  test(
    'macOS counts an unknown extension without requesting file access',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return null;
      });

      final result = await QueueFileImporter().prepare([
        '/tmp/not-an-install.txt',
      ]);

      expect(result.addedCount, 0);
      expect(result.unsupportedCount, 1);
      expect(result.failures, isEmpty);
      expect(methods, isEmpty);
    },
  );

  test(
    'macOS checks a bookmarked file type after resolving its stale path',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'startAccess') {
          return <String, Object>{
            'started': true,
            'token': 'resolved-kind',
            'path': '/resolved/watchface.bin',
          };
        }
        return null;
      });
      final importer = QueueFileImporter(
        metadataLoader: (_, __) async => metadata,
      );

      final result = await importer.prepare([
        ScopedFileRef(
          path: '/stale/unknown.zip',
          bookmark: Uint8List.fromList([1]),
        ),
      ]);

      expect(result.addedCount, 1);
      expect(result.unsupportedCount, 0);
      expect(result.failures, isEmpty);
      expect(result.requests.single.kind, InstallKind.watchface);
      expect(result.requests.single.path, '/resolved/watchface.bin');
      expect(methods, ['startAccess', 'stopAccess']);
    },
  );

  test('macOS keeps a prepared request when scope cleanup fails', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startAccess') {
        return <String, Object>{
          'started': true,
          'token': 'cleanup-failure',
          'path': '/resolved/watchface.bin',
        };
      }
      throw PlatformException(code: 'stop_failed');
    });
    final importer = QueueFileImporter(
      metadataLoader: (_, __) async => metadata,
    );

    final result = await importer.prepare([
      ScopedFileRef(
        path: '/stale/watchface.bin',
        bookmark: Uint8List.fromList([1]),
      ),
    ]);

    expect(result.addedCount, 1);
    expect(result.failures, isEmpty);
  });

  test('macOS default importer reuses the resolved file lease', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final directory = await Directory.systemTemp.createTemp('queue-import-');
    addTearDown(() => directory.delete(recursive: true));
    final resolvedFile = File('${directory.path}/resolved.bin');
    await resolvedFile.writeAsBytes([1, 2, 3]);
    final methods = <String>[];
    var leaseNumber = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'startAccess') {
        leaseNumber++;
        return <String, Object>{
          'started': true,
          'token': 'lease-$leaseNumber',
          'path': resolvedFile.path,
          'bookmark': Uint8List.fromList([4, 5, 6]),
        };
      }
      return null;
    });

    final result = await QueueFileImporter().prepare([
      ScopedFileRef(
        path: '${directory.path}/stale.rpk',
        bookmark: Uint8List.fromList([1]),
      ),
      ScopedFileRef(
        path: '${directory.path}/renamed.face',
        bookmark: Uint8List.fromList([2]),
      ),
    ]);

    expect(result.addedCount, 1);
    expect(result.duplicateCount, 1);
    expect(result.unsupportedCount, 0);
    expect(result.failures, isEmpty);
    expect(result.requests.single.kind, InstallKind.watchface);
    expect(result.requests.single.path, resolvedFile.absolute.path);
    expect(result.requests.single.source?.path, resolvedFile.absolute.path);
    expect(result.requests.single.source?.bookmark, [4, 5, 6]);
    expect(methods, ['startAccess', 'stopAccess', 'startAccess', 'stopAccess']);
  });

  test(
    'macOS single-file request keeps the resolved path when queued',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final directory = await Directory.systemTemp.createTemp('home-import-');
      addTearDown(() => directory.delete(recursive: true));
      final resolvedFile = File('${directory.path}/resolved.face');
      await resolvedFile.writeAsBytes([1, 2, 3]);
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'startAccess') {
          return <String, Object>{
            'started': true,
            'token': 'home-lease',
            'path': resolvedFile.path,
            'bookmark': Uint8List.fromList([7, 8, 9]),
          };
        }
        return null;
      });

      final prepared = await QueueFileImporter().prepareSingle(
        ScopedFileRef(
          path: '${directory.path}/stale.face',
          bookmark: Uint8List.fromList([1, 2, 3]),
        ),
        expectedKind: InstallKind.watchface,
      );
      final queued = QueueEntry(
        request: prepared.copyWith(
          metadata: prepared.metadata.copyWith(faceId: '42'),
          watchfaceResolutionConfirmed: true,
        ),
      ).request;
      expect(queued.path, resolvedFile.absolute.path);
      expect(queued.source?.path, resolvedFile.absolute.path);
      expect(queued.source?.bookmark, [7, 8, 9]);
      expect(queued.metadata.faceId, '42');
      expect(queued.watchfaceResolutionConfirmed, isTrue);
      expect(methods, ['startAccess', 'stopAccess']);
    },
  );

  test(
    'single-file import rejects a resolved file of another install kind',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final directory = await Directory.systemTemp.createTemp('queue-kind-');
      addTearDown(() => directory.delete(recursive: true));
      final resolvedFile = File('${directory.path}/renamed.face');
      await resolvedFile.writeAsBytes([1, 2, 3]);
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'startAccess') {
          return <String, Object>{
            'started': true,
            'token': 'kind-lease',
            'path': resolvedFile.path,
          };
        }
        return null;
      });

      await expectLater(
        QueueFileImporter().prepareSingle(
          ScopedFileRef(
            path: '/selected/app.rpk',
            bookmark: Uint8List.fromList([1]),
          ),
          expectedKind: InstallKind.quickApp,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(methods, ['startAccess', 'stopAccess']);
    },
  );

  test('path normalization folds case only on Windows', () {
    expect(
      QueueFileImporter.normalizePath('/tmp/Watch.bin'),
      QueueFileImporter.normalizePath('/tmp/watch.bin'),
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(
      QueueFileImporter.normalizePath('/tmp/Watch.bin'),
      isNot(QueueFileImporter.normalizePath('/tmp/watch.bin')),
    );
  });
}
