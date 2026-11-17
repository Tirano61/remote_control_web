import 'package:equatable/equatable.dart';

/// Why the tablet refused a command, as its acknowledgement says.
enum RemoteControlError {
  /// The accessibility service is not connected on the tablet. The screen can
  /// still be shared: it only means commands cannot run.
  accessibilityUnavailable('accessibility_unavailable'),

  /// No `ACTIVE` session on the tablet's side, or it ended while the command
  /// was queued.
  sessionNotActive('session_not_active'),

  /// Android cancelled or refused the gesture or the global action, or too many
  /// were queued. The name is older than Back and Home, and stays.
  gestureRejected('gesture_rejected'),

  /// The tablet could not read the command: a bug on this side.
  invalidCommand('invalid_command'),

  /// The tablet does not know this command or protocol version.
  unsupportedCommand('unsupported_command'),

  /// A valid text or IME action with nowhere to go: no active window, nothing
  /// with input focus, or a focused node that is not editable or not enabled.
  textTargetUnavailable('text_target_unavailable'),

  /// There was somewhere to write, and `ACTION_SET_TEXT` did not take it.
  textRejected('text_rejected'),

  /// The focused field is there and editable, and declares no IME action.
  imeActionUnavailable('ime_action_unavailable'),

  /// The focused field declares an IME action, and Android did not run it.
  imeActionRejected('ime_action_rejected'),

  /// The touch a `touch_*` message names cannot go on, or does not exist: it was
  /// cancelled, timed out, saw the display change, was cancelled by Android, lost
  /// its session, or was never there. Why is in the tablet's log and nowhere else:
  /// the sender stops sending for that touch, whatever the reason.
  touchEnded('touch_ended'),

  /// A code this version does not know. The tablet did answer that the command
  /// failed, which is all that can be said about it.
  unknown('unknown');

  const RemoteControlError(this.code);

  /// One of the public codes of the protocol, so it is safe in the log.
  final String code;

  static RemoteControlError fromCode(String code) =>
      values.firstWhere((error) => error.code == code, orElse: () => unknown);
}

/// The tablet's answer to one command.
///
/// What `ok: true` promises depends on the command. For a tap or a swipe, Android
/// reported the gesture **completed**, not that it was requested. For Back or
/// Home, Android **accepted** the global action, which may still be animating and
/// may have had no visible effect at all. For a text, the focused node **accepted**
/// `ACTION_SET_TEXT`, and nothing says what the field ended up holding. For an IME
/// action, the focused node **accepted** `ACTION_IME_ENTER`: not that a search ran, a
/// form went or the screen changed. A command may
/// also never get an answer, so the sender keeps its own timeout.
final class RemoteControlAck extends Equatable {
  const RemoteControlAck({required this.commandId, this.error});

  final String commandId;

  /// `null` when the command succeeded.
  final RemoteControlError? error;

  bool get isOk => error == null;

  @override
  List<Object?> get props => [commandId, error];
}
