/// Persistent routing policy for a resource imported while more than one
/// authenticated device session is available. Device identifiers are opaque
/// CoreBluetooth identities, never Bluetooth addresses.
enum ResourceInstallTargetMode { allConnected, manual, automaticDevice }

class ResourceInstallTargetPolicy {
  const ResourceInstallTargetPolicy({
    // A dropped resource must never fan out to every connected watch unless
    // the user has explicitly chosen that behavior.
    this.mode = ResourceInstallTargetMode.manual,
    this.automaticDeviceId,
  });

  final ResourceInstallTargetMode mode;
  final String? automaticDeviceId;

  ResourceInstallTargetPolicy copyWith({
    ResourceInstallTargetMode? mode,
    String? automaticDeviceId,
    bool clearAutomaticDevice = false,
  }) => ResourceInstallTargetPolicy(
    mode: mode ?? this.mode,
    automaticDeviceId: clearAutomaticDevice
        ? null
        : automaticDeviceId ?? this.automaticDeviceId,
  );
}
