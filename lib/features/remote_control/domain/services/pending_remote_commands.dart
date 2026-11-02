import 'dart:async';

import '../entities/remote_control_command.dart';

/// Commands sent and waiting for an acknowledgement, each with its own deadline.
///
/// A deadline only reports: it says which command ran out of time and leaves the
/// decision to the caller. Nothing here sends anything, so nothing here can
/// repeat a gesture.
class PendingRemoteCommands {
  PendingRemoteCommands({required Duration timeout}) : _timeout = timeout;

  final Duration _timeout;
  final Map<String, _PendingRemoteCommand> _pending = {};

  int get length => _pending.length;

  void track(
    RemoteControlCommand command, {
    required void Function(String commandId) onTimeout,
  }) {
    _pending[command.id] = _PendingRemoteCommand(
      command: command,
      deadline: Timer(_timeout, () => onTimeout(command.id)),
    );
  }

  /// Takes the command out of the map, or returns `null` when it is not waiting
  /// any more: an unknown id, a duplicate acknowledgement, a late one.
  RemoteControlCommand? settle(String commandId) {
    final pending = _pending.remove(commandId);
    pending?.deadline.cancel();
    return pending?.command;
  }

  void clear() {
    for (final pending in _pending.values) {
      pending.deadline.cancel();
    }
    _pending.clear();
  }
}

final class _PendingRemoteCommand {
  const _PendingRemoteCommand({required this.command, required this.deadline});

  final RemoteControlCommand command;
  final Timer deadline;
}
