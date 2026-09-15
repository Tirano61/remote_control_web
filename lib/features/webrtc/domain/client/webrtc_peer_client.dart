import '../../../signaling/domain/entities/webrtc_ice_candidate.dart';
import '../../../signaling/domain/entities/webrtc_session_description.dart';
import '../entities/webrtc_ice_configuration.dart';
import '../entities/webrtc_peer_event.dart';

/// Port that hides WebRTC from the rest of the application.
///
/// Everything above the data layer talks to this interface only: no BLoC, no
/// widget and no domain object knows that `RTCPeerConnection`,
/// `RTCSessionDescription`, `RTCIceCandidate` or `RTCDataChannel` exist. The
/// only implementation that does is the `flutter_webrtc` adapter.
///
/// The models crossing this boundary are the ones signaling already defines —
/// `WebRtcOffer`, `WebRtcAnswer`, `WebRtcIceCandidate` — so a candidate
/// produced here can be relayed as it is, and one relayed to us can be applied
/// as it is. There is no second WebRTC model in the application.
abstract interface class WebRtcPeerClient {
  /// Builds a peer connection for exactly one negotiation of one remote
  /// session.
  ///
  /// A new negotiation always means a new [WebRtcPeerSession]: peer
  /// connections are never reused or reset in place, which is what makes a
  /// stale callback harmless.
  Future<WebRtcPeerSession> createSession({
    required String remoteSessionId,
    required WebRtcIceConfiguration configuration,
  });
}

/// One `RTCPeerConnection`, from creation to close.
///
/// The technician side is the **initial offerer** of this MVP, so the port
/// only needs to create an offer and consume an answer. `createAnswer` is
/// deliberately absent: a deterministic role is what keeps glare impossible
/// while the backend stays direction-neutral.
abstract interface class WebRtcPeerSession {
  /// The remote session this negotiation belongs to. Every candidate emitted
  /// by [events] is already addressed to it.
  String get remoteSessionId;

  /// Everything the peer connection reports. Broadcast, and closed by [close].
  Stream<WebRtcPeerEvent> get events;

  /// Creates the single `control` data channel of the session.
  ///
  /// It must be called before [createLocalOffer], because the channel is what
  /// puts the SCTP m-section into the SDP. The device never creates this
  /// channel: it receives it through `onDataChannel`.
  Future<void> openControlChannel();

  /// `createOffer()` followed by `setLocalDescription()`, in that order.
  ///
  /// The two are one operation on purpose: an offer that was not applied
  /// locally must never reach signaling, and no SDP is ever edited by hand —
  /// what WebRTC produced is what is returned.
  ///
  /// Local candidates start being gathered as soon as the local description is
  /// set, so they may reach [events] before the caller has relayed this offer.
  /// Holding them back until the relay is acknowledged is the caller's job.
  Future<WebRtcOffer> createLocalOffer();

  /// `setRemoteDescription()` with the answer relayed by the device.
  ///
  /// At most once per negotiation: a second answer is a protocol error and is
  /// dropped by the caller, not applied here.
  Future<void> applyRemoteAnswer(WebRtcAnswer answer);

  /// `addCandidate()` with a candidate relayed by the device.
  ///
  /// It is only valid after [applyRemoteAnswer] succeeded; candidates that
  /// arrive earlier are queued by the caller.
  Future<void> addRemoteIceCandidate(WebRtcIceCandidate candidate);

  /// Closes the data channel, the peer connection and [events].
  ///
  /// Idempotent: closing twice is not an error, because a negotiation can end
  /// from several directions at once (the assistance closed, ICE failed, the
  /// user signed out).
  Future<void> close();
}
