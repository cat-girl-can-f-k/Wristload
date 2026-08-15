enum UiModal { authKey, installPath }

class UiNextState {
  String? selectedDeviceId;
  int scrollOffset = 0;
  bool detailOpen = false;
  UiModal? modal;
  String input = '';

  /// Prevent a cancelled prompt from reopening from the same waiting snapshot.
  /// It resets once the application leaves the pre-connect authkey state.
  bool authKeyPromptDismissed = false;

  void select(String? deviceId) {
    if (selectedDeviceId == deviceId) return;
    selectedDeviceId = deviceId;
    detailOpen = false;
  }
}
