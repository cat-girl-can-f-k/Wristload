import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wristload/domain/install_models.dart';
import 'package:wristload/domain/install_task.dart';
import 'package:wristload/domain/protocol/zau.dart';
import 'package:wristload/platform/security_scoped_file_access.dart';

void main() {
  const base = InstallCheckpoint(
    kind: InstallKind.watchface,
    path: '/tmp/dial.face',
    fileSize: 12,
    md5Hex: '0123456789abcdef0123456789abcdef',
    sha256Hex: '0000000000000000000000000000000000000000000000000000000000000000',
    dataType: MassDataType.watchface,
    lastAcknowledgedSegment: 0,
    phase: 'transferring',
  );

  test('checkpoint round-trips a bounded security-scoped bookmark', () {
    final source = InstallCheckpoint(
      kind: base.kind,
      path: base.path,
      fileSize: base.fileSize,
      md5Hex: base.md5Hex,
      sha256Hex: base.sha256Hex,
      dataType: base.dataType,
      lastAcknowledgedSegment: base.lastAcknowledgedSegment,
      phase: base.phase,
      bookmark: Uint8List.fromList([1, 2, 3]),
    );
    expect(InstallCheckpoint.fromJson(source.toJson())!.bookmark, [1, 2, 3]);
  });

  test('checkpoint rejects malformed or oversized bookmarks', () {
    expect(InstallCheckpoint.fromJson({...base.toJson(), 'bookmark': '!'}), isNull);
    final oversized = Uint8List(maxSecurityScopedBookmarkBytes + 1);
    final source = InstallCheckpoint(
      kind: base.kind, path: base.path, fileSize: base.fileSize,
      md5Hex: base.md5Hex, sha256Hex: base.sha256Hex, dataType: base.dataType,
      lastAcknowledgedSegment: base.lastAcknowledgedSegment, phase: base.phase,
      bookmark: oversized,
    );
    expect(InstallCheckpoint.fromJson(source.toJson()), isNull);
  });
}
