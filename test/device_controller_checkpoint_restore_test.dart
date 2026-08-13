import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/application/device_controller.dart';
import 'package:wristload/domain/install_checkpoint_store.dart';
import 'package:wristload/domain/install_metadata_reader.dart';
import 'package:wristload/domain/install_models.dart';
import 'package:wristload/domain/install_task.dart';
import 'package:wristload/domain/protocol/zau.dart';
import 'package:wristload/platform/ble_transport.dart';
import 'package:wristload/platform/security_scoped_file_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const scopeChannel = MethodChannel('wristload/security_scope');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(scopeChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('restores a verified checkpoint as state-unknown without transport activity',
      () async {
    const metadata = InstallMetadata(
      fileName: 'resolved.face',
      fileSize: 12,
      md5Hex: '0123456789abcdef0123456789abcdef',
      sha256Hex:
          '0000000000000000000000000000000000000000000000000000000000000000',
      faceId: '42',
    );
    final store = _CheckpointStore(
      InstallCheckpoint(
        kind: InstallKind.watchface,
        path: '/old/selection.face',
        fileSize: 12,
        md5Hex: '0123456789abcdef0123456789abcdef',
        sha256Hex:
            '0000000000000000000000000000000000000000000000000000000000000000',
        dataType: MassDataType.watchface,
        lastAcknowledgedSegment: 3,
        phase: 'transferring',
        bookmark: Uint8List.fromList([1]),
      ),
    );
    final scopeCalls = <String>[];
    messenger.setMockMethodCallHandler(scopeChannel, (call) async {
      scopeCalls.add(call.method);
      if (call.method == 'startAccess') {
        return <String, Object>{
          'started': true,
          'token': 'restore-lease',
          'path': '/resolved/selection.face',
          'bookmark': Uint8List.fromList([9, 8, 7]),
        };
      }
      return null;
    });
    final reader = _MetadataReader(metadata);
    final transport = _Transport();
    final controller = DeviceController(
      transport: transport,
      checkpointStore: store,
      metadataReader: reader,
    );
    addTearDown(controller.dispose);

    await controller.checkpointRestoreReady;

    expect(reader.calls, 1);
    expect(reader.paths, ['/resolved/selection.face']);
    expect(reader.bookmarks.single, [9, 8, 7]);
    expect(scopeCalls, ['startAccess', 'stopAccess']);
    expect(transport.calls, isEmpty);
    expect(controller.sessionReady, isFalse);
    expect(controller.sppConnecting, isFalse);
    expect(controller.installQueue, hasLength(1));
    final entry = controller.installQueue.single;
    expect(entry.stage, QueueStage.stateUnknown);
    expect(entry.request.path, '/resolved/selection.face');
    expect(entry.request.source?.path, '/resolved/selection.face');
    expect(entry.request.source?.bookmark, [9, 8, 7]);
    expect(store.saved, isNotNull);
    expect(store.saved!.path, '/resolved/selection.face');
    expect(store.saved!.bookmark, [9, 8, 7]);
    expect(store.saved!.dataType, MassDataType.watchface);
    expect(controller.logs.join('\n'), contains('未自动连接或发送数据'));
  });

  test('does not restore an unverified checkpoint', () async {
    final scopeCalls = <String>[];
    messenger.setMockMethodCallHandler(scopeChannel, (call) async {
      scopeCalls.add(call.method);
      if (call.method == 'startAccess') {
        return <String, Object>{
          'started': true,
          'token': 'mismatch-lease',
          'path': '/resolved/app.rpk',
        };
      }
      return null;
    });
    final checkpoint = InstallCheckpoint(
      kind: InstallKind.quickApp,
      path: '/old/app.rpk',
      fileSize: 1,
      md5Hex: '0123456789abcdef0123456789abcdef',
      sha256Hex:
          '0000000000000000000000000000000000000000000000000000000000000000',
      dataType: MassDataType.quickAppRpk,
      lastAcknowledgedSegment: 0,
      phase: 'transferring',
      bookmark: Uint8List.fromList([1]),
    );
    final store = _CheckpointStore(checkpoint);
    final controller = DeviceController(
      checkpointStore: store,
      metadataReader: _MetadataReader(const InstallMetadata(
        fileName: 'app.rpk',
        fileSize: 2,
        md5Hex: '0123456789abcdef0123456789abcdef',
        sha256Hex:
            '0000000000000000000000000000000000000000000000000000000000000000',
        packageName: 'com.example.app',
        versionCode: 1,
      )),
    );
    addTearDown(controller.dispose);

    await controller.checkpointRestoreReady;

    expect(controller.installQueue, isEmpty);
    expect(store.saved, isNull);
    expect(scopeCalls, ['startAccess', 'stopAccess']);
  });

  test('does not publish restored state after disposal and still closes its lease',
      () async {
    final scopeCalls = <String>[];
    messenger.setMockMethodCallHandler(scopeChannel, (call) async {
      scopeCalls.add(call.method);
      if (call.method == 'startAccess') {
        return <String, Object>{
          'started': true,
          'token': 'disposed-lease',
          'path': '/resolved/disposed.face',
          'bookmark': Uint8List.fromList([5]),
        };
      }
      return null;
    });
    const metadata = InstallMetadata(
      fileName: 'disposed.face',
      fileSize: 12,
      md5Hex: '0123456789abcdef0123456789abcdef',
      sha256Hex:
          '0000000000000000000000000000000000000000000000000000000000000000',
      faceId: '42',
    );
    final reader = _BlockingMetadataReader();
    final store = _CheckpointStore(
      InstallCheckpoint(
        kind: InstallKind.watchface,
        path: '/old/disposed.face',
        fileSize: metadata.fileSize,
        md5Hex: metadata.md5Hex,
        sha256Hex: metadata.sha256Hex,
        dataType: MassDataType.watchface,
        lastAcknowledgedSegment: 1,
        phase: 'transferring',
        bookmark: Uint8List.fromList([1]),
      ),
    );
    final controller = DeviceController(
      checkpointStore: store,
      metadataReader: reader,
    );

    await reader.started.future;
    controller.dispose();
    reader.result.complete(metadata);
    await controller.checkpointRestoreReady;

    expect(controller.installQueue, isEmpty);
    expect(store.saved, isNull);
    expect(scopeCalls, ['startAccess', 'stopAccess']);
  });

  test('refreshes a resolved checkpoint path when the bookmark is unchanged',
      () async {
    final temporaryDirectory =
        await Directory.systemTemp.createTemp('wristload-checkpoint-');
    addTearDown(() async {
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });
    final resolvedFile = File('${temporaryDirectory.path}/resolved.face');
    await resolvedFile.writeAsBytes(const [0x61, 0x62, 0x63], flush: true);

    final bookmark = Uint8List.fromList([1]);
    final checkpoint = InstallCheckpoint(
      kind: InstallKind.watchface,
      path: '/old/selection.face',
      fileSize: 3,
      md5Hex: '900150983cd24fb0d6963f7d28e17f72',
      sha256Hex:
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      dataType: MassDataType.watchface,
      lastAcknowledgedSegment: 2,
      phase: 'transferring',
      faceId: '42',
      bookmark: bookmark,
    );
    final store = _DeferredCheckpointStore(checkpoint);
    final scopeCalls = <String>[];
    messenger.setMockMethodCallHandler(scopeChannel, (call) async {
      scopeCalls.add(call.method);
      if (call.method == 'startAccess') {
        return <String, Object>{
          'started': true,
          'token': 'reconnect-lease',
          'path': resolvedFile.path,
          'bookmark': Uint8List.fromList(bookmark),
        };
      }
      return null;
    });
    final controller = DeviceController(checkpointStore: store);
    addTearDown(controller.dispose);
    await controller.checkpointRestoreReady;

    controller.enqueue(InstallRequest(
      kind: checkpoint.kind,
      path: checkpoint.path,
      metadata: const InstallMetadata(
        fileName: 'selection.face',
        fileSize: 3,
        md5Hex: '900150983cd24fb0d6963f7d28e17f72',
        sha256Hex:
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        faceId: '42',
      ),
      source: ScopedFileRef(path: checkpoint.path, bookmark: bookmark),
    ));
    controller.installQueue.single.stage = QueueStage.stateUnknown;

    await controller.reconnectAndCheckInstall();

    expect(store.saved, isNotNull);
    expect(store.saved!.path, resolvedFile.absolute.path);
    expect(store.saved!.bookmark, [1]);
    expect(scopeCalls, ['startAccess', 'stopAccess']);
    expect(controller.installQueue.single.request.path, resolvedFile.absolute.path);
    expect(
      controller.installQueue.single.request.source?.path,
      resolvedFile.absolute.path,
    );
    expect(controller.installQueue.single.request.source?.bookmark, [1]);
    expect(controller.logs.join('\n'), contains('检查点有效'));
  });
}

