library;

/// Stable machine-readable failure code exposed when one physical RFCOMM
/// generation has no safe SPP sequence number left.
const String sppSequenceSpaceExhaustedFailureCode =
    'rfcomm_rebuild_required';

/// Stable diagnostic event code for the same fail-closed condition.
const String sppSequenceSpaceExhaustedEventCode =
    'protocol.spp_sequence_exhausted';

/// Raised when the current physical RFCOMM connection has consumed every
/// eight-bit SPP sequence number. The caller must fail closed and establish a
/// new physical RFCOMM connection before sending another SPP data frame.
final class SppSequenceSpaceExhausted implements Exception {
  const SppSequenceSpaceExhausted({
    required this.requested,
    required this.available,
  });

  final int requested;
  final int available;

  String get userMessage =>
      'SPP 序号空间已耗尽，必须重建 RFCOMM 会话后重试。';

  @override
  String toString() =>
      'SppSequenceSpaceExhausted(requested=$requested, available=$available)';
}

/// Allocates the protocol's eight-bit SPP sequence space for one physical
/// RFCOMM connection. A sequence is permanently retired after it is sent; it
/// is never made available again merely because its ACK arrived or a timeout
/// elapsed. This is required because SPP ACK frames carry no connection
/// generation or epoch.
///
/// Create a fresh allocator only after the transport has completed a new
/// physical RFCOMM connect. The allocator deliberately has no reset method so
/// a logical backend epoch cannot accidentally make old sequence numbers
/// reusable on the same byte stream.
final class SppSequenceAllocator {
  SppSequenceAllocator({
    int initialSequence = 0,
    // Kept as source compatibility for early TUI callers. Quarantine timing
    // is no longer a safety boundary; retired numbers remain unavailable for
    // the whole physical RFCOMM generation.
    Duration? quarantineDuration,
    DateTime Function()? clock,
  }) : _next = initialSequence & 0xff;

  final Set<int> _used = <int>{};
  final Set<int> _active = <int>{};
  final Set<int> _acknowledged = <int>{};
  final Set<int> _quarantined = <int>{};
  int _next;

  /// Reserves one sequence atomically.
  int allocate() => reserve(1).single;

  /// Reserves [count] sequence numbers atomically before a frame/window is
  /// built. If the current generation cannot satisfy the whole request, no
  /// sequence is consumed and [SppSequenceSpaceExhausted] is thrown.
  List<int> reserve(int count) {
    if (count <= 0 || count > 256) {
      throw RangeError.range(count, 1, 256, 'count');
    }
    final candidates = <int>[];
    for (var offset = 0; offset < 256 && candidates.length < count; offset++) {
      final sequence = (_next + offset) & 0xff;
      if (!_used.contains(sequence)) candidates.add(sequence);
    }
    if (candidates.length != count) {
      throw SppSequenceSpaceExhausted(
        requested: count,
        available: 256 - _used.length,
      );
    }
    for (final sequence in candidates) {
      _used.add(sequence);
      _active.add(sequence);
    }
    _next = (candidates.last + 1) & 0xff;
    return List.unmodifiable(candidates);
  }

  bool isActive(int sequence) => _active.contains(sequence & 0xff);

  /// True when the number was already sent in this physical generation.
  bool isUsed(int sequence) => _used.contains(sequence & 0xff);

  /// True when the number was retired through an ambiguous outcome. This is
  /// diagnostic only; both acknowledged and quarantined values stay used.
  bool isQuarantined(int sequence) => _quarantined.contains(sequence & 0xff);

  /// True when an ACK was consumed for this generation. Tombstones persist
  /// until a new allocator is created and never permit sequence reuse.
  bool wasRecentlyAcknowledged(int sequence) =>
      _acknowledged.contains(sequence & 0xff);

  int get activeCount => _active.length;
  int get usedCount => _used.length;
  int get remainingCount => 256 - _used.length;
  int get quarantinedCount => _quarantined.length;

  /// Releases the pending wait, but not the sequence number itself.
  void acknowledge(int sequence) {
    final normalized = sequence & 0xff;
    _active.remove(normalized);
    if (_used.contains(normalized)) _acknowledged.add(normalized);
  }

  /// Retires an ambiguous pending frame permanently for this generation.
  void quarantine(int sequence) {
    final normalized = sequence & 0xff;
    _active.remove(normalized);
    if (_used.contains(normalized)) _quarantined.add(normalized);
  }
}
