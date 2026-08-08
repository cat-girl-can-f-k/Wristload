enum InstallKind { watchface, quickApp }
enum InstallStage { idle, validating, waitingForProtocol, transferring, awaitingDevice, succeeded, failed }

class InstallTask {
  const InstallTask({
    required this.kind,
    required this.fileName,
    required this.stage,
    required this.message,
  });

  final InstallKind kind;
  final String fileName;
  final InstallStage stage;
  final String message;
}
