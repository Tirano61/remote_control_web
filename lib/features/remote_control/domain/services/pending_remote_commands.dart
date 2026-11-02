import 'dart:async';

import '../entities/remote_control_command.dart';

/// Commands sent and waiting for an acknowledgement, each with its own deadline.
///
/// A deadline only reports: it says which command ran out of time and leaves the
/// decision to the caller. Nothing here sends anything, so nothing here can
/// repeat a gesture.
class PendingRemoteCommands {
  PendingRemoteCommands({required Duration margin}) : _margin = margin;

  /// The longest any command waits. Enough for what the tablet can hold, one
  /// gesture running and 16 queued, all of them the longest swipe, plus a margin:
  /// `17 x 2 s + 3 s = 37 s`. Beyond that the tablet refuses instead of queuing,
  /// so a wait this long means the answer is not coming.
  static const Duration maxDeadline = Duration(seconds: 45);

  /// How long [command] may take to be answered, when [ahead] were sent before
  /// it and are still unanswered.
  ///
  /// The tablet runs one gesture at a time, in the order they arrived, so a valid
  /// command may have to wait for all of them. A fixed wait would report as lost
  /// a swipe that is simply behind others.
  ///
  /// [margin] is what the channel and the tablet's own processing may take. It
  /// is also the minimum: the shortest command never gets less than that.
  static Duration deadlineFor(
    RemoteControlCommand command, {
    required Iterable<RemoteControlCommand> ahead,
    required Duration margin,
  }) {
    final queued = ahead.fold(
      Duration.zero,
      (total, pending) => total + pending.estimatedWork,
    );
    final deadline = queued + command.estimatedWork + margin;
    return deadline > maxDeadline ? maxDeadline : deadline;
  }

  final Duration _margin;
  final Map<String, _PendingRemoteCommand> _pending = {};

  int get length => _pending.length;

  void track(
    RemoteControlCommand command, {
    required void Function(String commandId) onTimeout,
  }) {
    final deadline = deadlineFor(
      command,
      ahead: _pending.values.map((pending) => pending.command),
      margin: _margin,
    );
    _pending[command.id] = _PendingRemoteCommand(
      command: command,
      deadline: Timer(deadline, () => onTimeout(command.id)),
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
