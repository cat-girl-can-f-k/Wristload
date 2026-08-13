import 'dart:async';

/// Waits for every ACK in one Mass window. The timeout measures consecutive
/// inactivity, so each acknowledged frame renews the deadline.
Future<void> waitForMassAcknowledgements(
  Iterable<Future<void>> acknowledgements, {
  required Duration idleTimeout,
  required String Function(int acknowledged, int total) timeoutMessage,
}) {
  if (idleTimeout <= Duration.zero) {
    throw ArgumentError.value(idleTimeout, 'idleTimeout', '必须大于零');
  }
  final pending = acknowledgements.toList(growable: false);
  if (pending.isEmpty) return Future<void>.value();

  final completion = Completer<void>();
  Timer? timer;
  var acknowledged = 0;

  void armIdleTimeout() {
    timer?.cancel();
    timer = Timer(idleTimeout, () {
      if (!completion.isCompleted) {
        completion.completeError(TimeoutException(
          timeoutMessage(acknowledged, pending.length),
          idleTimeout,
        ));
      }
    });
  }

  armIdleTimeout();
  for (final acknowledgement in pending) {
    acknowledgement.then<void>((_) {
      if (completion.isCompleted) return;
      acknowledged++;
      if (acknowledged == pending.length) {
        timer?.cancel();
        completion.complete();
      } else {
        armIdleTimeout();
      }
    }, onError: (Object error, StackTrace stackTrace) {
      if (completion.isCompleted) return;
      timer?.cancel();
      completion.completeError(error, stackTrace);
    });
  }
  return completion.future.whenComplete(() => timer?.cancel());
}
