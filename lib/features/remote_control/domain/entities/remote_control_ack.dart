import 'package:equatable/equatable.dart';

/// Why the tablet refused a command, as its acknowledgement says.
enum RemoteControlError {
  /// The accessibility service is not connected on the tablet. The screen can
  /// still be shared: it only means gestures cannot run.
  accessibilityUnavailable('accessibility_unavailable'),

  /// No `ACTIVE` session on the tablet's side, or it ended while the command
  /// was queued.
  sessionNotActive('session_not_active'),

  /// Android cancelled or refused the gesture, or too many were queued.
  gestureRejected('gesture_rejected'),

  /// The tablet could not read the command: a bug on this side.
  invalidCommand('invalid_command'),

  /// The tablet does not know this command or protocol version.
  unsupportedCommand('unsupported_command'),

  /// A code this version does not know. The tablet did answer that the command
  /// failed, which is all that can be said about it.
  unknown('unknown');

  const RemoteControlError(this.code);

  /// One of the public codes of the protocol, so it is safe in the log.
  final String code;

  static RemoteControlError fromCode(String code) => values.firstWhere(
    (error) => error.code == code,
    orElse: () => unknown,
  );
}

/// The tablet's answer to one command.
///
/// `ok: true` means Android reported the gesture **completed**, not that it was
/// requested. A command may also never get an answer at all, so the sender keeps
/// its own timeout.
final class RemoteControlAck extends Equatable {
  const RemoteControlAck({required this.commandId, this.error});

  final String commandId;

  /// `null` when the command succeeded.
  final RemoteControlError? error;

  bool get isOk => error == null;

  @override
  List<Object?> get props => [commandId, error];
}
