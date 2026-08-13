/// A user intent produced by keyboard input. Commands are dispatched to the
/// facade through a single gate that handles busy state and result handling.
sealed class UiCommand {
  const UiCommand();
}

class NavigateCommand extends UiCommand {
  const NavigateCommand(this.view);
  final int view; // 0-based index matching View enum
}

class SelectNextCommand extends UiCommand {
  const SelectNextCommand();
}

class SelectPreviousCommand extends UiCommand {
  const SelectPreviousCommand();
}

class SelectFirstCommand extends UiCommand {
  const SelectFirstCommand();
}

class SelectLastCommand extends UiCommand {
  const SelectLastCommand();
}

class ActivateCommand extends UiCommand {
  const ActivateCommand();
}

class CancelCommand extends UiCommand {
  const CancelCommand();
}

class QuitCommand extends UiCommand {
  const QuitCommand();
}

class RefreshPairedCommand extends UiCommand {
  const RefreshPairedCommand();
}

class StartStopScanCommand extends UiCommand {
  const StartStopScanCommand();
}

class AddManualDeviceCommand extends UiCommand {
  const AddManualDeviceCommand();
}

class OpenManualDeviceCommand extends UiCommand {
  const OpenManualDeviceCommand();
}

class CycleManualFieldCommand extends UiCommand {
  const CycleManualFieldCommand();
}

class SelectManualModelCommand extends UiCommand {
  const SelectManualModelCommand(this.delta);

  final int delta;
}

class ConnectCommand extends UiCommand {
  const ConnectCommand();
}

class DisconnectCommand extends UiCommand {
  const DisconnectCommand();
}

class AuthKeyCommand extends UiCommand {
  const AuthKeyCommand();
}

class SubmitAuthKeyCommand extends UiCommand {
  const SubmitAuthKeyCommand();
}

class ToggleAuthKeyVisibilityCommand extends UiCommand {
  const ToggleAuthKeyVisibilityCommand();
}

class ClearAuthKeyCommand extends UiCommand {
  const ClearAuthKeyCommand();
}

class ImportFilesCommand extends UiCommand {
  const ImportFilesCommand();
}

class SubmitImportCommand extends UiCommand {
  const SubmitImportCommand();
}

class RemoveQueueItemCommand extends UiCommand {
  const RemoveQueueItemCommand();
}

class ClearCompletedQueueCommand extends UiCommand {
  const ClearCompletedQueueCommand();
}

class MoveQueueItemCommand extends UiCommand {
  const MoveQueueItemCommand(this.delta);
  final int delta;
}

class StartQueueCommand extends UiCommand {
  const StartQueueCommand({this.confirmed = false});
  final bool confirmed;
}

class RetryQueueItemCommand extends UiCommand {
  const RetryQueueItemCommand();
}

class CancelInstallCommand extends UiCommand {
  const CancelInstallCommand({this.confirmed = false});
  final bool confirmed;
}

class InspectRecoveryCommand extends UiCommand {
  const InspectRecoveryCommand();
}

class ResumeRecoveryCommand extends UiCommand {
  const ResumeRecoveryCommand();
}

class DiscardRecoveryCommand extends UiCommand {
  const DiscardRecoveryCommand({this.confirmed = false});
  final bool confirmed;
}

class UpdateSettingsCommand extends UiCommand {
  const UpdateSettingsCommand();
}

class CycleSettingsFieldCommand extends UiCommand {
  const CycleSettingsFieldCommand();
}

class ExportLogsCommand extends UiCommand {
  const ExportLogsCommand();
}

class SubmitLogExportCommand extends UiCommand {
  const SubmitLogExportCommand();
}

class ToggleHelpCommand extends UiCommand {
  const ToggleHelpCommand();
}

class ToggleLogFollowCommand extends UiCommand {
  const ToggleLogFollowCommand();
}

class CycleLogLevelFilterCommand extends UiCommand {
  const CycleLogLevelFilterCommand();
}

class CycleLogCategoryFilterCommand extends UiCommand {
  const CycleLogCategoryFilterCommand();
}

class ResetLogFiltersCommand extends UiCommand {
  const ResetLogFiltersCommand();
}

class ScrollLogsCommand extends UiCommand {
  const ScrollLogsCommand(this.delta);
  final int delta;
}

class OpenPendingDecisionCommand extends UiCommand {
  const OpenPendingDecisionCommand();
}

class CycleDecisionFieldCommand extends UiCommand {
  const CycleDecisionFieldCommand();
}

class ConfirmDialogCommand extends UiCommand {
  const ConfirmDialogCommand();
}

class ToggleDialogFocusCommand extends UiCommand {
  const ToggleDialogFocusCommand();
}

class TypeTextCommand extends UiCommand {
  const TypeTextCommand(this.text);
  final String text;
}

class BackspaceCommand extends UiCommand {
  const BackspaceCommand();
}

class DecisionCommand extends UiCommand {
  const DecisionCommand(this.decisionId, this.accepted, this.values);
  final String decisionId;
  final bool accepted;
  final Map<String, String> values;
}
