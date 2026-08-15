/// Stable, non-secret record for a saved classic-Bluetooth TUI device.
library;

/// A saved device is identified only by its normalized Bluetooth MAC address.
///
/// The model deliberately does not contain an authkey. Keys are kept in the
/// credential store rather than in device JSON.
class SavedTuiDevice {
  SavedTuiDevice({
    required String displayName,
    required String macAddress,
    required this.isSupported,
    String? profileId,
    this.lastConnectedAt,
  })  : displayName = _requireDisplayName(displayName),
        macAddress = normalizeMacAddress(macAddress),
        profileId = _normalizeProfileId(profileId);

  final String displayName;
  final String macAddress;
  final bool isSupported;

  /// Stable identifier for the profile selected when this device was saved.
  ///
  /// It is deliberately optional for records written by older TUI builds. A
  /// saved profile is preferred over a later advertisement match so scan data
  /// cannot silently change the connection protocol selected for a device.
  final String? profileId;
  final DateTime? lastConnectedAt;

  /// Normalizes conventional colon- or hyphen-separated MAC forms to the
  /// canonical stable identity used by repositories and credential accounts.
  static String normalizeMacAddress(String value) {
    final compact = value.trim().replaceAll(RegExp(r'[:-]'), '');
    if (!RegExp(r'^[0-9A-Fa-f]{12}$').hasMatch(compact)) {
      throw const FormatException(
          'Bluetooth MAC address must contain 12 hexadecimal digits.');
    }
    final upper = compact.toUpperCase();
    return List<String>.generate(
      6,
      (index) => upper.substring(index * 2, (index + 1) * 2),
    ).join(':');
  }

  static String _requireDisplayName(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw const FormatException('Device display name must not be empty.');
    }
    return normalized;
  }

  static String? _normalizeProfileId(String? value) {
    if (value == null) return null;
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw const FormatException('Saved device profile id must not be empty.');
    }
    return normalized;
  }

  SavedTuiDevice copyWith({
    String? displayName,
    String? macAddress,
    bool? isSupported,
    String? profileId,
    bool clearProfileId = false,
    DateTime? lastConnectedAt,
    bool clearLastConnectedAt = false,
  }) {
    return SavedTuiDevice(
      displayName: displayName ?? this.displayName,
      macAddress: macAddress ?? this.macAddress,
      isSupported: isSupported ?? this.isSupported,
      profileId: clearProfileId ? null : (profileId ?? this.profileId),
      lastConnectedAt: clearLastConnectedAt
          ? null
          : (lastConnectedAt ?? this.lastConnectedAt),
    );
  }

  Map<String, Object?> toJson() => {
        'displayName': displayName,
        'macAddress': macAddress,
        'isSupported': isSupported,
        if (profileId != null) 'profileId': profileId,
        if (lastConnectedAt != null)
          'lastConnectedAt': lastConnectedAt!.toUtc().toIso8601String(),
      };

  factory SavedTuiDevice.fromJson(Map<String, Object?> json) {
    final rawName = json['displayName'];
    final rawAddress = json['macAddress'];
    final rawSupported = json['isSupported'];
    if (rawName is! String || rawAddress is! String || rawSupported is! bool) {
      throw const FormatException('Saved TUI device JSON is incomplete.');
    }
    final rawProfileId = json['profileId'];
    if (rawProfileId != null && rawProfileId is! String) {
      throw const FormatException('Saved TUI device profile id is invalid.');
    }

    final rawLastConnected = json['lastConnectedAt'];
    DateTime? lastConnectedAt;
    if (rawLastConnected != null) {
      if (rawLastConnected is! String) {
        throw const FormatException('Saved TUI device timestamp is invalid.');
      }
      lastConnectedAt = DateTime.tryParse(rawLastConnected)?.toUtc();
      if (lastConnectedAt == null) {
        throw const FormatException('Saved TUI device timestamp is invalid.');
      }
    }

    return SavedTuiDevice(
      displayName: rawName,
      macAddress: rawAddress,
      isSupported: rawSupported,
      profileId: rawProfileId as String?,
      lastConnectedAt: lastConnectedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is SavedTuiDevice &&
        other.displayName == displayName &&
        other.macAddress == macAddress &&
        other.isSupported == isSupported &&
        other.profileId == profileId &&
        other.lastConnectedAt == lastConnectedAt;
  }

  @override
  int get hashCode => Object.hash(
        displayName,
        macAddress,
        isSupported,
        profileId,
        lastConnectedAt,
      );
}
