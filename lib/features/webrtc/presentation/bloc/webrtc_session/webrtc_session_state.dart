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
/// owns that one: `connected` here is what makes the console ask for
/// `POST /remote-sessions/:id/activate`, but the transition itself is the
/// backend's and is never applied locally. Until REST says otherwise,
/// `RemoteSession = CONNECTING` together with `WebRtc = connected` remains a
/// perfectly normal combination.
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

  /// The tablet's screen, when the current peer connection is receiving it.
  ///
  /// A capability next to the connection, never part of it: "connected" is
  /// still the peer connection plus the `control` channel, and a session
  /// without a screen — the tablet is waiting for MediaProjection consent, or
  /// the user refused it — is a normal one. Only the track of the current
  /// negotiation is ever held here; the one of a replaced or closed peer
  /// connection is gone with it.
  RemoteVideoTrack? get remoteVideoTrack => null;

  /// Whether the tablet's screen is arriving.
  bool get hasRemoteVideo => remoteVideoTrack != null;

  /// The remote control side of this negotiation.
  RemoteControlStatus get remoteControl => const RemoteControlStatus();

  /// Whether a global action, Back, Home or Recents, can reach the tablet.
  ///
  /// Every condition matters on its own: an open channel on a session that is
  /// not `ACTIVE` would only get `session_not_active` back. The picture is not
  /// one of them. These are not touches, and the tablet runs them whether or not
  /// it is sharing its screen.
  ///
  /// A global action or an IME action still settling holds everything back for a moment without
  /// making anything unavailable: see [RemoteControlStatus.isSettling].
  bool get canSendRemoteNavigation =>
      isConnected && isControlChannelOpen && remoteControl.isSessionActive;

  /// Whether a gesture on the picture can reach the tablet.
  ///
  /// All of the above, and a track: a click with none has no picture to have
  /// been aimed at. Whether the picture is really being displayed is only known
  /// to the surface, which checks it too.
  bool get canSendRemoteControl => canSendRemoteNavigation && hasRemoteVideo;

  /// Whether the technician can see what a text would land on.
  ///
  /// The tablet would run a text with no picture at all: this is the web's own
  /// decision. It knows nothing about the field, not its name, its content or its
  /// application, so the picture is the only way to check the target.
  bool get canOfferRemoteText =>
      canSendRemoteControl && remoteControl.isPictureDisplayed;

  /// Whether a text can go out right now.
  ///
  /// Nothing may be ahead of it: a swipe or a Back still running could move the
  /// focus away from the field the technician saw, and the text would replace the
  /// content of another one.
  bool get canSendRemoteText =>
      canOfferRemoteText &&
      remoteControl.pendingCommands == 0 &&
      !remoteControl.isSettling &&
      !remoteControl.isTouchActive;

  /// Whether the IME action of the focused field can go out right now.
  ///
  /// The same policy as a text, for the same reason. The tablet would run it with
  /// no picture at all, and that is precisely why the web asks for one: the action
  /// lands on whichever field has focus, which may search, go to the next field or
  /// send something, and the picture is the only way the technician has to check
  /// which field that is. Nothing may be ahead of it either, or the focus could
  /// have moved by the time it runs.
  bool get canSendRemoteImeEnter =>
      canOfferRemoteText &&
      remoteControl.pendingCommands == 0 &&
      !remoteControl.isSettling &&
      !remoteControl.isTouchActive;

  /// Whether a long press can go out right now.
  ///
  /// Everything a tap asks for, a picture really on screen, and nothing ahead of
  /// it: the press is recognised on what the technician sees, and a tap or a
  /// swipe still running could have moved that elsewhere by the time it lands.
  /// Once sent, the settle guard holds every other command back until it is
  /// answered.
  ///
  /// The same for the hold that starts a touch session: whichever of the two the
  /// tablet runs, it is recognised on the same picture.
  bool get canSendRemoteLongPress =>
      canOfferRemoteText &&
      remoteControl.pendingCommands == 0 &&
      !remoteControl.isSettling &&
      !remoteControl.isTouchActive;

  /// The offer was relayed long ago and no answer came back.
  ///
  /// Not a failure, and nothing is torn down for it: the tablet answers only
  /// once Android's MediaProjection consent has been answered, which takes as
  /// long as a person takes, and nothing in the protocol tells the console the
  /// tablet is waiting for one. The same silence is what an offer the tablet
  /// refused, or one that got lost, looks like. A late answer is still applied.
  bool get isAnswerOverdue => false;

  /// No offer of this session has been answered for longer than the answer
  /// deadline, across the negotiations that replaced one another meanwhile.
  /// Cleared by the first answer, a connection, or the end of the session.
  bool get isTabletSilent => false;

  /// The console will try to restore the connection on its own, within its
  /// bounded recovery budget. When this is `false` on a failure, nothing will
  /// happen until the technician asks for it.
  bool get isRecoveryScheduled => false;

  /// Whether the technician may ask for a new connection attempt now.
  bool get canRetryConnection => this is WebRtcFailed || isAnswerOverdue;

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
    this.remoteVideoTrack,
    this.remoteControl = const RemoteControlStatus(),
    this.isAnswerOverdue = false,
    this.isRecoveryScheduled = false,
    this.isTabletSilent = false,
  });

  @override
  final String remoteSessionId;

  @override
  final WebRtcDataChannelState controlChannelState;

  @override
  final RemoteVideoTrack? remoteVideoTrack;

  @override
  final RemoteControlStatus remoteControl;

  @override
  final bool isAnswerOverdue;

  @override
  final bool isRecoveryScheduled;

  @override
  final bool isTabletSilent;

  @override
  bool get hasNegotiation => true;

  @override
  List<Object?> get props => [
    remoteSessionId,
    controlChannelState,
    remoteVideoTrack,
    remoteControl,
    isAnswerOverdue,
    isRecoveryScheduled,
    isTabletSilent,
  ];
}

