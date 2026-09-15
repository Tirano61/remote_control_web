import '../entities/remote_signaling_message.dart';
import '../entities/signaling_relay_result.dart';
import '../entities/webrtc_ice_candidate.dart';
import '../entities/webrtc_session_description.dart';

/// Everything the `RTCPeerConnection` layer needs from signaling.
///
/// It is deliberately the whole surface: an implementation of this port is
/// enough to negotiate a peer connection, and nothing above it needs to know
/// that Socket.IO, a namespace, a room, a handshake, an ACK or a
/// `TechnicianRealtimeBloc` exist.
///
/// The transport is shared: the implementation runs over the **single**
/// `/technicians` socket the console already has, the same one that carries
/// `remote-session:closed` and `remote-session:join`. There is no second
/// connection.
///
/// This stage transports signaling and nothing else. No SDP is applied, no
/// candidate is added, and the client takes no position on which side creates
/// the offer — the backend is direction-neutral and so is this port.
abstract interface class TechnicianSignalingClient {
  /// Relayed `webrtc:*` messages, already parsed and filtered.
  ///
  /// Only messages whose `remoteSessionId` equals [joinedRemoteSessionId] are
  /// published: a message for any other session is dropped, and its id is
  /// never adopted. Broadcast, so several consumers may listen.
  Stream<RemoteSignalingMessage> get incoming;

  /// Relays the backend refused, as they happen.
  ///
  /// The caller of `sendOffer`/`sendAnswer`/`sendIceCandidate` already gets the
  /// refusal in its result; this stream exists for the console rules that are
  /// not the sender's business — a lost room membership has to be joined
  /// again, and a session that stopped being available has to be re-read over
  /// REST.
  Stream<SignalingRelayRefused> get relayRefusals;

  /// Session whose signaling room this socket is in, or `null`.
  ///
  /// It is set by an accepted `remote-session:join` and lost with the
  /// connection, so it answers the only question that matters before sending:
  /// *may I relay for this session right now?*
  String? get joinedRemoteSessionId;

  /// Emits `webrtc:offer`.
  ///
  /// Nothing is sent unless the socket is joined to
  /// [WebRtcSessionDescription.remoteSessionId] and the payload satisfies the
  /// documented limits.
  Future<SignalingRelayResult> sendOffer(WebRtcOffer offer);

  /// Emits `webrtc:answer`. Same preconditions as [sendOffer].
  Future<SignalingRelayResult> sendAnswer(WebRtcAnswer answer);

  /// Emits `webrtc:ice-candidate`. Same preconditions as [sendOffer].
  Future<SignalingRelayResult> sendIceCandidate(WebRtcIceCandidate candidate);

  /// Releases the streams. The socket belongs to the realtime client and is
  /// not closed here.
  Future<void> dispose();
}
