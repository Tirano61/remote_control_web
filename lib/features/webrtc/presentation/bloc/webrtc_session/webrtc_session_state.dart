part of 'webrtc_session_bloc.dart';

/// Why a negotiation ended badly.
enum WebRtcFailureReason {
  /// The peer connection, the data channel or the offer could not be created.
  negotiationFailed,

  /// The backend did not relay the offer: `NOT_JOINED`, `UNAUTHORIZED`,
  /// `UNAVAILABLE`, a timeout, or no usable socket. There is no negotiation to
  /// speak of, so nothing waits for an answer.
  offerNotDelivered,

  /// ICE gave up: `RTCPeerConnectionState.failed`.
  connectionFailed,
}

/// State of the WebRTC negotiation with the tablet.
///
/// It is deliberately **not** the state of the `RemoteSession`. The backend
/// owns that one and has no `CONNECTING -> ACTIVE` transition today, so
/// `RemoteSession = CONNECTING` together with `WebRtc = connected` is a normal,
/// expected combination and is never "fixed" locally.
sealed class WebRtcSessionState extends Equatable {
  const WebRtcSessionState();

  /// The remote session being negotiated, when there is one.
  String? get remoteSessionId => null;

  /// State of the `control` data channel, tracked apart from the peer
  /// connection: `connected` does not imply the channel is already open.
  WebRtcDataChannelState get controlChannelState =>
      WebRtcDataChannelState.closed;

  /// Whether a peer connection exists for this state.
  bool get hasNegotiation => false;

  /// Whether the peers can exchange data right now.
  bool get isConnected => false;

  bool get isControlChannelOpen =>
      controlChannelState == WebRtcDataChannelState.open;

  /// Whether losing the signaling socket must leave the peer connection alone.
  ///
  /// WebRTC is peer to peer: once media/data flows, Socket.IO is not in the
  /// path any more and tearing the connection down would break a working
  /// assistance for nothing.
  bool get survivesSignalingLoss => false;

  @override
  List<Object?> get props => const [];
}

/// Nothing is being negotiated: no assistance, no readiness, or everything was
/// cleaned up.
final class WebRtcIdle extends WebRtcSessionState {
  const WebRtcIdle();
}

/// A negotiation with a live peer connection.
sealed class WebRtcNegotiation extends WebRtcSessionState {
  const WebRtcNegotiation({
    required this.remoteSessionId,
    this.controlChannelState = WebRtcDataChannelState.closed,
  });

  @override
  final String remoteSessionId;

  @override
  final WebRtcDataChannelState controlChannelState;

  @override
  bool get hasNegotiation => true;

  @override
  List<Object?> get props => [remoteSessionId, controlChannelState];
}

/// The peer connection and the `control` channel are being created.
final class WebRtcPreparing extends WebRtcNegotiation {
  const WebRtcPreparing({
    required super.remoteSessionId,
    super.controlChannelState,
  });
}

/// The offer was created and applied locally, and is being relayed.
final class WebRtcOffering extends WebRtcNegotiation {
  const WebRtcOffering({
    required super.remoteSessionId,
    super.controlChannelState,
  });
}

/// The offer was relayed; the answer and ICE are being exchanged.
///
/// `delivered: true` only means the backend handed the offer to the device's
/// namespace — never that a connection exists.
final class WebRtcConnecting extends WebRtcNegotiation {
  const WebRtcConnecting({
    required super.remoteSessionId,
    super.controlChannelState,
  });
}

/// `RTCPeerConnectionState.connected`.
///
/// This changes nothing about the `RemoteSession`: it stays whatever REST says.
final class WebRtcConnected extends WebRtcNegotiation {
  const WebRtcConnected({
    required super.remoteSessionId,
    super.controlChannelState,
  });

  @override
  bool get isConnected => true;

  @override
  bool get survivesSignalingLoss => true;
}

/// `RTCPeerConnectionState.disconnected` after having been connected.
///
/// Transient by definition: ICE may recover on its own, so nothing is torn
/// down and no timer is started.
final class WebRtcInterrupted extends WebRtcNegotiation {
  const WebRtcInterrupted({
    required super.remoteSessionId,
    super.controlChannelState,
  });

  @override
  bool get survivesSignalingLoss => true;
}

/// The negotiation ended badly and its resources were released.
///
/// No automatic retry is made from here: a new negotiation starts when a
/// genuinely new situation appears — a new connection, a new join, a new
/// readiness — or when the user asks for it.
final class WebRtcFailed extends WebRtcSessionState {
  const WebRtcFailed({required this.remoteSessionId, required this.reason});

  @override
  final String remoteSessionId;

  final WebRtcFailureReason reason;

  @override
  List<Object?> get props => [remoteSessionId, reason];
}

/// The peer connection reported `closed`.
final class WebRtcClosed extends WebRtcSessionState {
  const WebRtcClosed(this.remoteSessionId);

  @override
  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}