/// The peer connection and the `control` channel are being created.
final class WebRtcPreparing extends WebRtcNegotiation {
  const WebRtcPreparing({
    required super.remoteSessionId,
    super.controlChannelState,
    super.remoteVideoTrack,
    super.remoteControl,
    super.isAnswerOverdue,
    super.isRecoveryScheduled,
    super.isTabletSilent,
  });
}

/// The offer was created and applied locally, and is being relayed.
final class WebRtcOffering extends WebRtcNegotiation {
  const WebRtcOffering({
    required super.remoteSessionId,
    super.controlChannelState,
    super.remoteVideoTrack,
    super.remoteControl,
    super.isAnswerOverdue,
    super.isRecoveryScheduled,
    super.isTabletSilent,
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
    super.remoteVideoTrack,
    super.remoteControl,
    super.isAnswerOverdue,
    super.isRecoveryScheduled,
    super.isTabletSilent,
  });
}

/// `RTCPeerConnectionState.connected`.
///
/// This changes nothing about the `RemoteSession` by itself: it stays whatever
/// REST says. Together with an open `control` channel it is what the console
/// treats as "the assistance really started", but the session only becomes
/// `ACTIVE` when the backend says so.
final class WebRtcConnected extends WebRtcNegotiation {
  const WebRtcConnected({
    required super.remoteSessionId,
    super.controlChannelState,
    super.remoteVideoTrack,
    super.remoteControl,
    super.isAnswerOverdue,
    super.isRecoveryScheduled,
    super.isTabletSilent,
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
    super.remoteVideoTrack,
    super.remoteControl,
    super.isAnswerOverdue,
    super.isRecoveryScheduled,
    super.isTabletSilent,
  });

  @override
  bool get survivesSignalingLoss => true;
}

/// The negotiation ended badly and its resources were released.
///
/// No automatic retry is made from here: a new negotiation starts when a
/// genuinely new situation appears — a new connection, a new join, a new
/// readiness — when the console, within its recovery schedule and only after
/// REST confirmed the session is still live, asks for one, or when the
/// technician presses REINTENTAR. [isRecoveryScheduled] says whether the
/// console still has an attempt planned.
final class WebRtcFailed extends WebRtcSessionState {
  const WebRtcFailed({
    required this.remoteSessionId,
    required this.reason,
    this.isRecoveryScheduled = false,
  });

  @override
  final String remoteSessionId;

  final WebRtcFailureReason reason;

  @override
  final bool isRecoveryScheduled;

  @override
  List<Object?> get props => [remoteSessionId, reason, isRecoveryScheduled];
}

/// The peer connection reported `closed`.
final class WebRtcClosed extends WebRtcSessionState {
  const WebRtcClosed(this.remoteSessionId);

  @override
  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}
