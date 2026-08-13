import '../port/tui_snapshot.dart';

/// Frontend-only view state. This never duplicates business facts from
/// [TuiSnapshot]; it only tracks navigation, focus, selection, and transient
/// UI state.
class AppState {
  AppState({this.currentView = View.devices});

  View currentView;

  /// Updated by the renderer so key mapping can expose the persistent log pane.
  bool wideLayout = false;

  // Global modal state
  ModalKind? modal;
  String dialogTitle = '确认';
  String dialogMessage = '';
  String dialogConfirmLabel = '确认';
  String dialogCancelLabel = '取消';
  bool dialogDangerous = false;
  bool dialogFocusConfirm = false;
  Future<void> Function()? onDialogConfirm;

  // Devices
  String? selectedDeviceId;
  bool showAddDevice = false;
  String manualAddress = '';
  String selectedModelId = '';
  String manualDisplayName = '';
  ManualDeviceField manualDeviceField = ManualDeviceField.address;

  // AuthKey
  bool showAuthKey = false;
  String authKeyInput = '';
  bool authKeyVisible = false;

  // Queue
  String? selectedQueueItemId;
  bool showImport = false;
  String importInput = '';
  bool showLogExport = false;
  String logExportPathInput = '';

  // Settings
  String segmentIntervalInput = '';
  String massWindowSizeInput = '';
  SettingsField settingsField = SettingsField.segmentInterval;

  String? activeDecisionId;
  int decisionFieldIndex = 0;
  bool decisionFocusConfirm = false;
  final Map<String, String> decisionValues = {};

  // Logs
  bool logsFollowTail = true;
  TuiLogLevel? logsFilter;
  TuiLogCategory? logsCategoryFilter;
  int logsScrollOffset = 0;

  // Help
  bool showHelp = false;

  // Busy operation tracking keyed by action name.
  final Set<String> _pendingActions = {};

  bool isActionPending(String action) => _pendingActions.contains(action);

  void markPending(String action) => _pendingActions.add(action);
  void clearPending(String action) => _pendingActions.remove(action);

  void clearDecision() {
    if (modal == ModalKind.decision) modal = null;
    activeDecisionId = null;
    decisionFieldIndex = 0;
    decisionFocusConfirm = false;
    decisionValues.clear();
  }

  void openConfirmation({
    required String title,
    required String message,
    required Future<void> Function() onConfirm,
    String confirmLabel = '确认',
    String cancelLabel = '取消',
    bool dangerous = false,
  }) {
    modal = ModalKind.confirm;
    dialogTitle = title;
    dialogMessage = message;
    dialogConfirmLabel = confirmLabel;
    dialogCancelLabel = cancelLabel;
    dialogDangerous = dangerous;
    // Destructive operations always open with Cancel focused.
    dialogFocusConfirm = false;
    onDialogConfirm = onConfirm;
  }

  /// Reset transient input when leaving a modal.
  void clearInputs() {
    modal = null;
    showAddDevice = false;
    manualAddress = '';
    selectedModelId = '';
    manualDisplayName = '';
    manualDeviceField = ManualDeviceField.address;
    showAuthKey = false;
    authKeyInput = '';
    authKeyVisible = false;
    showImport = false;
    importInput = '';
    showLogExport = false;
    logExportPathInput = '';
    clearDecision();
    dialogTitle = '确认';
    dialogMessage = '';
    dialogConfirmLabel = '确认';
    dialogCancelLabel = '取消';
    dialogDangerous = false;
    dialogFocusConfirm = false;
    onDialogConfirm = null;
  }
}

enum View { devices, queue, task, settings, logs }

enum ModalKind {
  confirm,
  authKey,
  addDevice,
  importFiles,
  decision,
  help,
}

enum ManualDeviceField { address, model, displayName }

enum SettingsField { segmentInterval, massWindowSize }
