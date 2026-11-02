import 'package:equatable/equatable.dart';

import '../../../remote_control/domain/entities/remote_control_ack.dart';
import '../../../signaling/domain/entities/webrtc_ice_candidate.dart';
import 'remote_video_track.dart';
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

/// The tablet answered a command on the `control` channel.
///
/// Already decoded: a frame that is not a valid acknowledgement never gets this
/// far, so no JSON and no channel message crosses this boundary.
final class RemoteControlAckReceived extends WebRtcPeerEvent {
  const RemoteControlAckReceived(this.ack);

  final RemoteControlAck ack;

  @override
  List<Object?> get props => [ack];

  @override
  String toString() => 'RemoteControlAckReceived(${ack.commandId})';
}

/// `onTrack` delivered a **video** track: the tablet is sending its screen.
///
/// Only video reaches this event. The negotiation declares one `recvonly`
/// video transceiver and nothing else, so an audio track — which nothing in
/// this application asks for — is dropped by the adapter instead of being
/// reported.
///
/// The track itself never leaves the data layer: what travels here is the
/// opaque [RemoteVideoTrack] handle.
///
/// It is **not** a connection state. A negotiation is connected when the peer
/// connection is connected and the `control` channel is open; whether a screen
/// is also arriving is a separate question — the tablet only sends one once
/// the user granted MediaProjection.
final class RemoteVideoTrackAvailable extends WebRtcPeerEvent {
  const RemoteVideoTrackAvailable(this.track);

  final RemoteVideoTrack track;

  @override
  List<Object?> get props => [track];

  /// The id only: no frame, no codec, no media of any kind.
  @override
  String toString() => 'RemoteVideoTrackAvailable(${track.id})';
}
