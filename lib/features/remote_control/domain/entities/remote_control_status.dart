import 'package:equatable/equatable.dart';

import 'remote_control_command.dart';

/// What became of the last command.
enum RemoteCommandOutcome {
  /// Handed to the channel; no acknowledgement yet.
  pending,

  /// The tablet reported the gesture completed, or Android accepted the global
  /// action, the text or the IME action.
  confirmed,

  accessibilityUnavailable,
  sessionNotActive,
  gestureRejected,
  textTargetUnavailable,
  textRejected,
  imeActionUnavailable,
  imeActionRejected,

  /// `touch_ended`: the remote contact was over before the touch was.
  touchEnded,

  /// `invalid_command`, `unsupported_command` or a code this version does not
  /// know: a programming error or a version mismatch, nothing the technician
  /// can act on.
  incompatible,

  /// No acknowledgement in time. The gesture may still have run, which is why
  /// a command is never sent again on its own.
  timedOut,

  /// The channel stopped being open before the acknowledgement arrived.
  channelClosed,

  /// The channel refused the message.
  notSent,
}

/// The last command, identified so that an acknowledgement can only ever speak
/// about the command it names.
final class RemoteCommandFeedback extends Equatable {
  const RemoteCommandFeedback({
    required this.commandId,
    required this.kind,
    required this.outcome,
  });

  final String commandId;

  /// Whether the technician should read about a touch, a stroke, Back, Home, a
  /// text or the IME action. Never the text itself: nothing here holds it.
  final RemoteCommandKind kind;

  final RemoteCommandOutcome outcome;

  @override
  List<Object?> get props => [commandId, kind, outcome];
}

/// Where the last touch session is, as far as the technician needs to know.
///
/// Nothing here says what the touch did on the tablet: an `ok` to the hold says
/// the finger is down past Android's long press timeout, an `ok` to the release
/// says the contact ended. What was picked up, moved or dropped is only on the
/// picture.
enum RemoteTouchPhase {
  /// `touch_hold` sent, not answered yet.
  holding,

  /// `touch_hold` answered ok, and nothing moved yet.
  held,

  /// Moves went out.
  dragging,

  /// `touch_release` sent, not answered yet.
  releasing,

  /// `touch_release` answered ok: the remote contact ended.
  released,

  /// `touch_cancel` sent, not answered yet.
  cancelling,

  /// Over without a release: cancelled here, or its channel went away.
  cancelled,

  /// Over because the tablet refused one of its messages: see
  /// [RemoteTouchFeedback.failure].
  failed,
}

/// The last touch session of the negotiation.
final class RemoteTouchFeedback extends Equatable {
  const RemoteTouchFeedback({
    required this.touchId,
    required this.phase,
    this.hasMoved = false,
    this.failure,
  });

  final String touchId;
  final RemoteTouchPhase phase;

  /// Whether more than keepalives went out: a drag rather than a press held.
  final bool hasMoved;

  /// Why it [RemoteTouchPhase.failed]. `null` otherwise.
  final RemoteCommandOutcome? failure;

  @override
  List<Object?> get props => [touchId, phase, hasMoved, failure];
}

/// The remote control side of a negotiation.
final class RemoteControlStatus extends Equatable {
  const RemoteControlStatus({
    this.isSessionActive = false,
    this.lastCommand,
    this.pendingCommands = 0,
    this.isSettling = false,
    this.isTextPending = false,
    this.isPictureDisplayed = false,
    this.isTouchActive = false,
    this.lastTouch,
  });

  /// REST says the session of this negotiation is `ACTIVE`, and it is not being
  /// closed. WebRTC alone never decides it.
  final bool isSessionActive;

  final RemoteCommandFeedback? lastCommand;

  /// Commands sent and not yet settled.
  final int pendingCommands;

  /// A global action, an IME action or a long press is unanswered, or answered and
  /// still within its settle time, and no new command of any kind is taken.
  final bool isSettling;

  /// A text is unanswered, and no new command of any kind is taken.
  final bool isTextPending;

  /// The surface says the renderer is really displaying the tablet's screen. A
  /// track exists long before that, for as long as the tablet waits for consent.
  final bool isPictureDisplayed;

  /// A touch session exists, from its hold to the answer that ends it. It is one
  /// interaction pending: nothing else is taken while it lasts, but FINALIZAR.
  final bool isTouchActive;

  /// The last touch session, when the last thing the technician did on the
  /// picture was one. Never set together with a gesture in [lastCommand]: the
  /// most recent of the two is the one reported.
  final RemoteTouchFeedback? lastTouch;

  @override
  List<Object?> get props => [
    isSessionActive,
    lastCommand,
    pendingCommands,
    isSettling,
    isTextPending,
    isPictureDisplayed,
    isTouchActive,
    lastTouch,
  ];
}
