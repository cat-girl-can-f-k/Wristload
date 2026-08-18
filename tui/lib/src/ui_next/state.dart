enum UiModal { authKey, installPath }

/// The frontend surface that currently owns directional keyboard input.
///
/// This is intentionally UI-only state: it never represents Bluetooth,
/// protocol, installation, or authentication progress.
enum UiFocusTarget {
  deviceBrowser,
  inspector,
  activity,
  install,
  commandBar,
}

/// A compact, safe-to-render event derived from an application snapshot or a
/// user action result. It is not a diagnostic packet log.
final class UiActivityEntry {
  const UiActivityEntry({
    required this.category,
    required this.message,
    this.isError = false,
  });

  final String category;
  final String message;
  final bool isError;
}

class UiNextState {
  String? selectedDeviceId;
  int scrollOffset = 0;

  /// The dashboard keeps an inspector visible at normal sizes. This opens the
  /// scrollable, inspector-only fallback for small terminals or explicit
  /// detail inspection.
  bool detailOpen = false;

  /// Keyboard and mouse both update this authoritative UI focus. Device
  /// identity remains the normalized MAC address, never a transient row index.
  UiFocusTarget focus = UiFocusTarget.deviceBrowser;

  /// The enum name of the action focused in the currently rendered command
  /// bar. A string avoids coupling this state model to layout.dart.
  String? focusedActionName;

  /// Zero-based command-bar page for terminals that cannot show every
  /// context action at once. This is presentation state only.
  int commandPage = 0;

  final List<UiActivityEntry> _recentActivity = <UiActivityEntry>[];
  UiModal? modal;

  /// Stable identity captured when an input modal opens.
  ///
  /// The authkey prompt must submit to the connection target that caused the
  /// prompt, even if a later snapshot changes the device list.
  String? modalTargetDeviceId;

  /// Connection attempt captured with [modalTargetDeviceId].
  int? modalTargetConnectionGeneration;
  String input = '';

  /// A local cancellation suppresses only the exact application attempt that
  /// created the prompt. A later target or generation must open normally.
  String? _dismissedAuthKeyTargetDeviceId;
  int? _dismissedAuthKeyConnectionGeneration;

  /// Authkey input owns selection until it is submitted or cancelled.
  bool get selectionLocked =>
      modal == UiModal.authKey && modalTargetDeviceId != null;

  bool get commandBarFocused => focus == UiFocusTarget.commandBar;

  List<UiActivityEntry> get recentActivity =>
      List<UiActivityEntry>.unmodifiable(_recentActivity);

  void focusRegion(UiFocusTarget value) {
    focus = value;
    if (value != UiFocusTarget.commandBar) {
      focusedActionName = null;
      commandPage = 0;
    }
  }

  void focusCommandBar([String? actionName]) {
    focus = UiFocusTarget.commandBar;
    focusedActionName = actionName;
  }

  void setCommandPage(int value) {
    commandPage = value < 0 ? 0 : value;
  }

  void clearCommandBarFocus() {
    focusedActionName = null;
    commandPage = 0;
    if (focus == UiFocusTarget.commandBar) {
      focus = UiFocusTarget.deviceBrowser;
    }
  }

  void recordActivity({
    required String category,
    required String message,
    bool isError = false,
  }) {
    final normalizedCategory = category.trim();
    final normalizedMessage = message.trim();
    if (normalizedCategory.isEmpty || normalizedMessage.isEmpty) return;
    final previous = _recentActivity.isEmpty ? null : _recentActivity.first;
    if (previous != null &&
        previous.category == normalizedCategory &&
        previous.message == normalizedMessage &&
        previous.isError == isError) {
      return;
    }
    _recentActivity.insert(
      0,
      UiActivityEntry(
        category: normalizedCategory,
        message: normalizedMessage,
        isError: isError,
      ),
    );
    if (_recentActivity.length > 6)
      _recentActivity.removeRange(6, _recentActivity.length);
  }

  void openModal(
    UiModal value, {
    String? targetDeviceId,
    int? targetConnectionGeneration,
  }) {
    clearCommandBarFocus();
    modal = value;
    modalTargetDeviceId = targetDeviceId;
    modalTargetConnectionGeneration = targetConnectionGeneration;
    input = '';
  }

  void closeModal() {
    modal = null;
    modalTargetDeviceId = null;
    modalTargetConnectionGeneration = null;
    input = '';
  }

  bool isAuthKeyPromptDismissedFor(
    String targetDeviceId,
    int connectionGeneration,
  ) {
    return _dismissedAuthKeyTargetDeviceId == targetDeviceId &&
        _dismissedAuthKeyConnectionGeneration == connectionGeneration;
  }

  void dismissAuthKeyPromptFor(
    String targetDeviceId,
    int connectionGeneration,
  ) {
    _dismissedAuthKeyTargetDeviceId = targetDeviceId;
    _dismissedAuthKeyConnectionGeneration = connectionGeneration;
  }

  void clearAuthKeyPromptDismissal() {
    _dismissedAuthKeyTargetDeviceId = null;
    _dismissedAuthKeyConnectionGeneration = null;
  }

  void select(String? deviceId) {
    if (selectionLocked && deviceId != modalTargetDeviceId) return;
    if (selectedDeviceId == deviceId) return;
    selectedDeviceId = deviceId;
    detailOpen = false;
    commandPage = 0;
  }
}
