enum ConnectionIssueKind {
  unexpectedDisconnect,
  connectionUnavailable,
  rfcommTimeout,
  authKeyMismatch,
}

class ConnectionIssue {
  const ConnectionIssue({required this.id, required this.kind});

  final int id;
  final ConnectionIssueKind kind;
}

/// Tracks user-facing connection notices independently from diagnostic logs.
///
/// Port-binding failures must be consecutive before they interrupt the user,
/// while an authenticated session can report an unexpected disconnect only
/// once until a new authentication succeeds.
class ConnectionIssueTracker {
  int _nextId = 1;
  int _authenticatedSession = 0;
  int? _unexpectedNoticeSession;
  int _consecutivePortConflicts = 0;
  bool _portConflictNoticeIssued = false;
  bool _authKeyMismatchNoticeIssued = false;
  String? _targetId;
  final List<ConnectionIssue> _pending = [];

  ConnectionIssue? get pending => _pending.firstOrNull;

  int get consecutivePortConflicts => _consecutivePortConflicts;

  void selectTarget(String targetId) {
    if (_targetId == targetId) return;
    _targetId = targetId;
    _resetConnectionFailures();
  }

  void authenticated() {
    _authenticatedSession++;
    _unexpectedNoticeSession = null;
    connectionSucceeded();
  }

  void connectionSucceeded() => _resetConnectionFailures();

  bool recordAuthKeyMismatch() {
    if (_authKeyMismatchNoticeIssued ||
        _pending.any((issue) => issue.kind == ConnectionIssueKind.authKeyMismatch)) {
      return false;
    }
    _authKeyMismatchNoticeIssued = true;
    _pending.add(ConnectionIssue(
      id: _nextId++,
      kind: ConnectionIssueKind.authKeyMismatch,
    ));
    return true;
  }

  bool recordConnectionFailure(Object error) {
    if (!isPortBindingConflict(error)) {
      _resetConnectionFailures();
      return false;
    }
    _consecutivePortConflicts++;
    if (_consecutivePortConflicts < 2 || _portConflictNoticeIssued) {
      return false;
    }
    _portConflictNoticeIssued = true;
    _pending.add(ConnectionIssue(
      id: _nextId++,
      kind: ConnectionIssueKind.connectionUnavailable,
    ));
    return true;
  }

  bool recordUnexpectedDisconnect() {
    if (_authenticatedSession == 0 ||
        _unexpectedNoticeSession == _authenticatedSession) {
      return false;
    }
    _unexpectedNoticeSession = _authenticatedSession;
    _pending.add(ConnectionIssue(
      id: _nextId++,
      kind: ConnectionIssueKind.unexpectedDisconnect,
    ));
    return true;
  }

  bool recordRfcommTimeout() {
    if (_pending.any((issue) => issue.kind == ConnectionIssueKind.rfcommTimeout)) {
      return false;
    }
    _pending.add(ConnectionIssue(
      id: _nextId++,
      kind: ConnectionIssueKind.rfcommTimeout,
    ));
    return true;
  }

  bool acknowledge(int id) {
    final removed = _pending.length;
    _pending.removeWhere((issue) => issue.id == id);
    return removed != _pending.length;
  }

  void reset() {
    _targetId = null;
    _authenticatedSession = 0;
    _unexpectedNoticeSession = null;
    _pending.clear();
    _resetConnectionFailures();
  }

  static bool isPortBindingConflict(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('只允许使用一次') ||
        text.contains('2147952448') ||
        text.contains('0x80072740');
  }

  void _resetConnectionFailures() {
    _consecutivePortConflicts = 0;
    _portConflictNoticeIssued = false;
    _authKeyMismatchNoticeIssued = false;
  }
}
