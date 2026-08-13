import '../state/app_state.dart';
import 'command.dart';
import 'key_event.dart';

/// Maps decoded [KeyEvent]s to [UiCommand]s based on current [AppState].
class KeyMapper {
  const KeyMapper();

  UiCommand? map(KeyEvent event, AppState state, bool textInputFocused) {
    if (event is PasteEvent) {
      if (textInputFocused) return TypeTextCommand(event.text);
      return null;
    }

    if (event is! KeyPress) return null;
    final key = event.name;

    if (state.modal == ModalKind.confirm) {
      if (key == 'esc' || key == 'n') return const CancelCommand();
      if (key == 'tab' || key == 'left' || key == 'right') {
        return const ToggleDialogFocusCommand();
      }
      // Enter executes the focused button. Destructive dialogs start with
      // Cancel focused; explicit y always confirms.
      if (key == 'y') return const ConfirmDialogCommand();
      if (key == 'enter') {
        return state.dialogFocusConfirm
            ? const ConfirmDialogCommand()
            : const CancelCommand();
      }
      return null;
    }

    if (state.activeDecisionId != null) {
      if (key == 'esc' || key == 'n')
        return DecisionCommand(state.activeDecisionId!, false, const {});
      if (key == 'left' || key == 'right') {
        return const ToggleDialogFocusCommand();
      }
      if (key == 'y' || (key == 'enter' && state.decisionFocusConfirm)) {
        return DecisionCommand(
          state.activeDecisionId!,
          true,
          Map<String, String>.from(state.decisionValues),
        );
      }
      if (key == 'enter') {
        return DecisionCommand(state.activeDecisionId!, false, const {});
      }
      if (key == 'tab' || key == 'shift-tab')
        return const CycleDecisionFieldCommand();
      if (key == 'backspace') return const BackspaceCommand();
      if (event.isPrintable) return TypeTextCommand(event.raw);
      return null;
    }

    // When a text input is focused, printable characters go to the input.
    if (textInputFocused) {
      if (key == 'esc') return const CancelCommand();
      if (state.showAuthKey && key == 'v')
        return const ToggleAuthKeyVisibilityCommand();
      if (state.showLogExport) {
        if (key == 'enter') return const SubmitLogExportCommand();
        if (key == 'backspace') return const BackspaceCommand();
        if (event.isPrintable) return TypeTextCommand(event.raw);
        return null;
      }
      if (key == 'tab' || key == 'shift-tab') {
        if (state.showAddDevice) return const CycleManualFieldCommand();
        if (state.currentView == View.settings)
          return const CycleSettingsFieldCommand();
      }
      if (state.showAddDevice &&
          state.manualDeviceField == ManualDeviceField.model) {
        if (key == 'up' || key == 'k')
          return const SelectManualModelCommand(-1);
        if (key == 'down' || key == 'j')
          return const SelectManualModelCommand(1);
      }
      if (key == 'enter') {
        if (state.showAuthKey) return const SubmitAuthKeyCommand();
        if (state.showImport) return const SubmitImportCommand();
        if (state.showAddDevice) return const AddManualDeviceCommand();
        if (state.currentView == View.settings)
          return const UpdateSettingsCommand();
        return const ActivateCommand();
      }
      if (key == 'backspace') return const BackspaceCommand();
      if (event.isPrintable) return TypeTextCommand(event.raw);
      return null;
    }

    // Global navigation.
    if (key == 'q') return const QuitCommand();
    if (key == '?' || key == 'f1') return const ToggleHelpCommand();
    if (key == 'esc') return const CancelCommand();

    // View switching.
    if (key == '1') return const NavigateCommand(0);
    if (key == '2') return const NavigateCommand(1);
    if (key == '3') return const NavigateCommand(2);
    if (key == '4') return const NavigateCommand(3);
    if (key == '5') return const NavigateCommand(4);

    // List navigation.
    if (key == 'down' || key == 'j') return const SelectNextCommand();
    if (key == 'up' || key == 'k') return const SelectPreviousCommand();
    if (key == 'home' || key == 'g') return const SelectFirstCommand();
    if (key == 'end' || key == 'G') return const SelectLastCommand();

    // The wide workbench keeps diagnostics visible on every page. Uppercase
    // keys avoid stealing queue l (move) and ordinary view actions.
    if (state.wideLayout) {
      if (key == 'F') return const CycleLogLevelFilterCommand();
      if (key == 'T') return const CycleLogCategoryFilterCommand();
      if (key == 'L') return const ToggleLogFollowCommand();
      if (key == '0') return const ResetLogFiltersCommand();
      if (key == '[' || key == 'page-up') {
        return const ScrollLogsCommand(-8);
      }
      if (key == ']' || key == 'page-down') {
        return const ScrollLogsCommand(8);
      }
    }

    // Actions.
    if (state.currentView == View.devices) {
      if (key == 'r') return const RefreshPairedCommand();
      if (key == 'R') return const StartStopScanCommand();
      if (key == 'm') {
        return const OpenManualDeviceCommand();
      }
      if (key == 'c') {
        return const ConnectCommand();
      }
      if (key == 'a') return const AuthKeyCommand();
      if (key == 'enter') return const ActivateCommand();
    }

    if (state.currentView == View.queue) {
      if (key == 'i') {
        return const ImportFilesCommand();
      }
      if (key == 's') return const StartQueueCommand();
      if (key == 'x') return const CancelInstallCommand();
      if (key == 'd') return const RemoveQueueItemCommand();
      if (key == 'left' || key == 'h') return const MoveQueueItemCommand(-1);
      if (key == 'right' || key == 'l') return const MoveQueueItemCommand(1);
      if (key == 'R') return const RetryQueueItemCommand();
      if (key == 'C') return const ClearCompletedQueueCommand();
      if (key == 'p') return const OpenPendingDecisionCommand();
      if (key == 'enter') return const ActivateCommand();
    }

    if (state.currentView == View.task) {
      if (key == 'x') return const CancelInstallCommand();
      if (key == 'c') return const InspectRecoveryCommand();
      if (key == 'r') return const ResumeRecoveryCommand();
      if (key == 'd') return const DiscardRecoveryCommand();
    }

    if (state.currentView == View.logs) {
      if (key == 'l') return const ToggleLogFollowCommand();
      if (key == 'e') return const ExportLogsCommand();
      if (key == 'f') return const CycleLogLevelFilterCommand();
      if (key == 't') return const CycleLogCategoryFilterCommand();
      if (key == '0') return const ResetLogFiltersCommand();
      if (key == 'page-up') return const ScrollLogsCommand(-8);
      if (key == 'page-down') return const ScrollLogsCommand(8);
    }

    if (state.currentView == View.settings && key == 'enter') {
      return const UpdateSettingsCommand();
    }

    return null;
  }

  /// True if any modal requiring text input is open.
  static bool isTextInputFocused(AppState state) {
    return state.showAuthKey ||
        state.showImport ||
        state.showLogExport ||
        state.showAddDevice ||
        state.activeDecisionId != null ||
        state.currentView == View.settings;
  }
}