final class _CheckpointStore extends InstallCheckpointStore {
  _CheckpointStore(this.checkpoint);

  final InstallCheckpoint? checkpoint;
  InstallCheckpoint? saved;

  @override
  Future<InstallCheckpoint?> load() async => checkpoint;

  @override
  Future<void> save(InstallCheckpoint value) async {
    saved = value;
  }
}

final class _DeferredCheckpointStore extends InstallCheckpointStore {
  _DeferredCheckpointStore(this.checkpoint);

  InstallCheckpoint checkpoint;
  InstallCheckpoint? saved;
  int _loadCount = 0;

  @override
  Future<InstallCheckpoint?> load() async {
    _loadCount++;
    return _loadCount == 1 ? null : checkpoint;
  }

  @override
  Future<void> save(InstallCheckpoint value) async {
    saved = value;
    checkpoint = value;
  }
}

final class _MetadataReader extends InstallMetadataReader {
  _MetadataReader(this.metadata);

  final InstallMetadata metadata;
  int calls = 0;
  final List<String> paths = [];
  final List<Uint8List?> bookmarks = [];

  @override
  Future<InstallMetadata> readWithLease(
    InstallKind kind,
    SecurityScopedFileLease lease,
  ) async {
    calls++;
    paths.add(lease.file.path);
    bookmarks.add(lease.file.bookmark);
    return metadata;
  }
}

final class _BlockingMetadataReader extends InstallMetadataReader {
  final Completer<void> started = Completer<void>();
  final Completer<InstallMetadata> result = Completer<InstallMetadata>();

  @override
  Future<InstallMetadata> readWithLease(
    InstallKind kind,
    SecurityScopedFileLease lease,
  ) {
    started.complete();
    return result.future;
  }
}

final class _Transport extends BleTransport {
  final List<String> calls = [];

  @override
  Future<void> disposeRfcommStream() async {
    calls.add('dispose');
  }
}
