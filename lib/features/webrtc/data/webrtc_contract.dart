import '../domain/entities/webrtc_ice_configuration.dart';

/// The WebRTC choices this application makes, in one place.
///
/// They are not a backend contract — `docs/backend/REALTIME.md` only relays
/// SDP and ICE and takes no position on any of this — but they must match what
/// `remote_control_device` expects, so they live in a single file and are
/// asserted by tests instead of being spread over the adapter.
class WebRtcContract {
  const WebRtcContract._();

  /// The one data channel of a session. The technician side creates it; the
  /// tablet receives it through `onDataChannel`.
  static const String controlChannelLabel = 'control';

  /// Ordered, reliable delivery — the default SCTP behaviour.
  ///
  /// Remote control commands are a sequence of user actions: a tap that
  /// arrives after the swipe that followed it would be worse than a slower
  /// channel.
  static const bool controlChannelOrdered = true;

  /// The only media this application negotiates: the tablet's screen, in one
  /// direction.
  ///
  /// The console receives and never sends — it has no camera, no microphone
  /// and no screen to share — so the offer carries exactly one `recvonly`
  /// video section, declared with a transceiver. `offerToReceiveVideo` is not
  /// used: it is the legacy Plan B way of asking for the same thing, and
  /// libwebrtc itself warns against it under Unified Plan.
  ///
  /// Audio is out of scope: none is negotiated and none is accepted.
  static const String screenVideoKind = 'video';
  static const String screenVideoDirection = 'recvonly';

  /// `RTCSessionDescription` types. The offer/answer distinction lives in the
  /// event name on the wire and in the type here.
  static const String offerType = 'offer';
  static const String answerType = 'answer';

  /// Keys of the map `createPeerConnection` takes.
  static const String iceServersKey = 'iceServers';
  static const String urlsKey = 'urls';

  /// Configuration of the peer connection.
  ///
  /// An empty `iceServers` list is valid and is the default: host candidates
  /// alone are enough on a LAN, and no public server is contacted unless
  /// `WEBRTC_STUN_URL` was defined.
  static Map<String, dynamic> peerConfiguration(
    WebRtcIceConfiguration configuration,
  ) => {
    iceServersKey: [
      for (final server in configuration.iceServers) {urlsKey: server.urls},
    ],
  };
}
