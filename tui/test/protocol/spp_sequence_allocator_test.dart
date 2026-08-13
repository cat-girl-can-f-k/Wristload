import 'package:test/test.dart';
import 'package:wristload_tui/src/domain/protocol/spp_sequence_allocator.dart';

void main() {
  group('SppSequenceAllocator', () {
    test('allocates the eight-bit space once and then fails closed', () {
      final allocator = SppSequenceAllocator();

      final values = <int>[
        for (var i = 0; i < 256; i++) allocator.allocate(),
      ];

      expect(values, List<int>.generate(256, (index) => index));
      expect(allocator.usedCount, 256);
      expect(allocator.remainingCount, 0);
      expect(
        () => allocator.allocate(),
        throwsA(
          isA<SppSequenceSpaceExhausted>()
              .having((error) => error.requested, 'requested', 1)
              .having((error) => error.available, 'available', 0),
        ),
      );
    });

    test('does not reuse an acknowledged or quarantined sequence', () {
      final allocator = SppSequenceAllocator(initialSequence: 255);
      final first = allocator.allocate();
      final second = allocator.allocate();
      expect([first, second], [255, 0]);

      allocator.acknowledge(first);
      allocator.quarantine(second);
      final next = allocator.reserve(2);
      expect(next, [1, 2]);
      expect(allocator.isUsed(first), isTrue);
      expect(allocator.isUsed(second), isTrue);
      expect(allocator.wasRecentlyAcknowledged(first), isTrue);
      expect(allocator.isQuarantined(second), isTrue);
    });

    test('reserve is atomic when a whole Mass window does not fit', () {
      final allocator = SppSequenceAllocator();
      allocator.reserve(255);
      final before = allocator.usedCount;

      expect(
        () => allocator.reserve(2),
        throwsA(isA<SppSequenceSpaceExhausted>()),
      );
      expect(allocator.usedCount, before);
      expect(allocator.remainingCount, 1);
      expect(allocator.allocate(), 255);
    });

    test('a new allocator is the only reset boundary', () {
      final oldGeneration = SppSequenceAllocator();
      oldGeneration.reserve(256);
      expect(() => oldGeneration.allocate(),
          throwsA(isA<SppSequenceSpaceExhausted>()));

      final newGeneration = SppSequenceAllocator();
      expect(newGeneration.allocate(), 0);
    });
  });
}
