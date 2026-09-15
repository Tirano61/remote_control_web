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
