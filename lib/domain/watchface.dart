/// A watchface reported by command=4/sub=0 on an authenticated device.
class WatchfaceItem {
  const WatchfaceItem({
    required this.id,
    required this.name,
    required this.isCurrent,
    required this.canRemove,
    required this.versionCode,
  });

  final String id;
  final String name;
  final bool isCurrent;
  final bool canRemove;
  final int versionCode;

  String get displayName => name.trim().isEmpty ? '表盘 $id' : name;
}
