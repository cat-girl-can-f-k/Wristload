import 'dart:typed_data';

/// A quick app reported by command=20/sub=0.
class WatchAppItem {
  const WatchAppItem({
    required this.packageName,
    required this.fingerprint,
    required this.versionCode,
    required this.canRemove,
    required this.appName,
  });

  final String packageName;
  final Uint8List fingerprint;
  final int versionCode;
  final bool canRemove;
  final String appName;

  String get displayName => appName.trim().isEmpty ? packageName : appName;
}
