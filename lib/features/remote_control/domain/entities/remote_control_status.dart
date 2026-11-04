import 'package:equatable/equatable.dart';

import 'remote_control_command.dart';

/// What became of the last command.
enum RemoteCommandOutcome {
  /// Handed to the channel; no acknowledgement yet.
  pending,

  /// The tablet reported the gesture completed, or Android accepted the global
  /// action or the text.
  confirmed,

  accessibilityUnavailable,
  sessionNotActive,
  gestureRejected,
  textTargetUnavailable,
  textRejected,

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

  /// Whether the technician should read about a touch, a stroke, Back, Home or a
  /// text. Never the text itself: nothing here holds it.
  final RemoteCommandKind kind;

  final RemoteCommandOutcome outcome;

  @override
  List<Object?> get props => [commandId, kind, outcome];
}

/// The remote control side of a negotiation.
final class RemoteControlStatus extends Equatable {
  const RemoteControlStatus({
    this.isSessionActive = false,
    this.lastCommand,
    this.pendingCommands = 0,
    this.isNavigationSettling = false,
    this.isTextPending = false,
    this.isPictureDisplayed = false,
  });

  /// REST says the session of this negotiation is `ACTIVE`, and it is not being
  /// closed. WebRTC alone never decides it.
  final bool isSessionActive;

  final RemoteCommandFeedback? lastCommand;

  /// Commands sent and not yet settled.
  final int pendingCommands;

  /// A Back or a Home is under way, and no new command of any kind is taken.
  final bool isNavigationSettling;

  /// A text is unanswered, and no new command of any kind is taken.
  final bool isTextPending;

  /// The surface says the renderer is really displaying the tablet's screen. A
  /// track exists long before that, for as long as the tablet waits for consent.
  final bool isPictureDisplayed;

  @override
  List<Object?> get props => [
    isSessionActive,
    lastCommand,
    pendingCommands,
    isNavigationSettling,
    isTextPending,
    isPictureDisplayed,
  ];
}
