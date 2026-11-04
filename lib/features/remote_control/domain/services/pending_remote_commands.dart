import 'dart:async';

import 'package:equatable/equatable.dart';

import '../entities/remote_control_command.dart';

/// What is kept of a command while its acknowledgement is awaited: what it takes
/// to recognise the answer and to compute the deadlines of what follows.
///
/// Deliberately not the command. A text may hold a password, and it has no reason
/// to stay in memory for the seconds the answer can take.
final class PendingRemoteCommand extends Equatable {
  const PendingRemoteCommand({
    required this.commandId,
    required this.kind,
    required this.estimatedWork,
  });

  final String commandId;
  final RemoteCommandKind kind;
  final Duration estimatedWork;

  @override
  List<Object?> get props => [commandId, kind, estimatedWork];
}

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

  /// How long a command of [estimatedWork] may take to be answered, when [ahead]
  /// is the work of what was sent before it and is still unanswered.
  ///
  /// The tablet runs one gesture at a time, in the order they arrived, so a valid
  /// command may have to wait for all of them. A fixed wait would report as lost
  /// a swipe that is simply behind others.
  ///
  /// [margin] is what the channel and the tablet's own processing may take. It
  /// is also the minimum: the shortest command never gets less than that.
  static Duration deadlineFor(
    Duration estimatedWork, {
    required Iterable<Duration> ahead,
    required Duration margin,
  }) {
    final queued = ahead.fold(Duration.zero, (total, work) => total + work);
    final deadline = queued + estimatedWork + margin;
    return deadline > maxDeadline ? maxDeadline : deadline;
  }

  final Duration _margin;
  final Map<String, _TrackedRemoteCommand> _pending = {};

  int get length => _pending.length;

  /// What is waiting, oldest first.
  Iterable<PendingRemoteCommand> get commands =>
      _pending.values.map((tracked) => tracked.command);

  /// Takes what it needs from [command] and lets go of it. The deadline closes
  /// over the id alone, so a timer does not keep a text alive either.
  void track(
    RemoteControlCommand command, {
    required void Function(String commandId) onTimeout,
  }) {
    final commandId = command.id;
    final deadline = deadlineFor(
      command.estimatedWork,
      ahead: commands.map((pending) => pending.estimatedWork),
      margin: _margin,
    );
    _pending[commandId] = _TrackedRemoteCommand(
      command: PendingRemoteCommand(
        commandId: commandId,
        kind: command.kind,
        estimatedWork: command.estimatedWork,
      ),
      deadline: Timer(deadline, () => onTimeout(commandId)),
    );
  }

  /// Takes the command out of the map, or returns `null` when it is not waiting
  /// any more: an unknown id, a duplicate acknowledgement, a late one.
  PendingRemoteCommand? settle(String commandId) {
    final tracked = _pending.remove(commandId);
    tracked?.deadline.cancel();
    return tracked?.command;
  }

  void clear() {
    for (final tracked in _pending.values) {
      tracked.deadline.cancel();
    }
    _pending.clear();
  }
}

final class _TrackedRemoteCommand {
  const _TrackedRemoteCommand({required this.command, required this.deadline});

  final PendingRemoteCommand command;
  final Timer deadline;
}
