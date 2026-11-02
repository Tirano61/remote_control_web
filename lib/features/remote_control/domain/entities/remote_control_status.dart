import 'package:equatable/equatable.dart';

/// What became of the last tap.
enum RemoteTapOutcome {
  /// Handed to the channel; no acknowledgement yet.
  pending,

  /// The tablet reported the gesture completed.
  confirmed,

  accessibilityUnavailable,
  sessionNotActive,
  gestureRejected,

  /// `invalid_command`, `unsupported_command` or a code this version does not
  /// know: a programming error or a version mismatch, nothing the technician
  /// can act on.
  incompatible,

  /// No acknowledgement in time. The gesture may still have run, which is why
  /// a tap is never sent again on its own.
  timedOut,

  /// The channel stopped being open before the acknowledgement arrived.
  channelClosed,

  /// The channel refused the message.
  notSent,
}

/// The last tap, identified so that an acknowledgement can only ever speak about
/// the command it names.
final class RemoteTapFeedback extends Equatable {
  const RemoteTapFeedback({required this.commandId, required this.outcome});

  final String commandId;
  final RemoteTapOutcome outcome;

  @override
  List<Object?> get props => [commandId, outcome];
}

/// The remote control side of a negotiation.
final class RemoteControlStatus extends Equatable {
  const RemoteControlStatus({
    this.isSessionActive = false,
    this.lastTap,
    this.pendingCommands = 0,
  });

  /// REST says the session of this negotiation is `ACTIVE`, and it is not being
  /// closed. WebRTC alone never decides it.
  final bool isSessionActive;

  final RemoteTapFeedback? lastTap;

  /// Commands sent and not yet settled.
  final int pendingCommands;

  @override
  List<Object?> get props => [isSessionActive, lastTap, pendingCommands];
}
