import 'install_task.dart';

/// UI state published by the main engine to the floating install window.
enum FloatingInstallPhase { idle, installing, done, failed }

/// A transport-safe view of the shared connection and install queue state.
///
/// Keep this model free of Flutter and platform objects: desktop_multi_window
/// sends values through a method channel, so every field must be JSON-like.
class FloatingInstallSnapshot {
  const FloatingInstallSnapshot({
    required this.phase,
    required this.connected,
    required this.authenticated,
    required this.deviceName,
    this.kind,
    this.fileName,
    this.confirmedBytes = 0,
    this.totalBytes = 0,
    this.bytesPerSecond,
    this.queuePosition,
    this.queueLength = 0,
    this.message,
    this.canRetry = false,
  });

  const FloatingInstallSnapshot.idle({
    required bool connected,
    required bool authenticated,
    required String deviceName,
    int queueLength = 0,
  }) : this(
          phase: FloatingInstallPhase.idle,
          connected: connected,
          authenticated: authenticated,
          deviceName: deviceName,
          queueLength: queueLength,
        );

  final FloatingInstallPhase phase;
  final bool connected;
  final bool authenticated;
  final String deviceName;
  final InstallKind? kind;
  final String? fileName;
  final int confirmedBytes;
  final int totalBytes;
  final double? bytesPerSecond;

  /// One-based position of the displayed file in the full shared queue.
  final int? queuePosition;
  final int queueLength;
  final String? message;
  final bool canRetry;

  double get progress {
    if (totalBytes <= 0) return 0;
    return (confirmedBytes / totalBytes).clamp(0.0, 1.0);
  }

  Map<String, Object?> toJson() => {
        'phase': phase.name,
        'connected': connected,
        'authenticated': authenticated,
        'deviceName': deviceName,
        'kind': kind?.name,
        'fileName': fileName,
        'confirmedBytes': confirmedBytes,
        'totalBytes': totalBytes,
        'bytesPerSecond': bytesPerSecond,
        'queuePosition': queuePosition,
        'queueLength': queueLength,
        'message': message,
        'canRetry': canRetry,
      };

  factory FloatingInstallSnapshot.fromJson(Map<Object?, Object?> json) {
    final confirmedBytes = _nonNegativeInt(json['confirmedBytes']);
    final totalBytes = _nonNegativeInt(json['totalBytes']);
    final queueLength = _nonNegativeInt(json['queueLength']);
    final rawPosition = _nonNegativeInt(json['queuePosition']);
    final speed = json['bytesPerSecond'];

    return FloatingInstallSnapshot(
      phase: FloatingInstallPhase.values.byNameOr(
        json['phase'],
        FloatingInstallPhase.idle,
      ),
      connected: json['connected'] == true,
      authenticated: json['authenticated'] == true,
      deviceName:
          json['deviceName'] is String ? json['deviceName']! as String : '',
      kind: InstallKind.values.byNullableName(json['kind']),
      fileName: json['fileName'] as String?,
      confirmedBytes: confirmedBytes.clamp(0, totalBytes),
      totalBytes: totalBytes,
      bytesPerSecond: speed is num && speed.isFinite && speed >= 0
          ? speed.toDouble()
          : null,
      queuePosition:
          rawPosition > 0 && rawPosition <= queueLength ? rawPosition : null,
      queueLength: queueLength,
      message: json['message'] as String?,
      canRetry: json['canRetry'] == true,
    );
  }

  static int _nonNegativeInt(Object? value) {
    if (value is! num || !value.isFinite) return 0;
    return value.toInt().clamp(0, 0x7fffffffffffffff);
  }
}

extension _EnumNameLookup<T extends Enum> on Iterable<T> {
  T byNameOr(Object? name, T fallback) {
    if (name is! String) return fallback;
    for (final value in this) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  T? byNullableName(Object? name) {
    if (name is! String) return null;
    for (final value in this) {
      if (value.name == name) return value;
    }
    return null;
  }
}
