import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/connection_issue.dart';

Future<void> showConnectionIssueWarning({
  required BuildContext context,
  required ConnectionIssue issue,
  required Future<void> Function() onReconnect,
}) =>
    switch (issue.kind) {
      ConnectionIssueKind.unexpectedDisconnect =>
        showUnexpectedDisconnectWarning(
          context: context,
          onReconnect: onReconnect,
        ),
      ConnectionIssueKind.connectionUnavailable =>
        showCannotConnectWarning(context: context),
    };

Future<void> showUnexpectedDisconnectWarning({
  required BuildContext context,
  required Future<void> Function() onReconnect,
}) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UnexpectedDisconnectDialog(onReconnect: onReconnect),
  );
}

Future<void> showCannotConnectWarning({required BuildContext context}) async {
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _CannotConnectDialog(),
  );
}

Widget _warningIcon(BuildContext context, IconData icon) {
  final scheme = Theme.of(context).colorScheme;
  return Container(
    width: 56,
    height: 56,
    decoration: BoxDecoration(
      color: scheme.errorContainer,
      shape: BoxShape.circle,
    ),
    child: Icon(icon, size: 28, color: scheme.error),
  );
}

class _UnexpectedDisconnectDialog extends StatefulWidget {
  const _UnexpectedDisconnectDialog({required this.onReconnect});

  final Future<void> Function() onReconnect;

  @override
  State<_UnexpectedDisconnectDialog> createState() =>
      _UnexpectedDisconnectDialogState();
}

class _UnexpectedDisconnectDialogState
    extends State<_UnexpectedDisconnectDialog> {
  bool _reconnecting = false;

  Future<void> _reconnect() async {
    if (_reconnecting) return;
    setState(() => _reconnecting = true);
    try {
      await widget.onReconnect();
      if (mounted) Navigator.of(context).pop();
    } on Object {
      if (mounted) setState(() => _reconnecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_reconnecting,
      child: AlertDialog(
        icon: _warningIcon(context, Icons.link_off),
        title: const Text('您的设备似乎意外断开了', textAlign: TextAlign.center),
        content: const Text(
          '请确认设备正常后，点击下方按钮关闭或重新连接。',
          textAlign: TextAlign.center,
        ),
        actions: [
          TextButton(
            onPressed: _reconnecting ? null : () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: _reconnecting ? null : _reconnect,
            child: _reconnecting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('重新连接'),
          ),
        ],
      ),
    );
  }
}

class _CannotConnectDialog extends StatefulWidget {
  const _CannotConnectDialog();

  @override
  State<_CannotConnectDialog> createState() => _CannotConnectDialogState();
}

class _CannotConnectDialogState extends State<_CannotConnectDialog> {
  Timer? _timer;
  int _secondsLeft = 3;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_secondsLeft <= 1) {
        _timer?.cancel();
        _timer = null;
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _close() {
    if (_secondsLeft != 0) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = _secondsLeft == 0;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape) {
          return KeyEventResult.ignored;
        }
        if (enabled) Navigator.of(context).pop();
        return KeyEventResult.handled;
      },
      child: PopScope(
        canPop: enabled,
        child: AlertDialog(
          icon: _warningIcon(context, Icons.bluetooth_disabled),
          title: const Text('您的设备无法被连接', textAlign: TextAlign.center),
          content: Text.rich(
            TextSpan(
              text: '请进入设备『',
              children: [
                TextSpan(
                  text: '连接新手机',
                  style: TextStyle(color: scheme.primary),
                ),
                const TextSpan(text: '』模式后，尝试重新连接。'),
              ],
            ),
            textAlign: TextAlign.center,
          ),
          actions: [
            FilledButton(
              onPressed: enabled ? _close : null,
              child: Text(enabled ? '关闭' : '关闭（$_secondsLeft）'),
            ),
          ],
        ),
      ),
    );
  }
}
