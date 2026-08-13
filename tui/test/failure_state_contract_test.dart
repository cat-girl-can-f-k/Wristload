import 'package:test/test.dart';
import 'package:wristload_tui/src/backend/backend_snapshot.dart';
import 'package:wristload_tui/src/domain/protocol/spp_sequence_allocator.dart';
import 'package:wristload_tui/src/frontend/port/tui_snapshot.dart';

void main() {
  test('sequence exhaustion identifiers remain stable', () {
    expect(
      sppSequenceSpaceExhaustedFailureCode,
      'rfcomm_rebuild_required',
    );
    expect(
      sppSequenceSpaceExhaustedEventCode,
      'protocol.spp_sequence_exhausted',
    );
  });

  test('sequence exhaustion failure code survives backend and TUI DTOs', () {
    const backend = BackendSnapshot(
      connection: BackendConnectionState.disconnected,
      queue: [],
      message: 'SPP 序号空间已耗尽，必须重建 RFCOMM 会话后重试。',
      failureCode: sppSequenceSpaceExhaustedFailureCode,
    );
    final connection = TuiConnectionInfo(
      state: TuiConnectionState.disconnected,
      failureMessage: backend.message,
      failureCode: backend.failureCode,
    );

    expect(backend.failureCode, sppSequenceSpaceExhaustedFailureCode);
    expect(connection.failureCode, sppSequenceSpaceExhaustedFailureCode);
    expect(connection.failureMessage, contains('重建 RFCOMM'));
  });
}
