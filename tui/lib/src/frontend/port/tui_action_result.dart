/// Result returned by every frontend action.
///
/// [code] is a stable, machine-readable reason string; UI must not parse
/// exception messages to infer failure categories. [message] is a safe,
/// user-facing Chinese explanation. [operationId] correlates asynchronous
/// operations and deduplicates rapid repeated submissions.
class TuiActionResult {
  const TuiActionResult({
    required this.accepted,
    required this.code,
    required this.message,
    this.operationId,
  });

  factory TuiActionResult.success(String message, {String? operationId}) =>
      TuiActionResult(
        accepted: true,
        code: 'ok',
        message: message,
        operationId: operationId,
      );

  factory TuiActionResult.failure(
    String code,
    String message, {
    String? operationId,
  }) =>
      TuiActionResult(
        accepted: false,
        code: code,
        message: message,
        operationId: operationId,
      );

  final bool accepted;
  final String code;
  final String message;
  final String? operationId;

  @override
  String toString() => 'TuiActionResult(accepted: $accepted, code: $code)';
}
