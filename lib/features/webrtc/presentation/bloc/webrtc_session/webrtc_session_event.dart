part of 'webrtc_session_bloc.dart';

sealed class WebRtcSessionEvent extends Equatable {
  const WebRtcSessionEvent();

  @override
  List<Object?> get props => const [];
}

/// Everything a negotiation needs is true: there is a live `RemoteSession`,
/// this socket is inside its signaling room, and the tablet is in it too.
///
/// The console raises it whenever that combination becomes true again — a
/// reconnection, a new assistance — and the BLoC decides whether it means a
/// new peer connection or nothing at all.
final class WebRtcNegotiationRequested extends WebRtcSessionEvent {
  const WebRtcNegotiationRequested(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The signaling room was lost: the socket dropped, the join expired, or the
/// backend refused a relay.
///
/// It does **not** mean the peer connection is dead. A connected one is kept:
/// WebRTC is peer to peer and does not need Socket.IO any more.
final class WebRtcSignalingLost extends WebRtcSessionEvent {
  const WebRtcSignalingLost();
}

/// The assistance is over: closed from here, closed by the tablet, or the user
/// signed out. Everything WebRTC holds is released.
final class WebRtcSessionTerminated extends WebRtcSessionEvent {
  const WebRtcSessionTerminated();
}

/// The technician clicked on the picture of the tablet.
///
/// Carries the session the picture belonged to, so that a click can never land
/// on a session other than the one it was aimed at.
final class WebRtcRemoteTapRequested extends WebRtcSessionEvent {
  const WebRtcRemoteTapRequested({
    required this.remoteSessionId,
    required this.point,
  });

  final String remoteSessionId;
  final NormalizedRemotePoint point;

  @override
  List<Object?> get props => [remoteSessionId, point];
}

/// The technician dragged across the picture of the tablet and let go.
///
/// Like a click, it carries the session the picture belonged to.
final class WebRtcRemoteSwipeRequested extends WebRtcSessionEvent {
  const WebRtcRemoteSwipeRequested({
    required this.remoteSessionId,
    required this.start,
    required this.end,
    required this.durationMs,
  });

  final String remoteSessionId;
  final NormalizedRemotePoint start;
  final NormalizedRemotePoint end;
  final int durationMs;

  @override
  List<Object?> get props => [remoteSessionId, start, end, durationMs];
}

/// The technician pressed Atrás.
///
/// Like a click, it carries the session it was aimed at. Unlike a click, it needs
/// no picture.
final class WebRtcRemoteBackRequested extends WebRtcSessionEvent {
  const WebRtcRemoteBackRequested({required this.remoteSessionId});

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The technician pressed Inicio. See [WebRtcRemoteBackRequested].
final class WebRtcRemoteHomeRequested extends WebRtcSessionEvent {
  const WebRtcRemoteHomeRequested({required this.remoteSessionId});

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// Which session REST currently says is `ACTIVE` and not being closed, if any.
///
/// The BLoC only learns this from outside: `RemoteSession` is not its state, and
/// WebRTC being connected says nothing about it.
final class WebRtcRemoteSessionActivityChanged extends WebRtcSessionEvent {
  const WebRtcRemoteSessionActivityChanged(this.activeRemoteSessionId);

  final String? activeRemoteSessionId;

  @override
  List<Object?> get props => [activeRemoteSessionId];
}

/// A command ran out of time. Internal.
final class _WebRtcRemoteCommandTimedOut extends WebRtcSessionEvent {
  const _WebRtcRemoteCommandTimedOut(this.commandId, this.generation);

  final String commandId;
  final int generation;

  @override
  List<Object?> get props => [commandId, generation];
}

/// The settle time of a Back or a Home has passed. Internal.
final class _WebRtcRemoteNavigationSettled extends WebRtcSessionEvent {
  const _WebRtcRemoteNavigationSettled(this.commandId, this.generation);

  final String commandId;
  final int generation;

  @override
  List<Object?> get props => [commandId, generation];
}

/// The peer connection reported something. Internal: only the BLoC raises it.
final class _WebRtcPeerReported extends WebRtcSessionEvent {
  const _WebRtcPeerReported(this.event, this.generation);

  final WebRtcPeerEvent event;

  /// The negotiation this callback belongs to. A late callback from a closed
  /// peer connection must never touch the current one.
  final int generation;

  @override
  List<Object?> get props => [event, generation];
}

/// A `webrtc:*` message was relayed to this technician. Internal.
final class _WebRtcSignalingReported extends WebRtcSessionEvent {
  const _WebRtcSignalingReported(this.message);

  final RemoteSignalingMessage message;

  @override
  List<Object?> get props => [message];
}
