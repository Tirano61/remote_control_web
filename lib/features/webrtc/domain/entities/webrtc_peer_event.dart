import 'package:equatable/equatable.dart';

import '../../../signaling/domain/entities/webrtc_ice_candidate.dart';
import 'webrtc_connection_state.dart';

/// Something the peer connection reported, as a typed value.
///
/// This is the whole upward surface of the WebRTC port: whoever listens never
/// sees an `RTCPeerConnection`, an `RTCIceCandidate` or an `RTCDataChannel`.
sealed class WebRtcPeerEvent extends Equatable {
  const WebRtcPeerEvent();

  @override
  List<Object?> get props => const [];
}

/// `onIceCandidate`, already turned into the signaling model.
///
/// Nothing is filtered on the way out — host, srflx and relay candidates are
/// all forwarded exactly as WebRTC produced them, with their `sdpMid` and
/// `sdpMLineIndex`. Deciding *when* to relay one is the orchestrator's job.
final class LocalIceCandidateGathered extends WebRtcPeerEvent {
  const LocalIceCandidateGathered(this.candidate);

  final WebRtcIceCandidate candidate;

  @override
  List<Object?> get props => [candidate];

  /// Never the candidate line itself.
  @override
  String toString() =>
      'LocalIceCandidateGathered(length: ${candidate.candidateLength})';
}

/// `onConnectionState`.
final class PeerConnectionStateChanged extends WebRtcPeerEvent {
  const PeerConnectionStateChanged(this.state);

  final WebRtcPeerConnectionState state;

  @override
  List<Object?> get props => [state];

  @override
  String toString() => 'PeerConnectionStateChanged(${state.name})';
}

/// `onDataChannelState` of the `control` channel.
final class ControlChannelStateChanged extends WebRtcPeerEvent {
  const ControlChannelStateChanged(this.state);

  final WebRtcDataChannelState state;

  @override
  List<Object?> get props => [state];

  @override
  String toString() => 'ControlChannelStateChanged(${state.name})';
}

/// A message arrived on the `control` channel.
///
/// The channel exists but carries no protocol yet: this stage only proves that
/// SCTP works. Nothing consumes this event, and no command is ever sent.
final class ControlChannelMessageReceived extends WebRtcPeerEvent {
  const ControlChannelMessageReceived(this.text);

  final String text;

  @override
  List<Object?> get props => [text];

  /// The payload is never logged: no protocol is defined yet, so anything
  /// could be inside.
  @override
  String toString() =>
      'ControlChannelMessageReceived(length: ${text.length})';
}
