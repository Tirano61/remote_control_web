/// State of the `RTCPeerConnection`, as this application models it.
///
/// It mirrors the states a browser reports, kept as a domain enum so that
/// nothing above the data layer imports `package:flutter_webrtc`.
enum WebRtcPeerConnectionState {
  /// Created, nothing negotiated yet (`new`).
  fresh,

  /// ICE is checking candidate pairs (`connecting`).
  connecting,

  /// At least one candidate pair works: the peers can talk (`connected`).
  connected,

  /// Connectivity was lost but may come back on its own (`disconnected`).
  ///
  /// Transient. It must never destroy a peer connection by itself.
  disconnected,

  /// Terminal for this negotiation: ICE gave up (`failed`).
  failed,

  /// The peer connection was closed (`closed`).
  closed,
}

/// State of an `RTCDataChannel`.
///
/// Tracked apart from [WebRtcPeerConnectionState] on purpose: a connected peer
/// connection does not guarantee that the SCTP channel is already open.
enum WebRtcDataChannelState { connecting, open, closing, closed }
