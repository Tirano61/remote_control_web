import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/logging/debug_log.dart';
import '../../../../remote_control/domain/entities/normalized_remote_point.dart';
import '../../../../remote_control/domain/entities/remote_control_ack.dart';
import '../../../../remote_control/domain/entities/remote_control_command.dart';
import '../../../../remote_control/domain/entities/remote_control_status.dart';
import '../../../../remote_control/domain/services/pending_remote_commands.dart';
import '../../../../remote_control/domain/services/remote_control_command_id_generator.dart';
import '../../../../remote_control/domain/services/remote_settle_guard.dart';
import '../../../../remote_control/domain/services/remote_touch_session.dart';
import '../../../../signaling/domain/client/technician_signaling_client.dart';
import '../../../../signaling/domain/entities/remote_signaling_message.dart';
import '../../../../signaling/domain/entities/webrtc_ice_candidate.dart';
import '../../../domain/client/webrtc_peer_client.dart';
import '../../../domain/entities/remote_video_track.dart';
import '../../../domain/entities/webrtc_connection_state.dart';
import '../../../domain/entities/webrtc_ice_configuration.dart';
import '../../../domain/entities/webrtc_peer_event.dart';

part 'webrtc_session_event.dart';
part 'webrtc_session_state.dart';

/// Drives one WebRTC negotiation with the tablet.
///
/// The role is fixed for this stage: **`remote_control_web` is the initial
/// offerer and `remote_control_device` is the answerer**. The backend stays
/// direction-neutral — either end may send `webrtc:offer` as far as it is
/// concerned — so the two clients agree on it between themselves, and a fixed
/// role is what makes glare impossible without any rollback logic.
///
/// The sequence, once the console says everything is ready:
///
/// ```text
/// createSession -> control channel -> video recvonly
///   -> createOffer + setLocalDescription
///   -> webrtc:offer -> delivered -> flush local ICE
///   -> webrtc:answer -> setRemoteDescription -> flush remote ICE
///   -> RTCPeerConnectionState.connected
/// ```
///
/// Three rules shape everything below:
///
/// * **one negotiation at a time.** Repeated readiness triggers — another
///   `peer-joined`, a refreshed `RemoteSession`, a rejoin — never produce a
///   second peer connection while the current one is usable;
/// * **generations.** Every negotiation has a number, and a callback carrying
///   an old one is dropped. A peer connection being torn down keeps firing for
///   a while, and it must never touch the state of its successor;
/// * **nothing is retried in a loop.** A failure releases the resources and
///   waits: a new negotiation needs a genuinely new situation — a new socket,
///   a new join, a new readiness — not a timer.
///
/// Remote control commands travel over the channel of this same negotiation, so
/// they share its lifetime and its generation: whatever is pending ends with it,
/// and an acknowledgement from a replaced peer connection is dropped like any
/// other late callback. A command is sent at most once. Nothing queues a gesture
/// and nothing repeats one, because it may have run even when its acknowledgement
/// was lost. While a global action, an IME action or a long press settles, new
/// commands are dropped rather than held for later, for the same reason, and
/// likewise while a text is unanswered. An IME action only ever goes out because
/// the technician pressed Acción: nothing sends one after a tap or a text.
///
/// A press held still becomes a touch session ([RemoteTouchSession]): one remote
/// finger that follows the pointer until it goes up or is cancelled. Its messages
/// do not go through the pending commands, and nothing else goes out while it
/// lasts. On a tablet that answers its hold `unsupported_command`, the legacy
/// long press is sent instead, and from then on for that negotiation.
///
/// Security: SDP and ICE candidate contents never reach the log, and neither do
/// the coordinates of a gesture or a text. What is logged is the lifecycle — created,
/// relayed, applied, connected, failed — and the opaque id of a command. A text is
/// not kept either: it goes from the event to the channel and nothing here holds it
/// while its answer is awaited.
class WebRtcSessionBloc extends Bloc<WebRtcSessionEvent, WebRtcSessionState> {
  WebRtcSessionBloc({
    required WebRtcPeerClient peerClient,
    required TechnicianSignalingClient signalingClient,
    required WebRtcIceConfiguration iceConfiguration,
    RemoteControlCommandIdGenerator? commandIdGenerator,
    Duration remoteCommandMargin = defaultRemoteCommandMargin,
    Duration settleDuration = remoteSettleDuration,
    Duration answerDeadline = defaultAnswerDeadline,
    Duration? recoveryAnswerDeadline,
  }) : _peerClient = peerClient,
       _answerDeadline = answerDeadline,
       _recoveryAnswerDeadline =
           recoveryAnswerDeadline ??
           (answerDeadline < defaultRecoveryAnswerDeadline
               ? answerDeadline
               : defaultRecoveryAnswerDeadline),
       _signalingClient = signalingClient,
       _iceConfiguration = iceConfiguration,
       _commandIdGenerator =
           commandIdGenerator ?? SequentialRemoteControlCommandIdGenerator(),
       _pendingCommands = PendingRemoteCommands(margin: remoteCommandMargin),
       _settleGuard = RemoteSettleGuard(settleDuration: settleDuration),
       _touchAnswerDeadline = remoteTouchEstimatedWork + remoteCommandMargin,
       super(const WebRtcIdle()) {
    on<WebRtcNegotiationRequested>(_onNegotiationRequested);
    on<WebRtcSignalingLost>(_onSignalingLost);
    on<WebRtcSessionTerminated>(_onTerminated);
    on<WebRtcRemoteTapRequested>(_onRemoteTapRequested);
    on<WebRtcRemoteSwipeRequested>(_onRemoteSwipeRequested);
    on<WebRtcRemoteLongPressRequested>(_onRemoteLongPressRequested);
    on<WebRtcRemoteTouchHoldRequested>(_onRemoteTouchHoldRequested);
    on<WebRtcRemoteTouchMoved>(_onRemoteTouchMoved);
    on<WebRtcRemoteTouchReleased>(_onRemoteTouchReleased);
    on<WebRtcRemoteTouchCancelled>(_onRemoteTouchCancelled);
    on<_WebRtcRemoteTouchTimerFired>(_onRemoteTouchTimerFired);
    on<WebRtcRemoteBackRequested>(_onRemoteBackRequested);
    on<WebRtcRemoteHomeRequested>(_onRemoteHomeRequested);
    on<WebRtcRemoteRecentsRequested>(_onRemoteRecentsRequested);
    on<WebRtcRemoteTextRequested>(_onRemoteTextRequested);
    on<WebRtcRemoteImeEnterRequested>(_onRemoteImeEnterRequested);
    on<WebRtcRemotePictureChanged>(_onRemotePictureChanged);
    on<WebRtcRemoteSessionActivityChanged>(_onRemoteSessionActivityChanged);
    on<_WebRtcRemoteCommandTimedOut>(_onRemoteCommandTimedOut);
    on<_WebRtcRemoteActionSettled>(_onRemoteActionSettled);
    on<_WebRtcPeerReported>(_onPeerReported);
    on<_WebRtcSignalingReported>(_onSignalingReported);
    on<_WebRtcAnswerDeadlineReached>(_onAnswerDeadlineReached);
    on<WebRtcAutomaticRecoveryChanged>(_onAutomaticRecoveryChanged);
    on<WebRtcConnectionRetryRequested>(_onConnectionRetryRequested);
    on<WebRtcPeerArrived>(_onPeerArrived);

    _incomingSubscription = _signalingClient.incoming.listen(
      (message) => add(_WebRtcSignalingReported(message)),
    );
  }

  final WebRtcPeerClient _peerClient;
  final TechnicianSignalingClient _signalingClient;
  final WebRtcIceConfiguration _iceConfiguration;
  final RemoteControlCommandIdGenerator _commandIdGenerator;

  /// How long a command waits for its acknowledgement beyond the work the tablet
  /// has to do first ([PendingRemoteCommands.deadlineFor]). The tablet sends none
  /// on a channel that closed or was replaced, so an answer may never come.
  static const Duration defaultRemoteCommandMargin = Duration(seconds: 3);

  /// How long a relayed offer may wait for its answer before the negotiation
  /// is reported as unanswered ([WebRtcSessionState.isAnswerOverdue]).
  ///
  /// It ends nothing. The tablet answers only after Android's MediaProjection
  /// consent, so a person deciding is a perfectly normal reason for this, and
  /// the peer connection is kept for an answer that comes late. Seen on the
  /// T10A: 10 s from the offer to the answer while the user read the dialog.
  static const Duration defaultAnswerDeadline = Duration(seconds: 30);

  /// The answer deadline of an offer made by the console's recovery
  /// ([WebRtcNegotiationRequested.isRecovery]).
  ///
  /// Shorter than the first offer's on purpose. It is the fallback for a lost
  /// offer the console was not told about — the tablet's
  /// `remote-session:peer-joined` is best effort, and the backend does not
  /// emit it while an older tablet socket is still in the room. A tablet that
  /// still holds its capture answers within a second (T10A: 0.5 s from the
  /// offer to the answer); one that needs a new MediaProjection consent shows
  /// a single dialog whatever the number of offers, and the newest one gets
  /// the grant. Measured against the tablet's 45 s orphan-capture window,
  /// counted from its rejoin: 10 s + the 5 s step still offers within it.
  static const Duration defaultRecoveryAnswerDeadline = Duration(seconds: 10);

  final Duration _answerDeadline;
  final Duration _recoveryAnswerDeadline;

  /// Started when the backend relayed the offer, for that negotiation only.
  Timer? _answerDeadlineTimer;

  /// The answer deadline of the current negotiation passed without one.
  bool _isAnswerOverdue = false;

  /// The tablet entered the room after the current offer was relayed, and no
  /// answer came: see [WebRtcSessionState.isOfferLost].
  bool _isOfferLost = false;

  /// No offer of the session has been answered since a deadline passed. It
  /// outlives the negotiation it was noticed on, so the technician keeps being
  /// told the tablet may be waiting for its user while the console offers again.
  bool _isTabletSilent = false;

  /// What the console said about its automatic recovery. Outlives a
  /// negotiation: it is about the session, and it is said before the next one
  /// exists.
  bool _isRecoveryScheduled = false;

  final StreamController<String> _connectionRetries =
      StreamController<String>.broadcast();

  /// The REINTENTAR presses that reached a negotiation which could use one,
  /// each with the session it is for. The console decides what follows.
  Stream<String> get connectionRetries => _connectionRetries.stream;

  late final StreamSubscription<RemoteSignalingMessage> _incomingSubscription;

  /// Identifies the current negotiation. Never persisted: an F5 destroys the
  /// peer connection anyway, and the next one starts from zero.
  int _generation = 0;

  WebRtcPeerSession? _session;
  StreamSubscription<WebRtcPeerEvent>? _peerSubscription;

  /// The backend acknowledged the offer relay. Until then, a local candidate
  /// would reach a device that has no offer to attach it to.
  bool _isOfferDelivered = false;

  /// An answer was taken for this negotiation. Guards against a duplicate one.
  bool _isAnswerAccepted = false;

  /// `setRemoteDescription` completed. Until then, `addCandidate` would fail.
  bool _isRemoteDescriptionApplied = false;

  /// Local candidates gathered before the offer was relayed, in order.
  final List<WebRtcIceCandidate> _pendingLocalIceCandidates = [];

  /// Remote candidates that arrived before the answer was applied, in order.
  final List<WebRtcIceCandidate> _pendingRemoteIceCandidates = [];

  bool _isDrainingLocalIce = false;
  bool _isDrainingRemoteIce = false;

  WebRtcDataChannelState _controlChannelState = WebRtcDataChannelState.closed;

  /// The screen the current peer connection is receiving, if any.
  ///
  /// It belongs to the negotiation, exactly like the channel state above: it
  /// is carried into every state that negotiation produces, and forgotten
  /// with it.
  RemoteVideoTrack? _remoteVideoTrack;

  /// The surface says that screen is really being displayed. Belongs to the
  /// negotiation too.
  bool _isPictureDisplayed = false;

  /// The session REST says is `ACTIVE`. It comes from outside and outlives any
  /// one negotiation: after an F5 it is known before a peer connection exists.
  String? _activeRemoteSessionId;

  /// Commands of the current negotiation still waiting for an answer.
  final PendingRemoteCommands _pendingCommands;

  /// The most recent command of the current negotiation.
  RemoteCommandFeedback? _lastRemoteCommand;

  /// Holds new commands back while a global action or an IME action of the
  /// current negotiation is under way.
  final RemoteSettleGuard _settleGuard;

  /// The touch session of the current negotiation, from its hold to the answer
  /// that ends it. There is never more than one: there is one remote finger.
  RemoteTouchSession? _touch;

  /// What the tablet of the current negotiation said about touch sessions.
  RemoteTouchSupport _touchSupport = RemoteTouchSupport.unknown;

  /// The last hold sent whose answer has not arrived, even if its touch is over:
  /// that answer still says whether the tablet runs touch sessions.
  String? _unansweredHoldId;

  /// The last touch session of the current negotiation, for the technician.
  RemoteTouchFeedback? _lastTouch;

  /// How long the answer to a release or a cancel may take.
  final Duration _touchAnswerDeadline;

  @override
  Future<void> close() async {
    // Before anything is awaited: a deadline must not outlive this call.
    _pendingCommands.clear();
    _settleGuard.clear();
    _touch?.end();
    _touch = null;
    _answerDeadlineTimer?.cancel();
    await _incomingSubscription.cancel();
    await _connectionRetries.close();
    _generation++;
    await _releaseNegotiation();
    return super.close();
  }

  /// Readiness became true. It may mean a new peer connection, or nothing.
  Future<void> _onNegotiationRequested(
    WebRtcNegotiationRequested event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final remoteSessionId = event.remoteSessionId;

    // A usable negotiation for this very session already exists. This is the
    // rule that makes a reconnection harmless: the console rejoins the room,
    // asks again, and no second offer is created while the peers still talk.
    //
    // The single exception is a negotiation whose offer was never answered,
    // and only when the console says so — after REST confirmed the session. It
    // is replaced like a failed one: released first, so there are never two.
    if (state.remoteSessionId == remoteSessionId && state.hasNegotiation) {
      if (!event.replacesUnansweredOffer ||
          !(state.isAnswerOverdue || state.isOfferLost)) {
        logDebug('negotiation already in place $remoteSessionId');
        return;
      }
      logDebug(
        state.isOfferLost
            ? 'lost negotiation replaced $remoteSessionId'
            : 'unanswered negotiation replaced $remoteSessionId',
      );
    }

    _generation++;
    final generation = _generation;
    if (state.remoteSessionId != remoteSessionId) _isTabletSilent = false;
    await _releaseNegotiation();

    emit(
      _withNegotiationFacts(WebRtcPreparing(remoteSessionId: remoteSessionId)),
    );

    try {
      final session = await _peerClient.createSession(
        remoteSessionId: remoteSessionId,
        configuration: _iceConfiguration,
      );
      if (generation != _generation) {
        // Abandoned while the peer connection was being created.
        await session.close();
        return;
      }
      _session = session;
      _peerSubscription = session.events.listen(
        (peerEvent) => add(_WebRtcPeerReported(peerEvent, generation)),
      );

      // Before the offer: the channel is what puts the SCTP m-section in it.
      await session.openControlChannel();
      if (generation != _generation) return;

      // Also before the offer: the `recvonly` video section the tablet will
      // attach its screen to. An offer created without it describes a
      // data-only session, and no screen could arrive without renegotiating.
      await session.prepareScreenVideoReceiver();
      if (generation != _generation) return;

      final offer = await session.createLocalOffer();
      if (generation != _generation) return;
      emit(
        _withNegotiationFacts(WebRtcOffering(remoteSessionId: remoteSessionId)),
      );

      final relay = await _signalingClient.sendOffer(offer);
      if (generation != _generation) return;

      if (!relay.isDelivered) {
        // NOT_JOINED, UNAUTHORIZED, UNAVAILABLE, a timeout or no socket: the
        // device never saw this offer, so there is no negotiation to wait on.
        // The resources go, and the rejoin and REST reconciliation the console
        // already performs decide what happens next. The offer is never
        // resent from here, so a refusal cannot become a retry loop.
        logDebug('offer not delivered $remoteSessionId');
        await _releaseNegotiation();
        emit(
          WebRtcFailed(
            remoteSessionId: remoteSessionId,
            reason: WebRtcFailureReason.offerNotDelivered,
            isRecoveryScheduled: _isRecoveryScheduled,
          ),
        );
        return;
      }

      logDebug('offer relayed $remoteSessionId');
      _isOfferDelivered = true;
      _startAnswerDeadline(
        generation,
        event.isRecovery ? _recoveryAnswerDeadline : _answerDeadline,
      );
      if (state is WebRtcOffering) {
        emit(
          _withNegotiationFacts(
            WebRtcConnecting(remoteSessionId: remoteSessionId),
          ),
        );
      }
      await _drainLocalIceCandidates(generation);
    } catch (_) {
      if (generation != _generation) return;
      logDebug('negotiation failed $remoteSessionId');
      await _releaseNegotiation();
      emit(
        WebRtcFailed(
          remoteSessionId: remoteSessionId,
          reason: WebRtcFailureReason.negotiationFailed,
          isRecoveryScheduled: _isRecoveryScheduled,
        ),
      );
    }
  }

  /// Arms the answer deadline of [generation], once its offer was relayed.
  void _startAnswerDeadline(int generation, Duration deadline) {
    _answerDeadlineTimer?.cancel();
    _answerDeadlineTimer = Timer(deadline, () {
      if (isClosed) return;
      add(_WebRtcAnswerDeadlineReached(generation));
    });
  }

  /// No answer in time. Said, not acted upon: the peer connection stays, and a
  /// late answer is applied to it. Whether a new offer is worth making is the
  /// console's decision, after REST.
  void _onAnswerDeadlineReached(
    _WebRtcAnswerDeadlineReached event,
    Emitter<WebRtcSessionState> emit,
  ) {
    if (event.generation != _generation) return;
    final session = _session;
    if (session == null || !_isOfferDelivered || _isAnswerAccepted) return;
    if (_isAnswerOverdue) return;
    _answerDeadlineTimer = null;
    _isAnswerOverdue = true;
    _isTabletSilent = true;
    logDebug('answer overdue ${session.remoteSessionId}');
    final next = _withNegotiationFacts(state);
    if (next != state) emit(next);
  }

  /// The tablet is in the room again. An offer relayed before that, and not
  /// answered, reached a room without it: whatever held it is gone.
  ///
  /// Decided here, synchronously, from what this negotiation already knows:
  /// an offer still being built or relayed ([_isOfferDelivered] false) goes
  /// out to the tablet now in the room, and one that got its answer is
  /// progressing — neither is touched. Nothing is torn down and the deadline
  /// keeps running; replacing is the console's call, after REST. A second
  /// arrival changes nothing more.
  void _onPeerArrived(
    WebRtcPeerArrived event,
    Emitter<WebRtcSessionState> emit,
  ) {
    final session = _session;
    if (session == null || session.remoteSessionId != event.remoteSessionId) {
      return;
    }
    // Only an offer still waiting for its answer. A peer connection that
    // reached `connected` — or `disconnected` after it — proves the tablet
    // has this negotiation, whatever was or was not seen of its answer.
    if (state is! WebRtcConnecting) return;
    if (!_isOfferDelivered ||
        _isAnswerAccepted ||
        _isRemoteDescriptionApplied ||
        _isOfferLost) {
      return;
    }
    _isOfferLost = true;
    logDebug(
      'offer lost, the device rejoined after it ${event.remoteSessionId}',
    );
    final next = _withNegotiationFacts(state);
    if (next != state) emit(next);
  }

  void _onAutomaticRecoveryChanged(
    WebRtcAutomaticRecoveryChanged event,
    Emitter<WebRtcSessionState> emit,
  ) {
    if (event.isScheduled == _isRecoveryScheduled) return;
    _isRecoveryScheduled = event.isScheduled;
    final next = _withNegotiationFacts(state);
    if (next != state) emit(next);
  }

  /// REINTENTAR, handed on to the console when it can mean anything: the
  /// connection of that very session failed, or its offer is unanswered.
  void _onConnectionRetryRequested(
    WebRtcConnectionRetryRequested event,
    Emitter<WebRtcSessionState> emit,
  ) {
    if (state.remoteSessionId != event.remoteSessionId) return;
    if (!state.canRetryConnection) return;
    logDebug('connection retry requested ${event.remoteSessionId}');
    _connectionRetries.add(event.remoteSessionId);
  }

  /// The signaling room is gone.
  Future<void> _onSignalingLost(
    WebRtcSignalingLost event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    if (state.survivesSignalingLoss) {
      // Peer to peer: the connection does not go through the socket, so it is
      // left exactly as it is, and nothing is renegotiated when signaling
      // comes back.
      logDebug('signaling lost, peer connection kept');
      return;
    }
    // An incomplete negotiation still depends on signaling — the answer and
    // the remaining candidates would never arrive.
    if (_session == null) return;

    _generation++;
    await _releaseNegotiation();
    emit(const WebRtcIdle());
  }

  /// The assistance is over, whoever ended it.
  Future<void> _onTerminated(
    WebRtcSessionTerminated event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    _generation++;
    _activeRemoteSessionId = null;
    _isRecoveryScheduled = false;
    _isTabletSilent = false;
    await _releaseNegotiation();
    if (state is WebRtcIdle) return;
    emit(const WebRtcIdle());
  }

  /// A click on the picture.
  Future<void> _onRemoteTapRequested(
    WebRtcRemoteTapRequested event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final session = _sessionAcceptingCommands(
      event.remoteSessionId,
      isAvailable: state.canSendRemoteControl,
    );
    if (session == null) {
      logDebug('remote tap ignored ${event.remoteSessionId}');
      return;
    }
    await _sendRemoteCommand(
      session,
      RemoteTapCommand(
        id: _commandIdGenerator.next(RemoteCommandKind.tap),
        point: event.point,
      ),
      emit,
    );
  }

  /// A drag across the picture, over and done with.
  Future<void> _onRemoteSwipeRequested(
    WebRtcRemoteSwipeRequested event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final session = _sessionAcceptingCommands(
      event.remoteSessionId,
      isAvailable: state.canSendRemoteControl,
    );
    if (session == null) {
      logDebug('remote swipe ignored ${event.remoteSessionId}');
      return;
    }
    await _sendRemoteCommand(
      session,
      RemoteSwipeCommand(
        id: _commandIdGenerator.next(RemoteCommandKind.swipe),
        start: event.start,
        end: event.end,
        durationMs: event.durationMs,
      ),
      emit,
    );
  }

  /// A press held still on the picture, recognised while the pointer is down.
  ///
  /// Checked again here, at the moment the recognition ends, and not when the
  /// pointer went down: by now the session, the channel, the picture or what is
  /// pending may have changed. If anything is missing it is dropped, never kept
  /// for later.
  Future<void> _onRemoteLongPressRequested(
    WebRtcRemoteLongPressRequested event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final session = _sessionAcceptingCommands(
      event.remoteSessionId,
      isAvailable: state.canSendRemoteLongPress,
    );
    if (session == null) {
      logDebug('remote long_press ignored ${event.remoteSessionId}');
      return;
    }
    await _sendRemoteCommand(
      session,
      RemoteLongPressCommand(
        id: _commandIdGenerator.next(RemoteCommandKind.longPress),
        point: event.point,
      ),
      emit,
    );
  }

  /// A press held still on the picture, the pointer still down: a touch session
  /// starts, or the legacy long press goes out.
  ///
  /// What it asks of the state is what a long press asks, checked now and not
  /// when the pointer went down, and it is dropped rather than kept when anything
  /// is missing.
  Future<void> _onRemoteTouchHoldRequested(
    WebRtcRemoteTouchHoldRequested event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final session = _sessionAcceptingCommands(
      event.remoteSessionId,
      isAvailable: state.canSendRemoteLongPress,
    );
    if (session == null) {
      logDebug('remote hold ignored ${event.remoteSessionId}');
      return;
    }
    if (_touchSupport == RemoteTouchSupport.unsupported) {
      // This tablet said so already: no round trip is paid again.
      await _sendRemoteCommand(
        session,
        RemoteLongPressCommand(
          id: _commandIdGenerator.next(RemoteCommandKind.longPress),
          point: event.point,
        ),
        emit,
      );
      return;
    }

    final generation = _generation;
    final touchId = _commandIdGenerator.nextTouch();
    final holdId = _commandIdGenerator.next(RemoteCommandKind.touchHold);
    final touch = RemoteTouchSession(
      touchId: touchId,
      holdId: holdId,
      pointer: event.pointer,
      generation: generation,
      remoteSessionId: event.remoteSessionId,
      channel: session,
      initialPoint: event.point,
      support: _touchSupport,
      answerDeadline: _touchAnswerDeadline,
      onTimer: (timer) {
        if (isClosed) return;
        add(_WebRtcRemoteTouchTimerFired(touchId, generation, timer));
      },
    );
    _touch = touch;
    _unansweredHoldId = holdId;
    _lastRemoteCommand = null;
    _lastTouch = RemoteTouchFeedback(
      touchId: touchId,
      phase: RemoteTouchPhase.holding,
    );
    final sending = _sendTouchMessage(
      session,
      touch,
      RemoteTouchHoldCommand(id: holdId, touch: touchId, point: event.point),
      emit,
    );
    // From the moment the hold is handed over, and not from its answer: the
    // tablet's watchdog runs from the moment the finger goes down.
    touch.start();
    emit(_withNegotiationFacts(state));
    await sending;
  }

  /// The pointer of the touch moved. Whether that goes out now, later or never
  /// is the touch session's decision: the latest position wins.
  Future<void> _onRemoteTouchMoved(
    WebRtcRemoteTouchMoved event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final touch = _streamingTouch(event.remoteSessionId, event.pointer);
    if (touch == null || !touch.observe(event.point)) return;
    await _sendTouchMove(touch, isKeepalive: false, emit);
  }

  /// The pointer of the touch went up: the finger is lifted where it is now,
  /// whether or not the hold was answered.
  Future<void> _onRemoteTouchReleased(
    WebRtcRemoteTouchReleased event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final touch = _streamingTouch(event.remoteSessionId, event.pointer);
    if (touch == null) return;
    final session = _channelOf(touch);
    if (session == null) return;

    final generation = _generation;
    final command = touch.release(
      _commandIdGenerator.next(RemoteCommandKind.touchRelease),
      event.point,
    );
    final sending = _sendTouchMessage(session, touch, command, emit);
    // Lifting the finger may drop something or end a long press: the screen
    // gets its settle time, from now, like after any such action.
    _settleGuard.begin(
      command.id,
      onElapsed: (commandId) {
        if (isClosed) return;
        add(_WebRtcRemoteActionSettled(commandId, generation));
      },
    );
    _reportTouch(touch);
    emit(_withNegotiationFacts(state));
    await sending;
  }

  /// The surface cannot go on with the touch.
  Future<void> _onRemoteTouchCancelled(
    WebRtcRemoteTouchCancelled event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final touch = _streamingTouch(event.remoteSessionId, event.pointer);
    if (touch == null) return;
    await _cancelTouch(touch, emit);
  }

  Future<void> _onRemoteTouchTimerFired(
    _WebRtcRemoteTouchTimerFired event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final touch = _touch;
    if (event.generation != _generation ||
        touch == null ||
        touch.touchId != event.touchId) {
      return;
    }
    switch (event.timer) {
      case RemoteTouchTimer.keepalive:
        if (!touch.isStreaming) return;
        await _sendTouchMove(touch, isKeepalive: true, emit);

      case RemoteTouchTimer.throttle:
        if (!touch.isMoveDue) return;
        await _sendTouchMove(touch, isKeepalive: false, emit);

      case RemoteTouchTimer.lifetime:
        if (!touch.isStreaming) return;
        logDebug('touch lifetime reached touch=${touch.touchId}');
        await _cancelTouch(touch, emit);

      case RemoteTouchTimer.deadline:
        final releaseId = touch.releaseId;
        if (releaseId != null) {
          // Nothing known about the release: never sent again, only reported.
          logDebug('touch_release timed out $releaseId');
          _settleGuard.release(releaseId);
          _finishTouch(touch, failure: RemoteCommandOutcome.timedOut);
        } else {
          // The tablet's watchdog ends a touch that hears nothing anyway.
          logDebug('touch_cancel unanswered ${touch.cancelId}');
          _finishTouch(touch, phase: RemoteTouchPhase.cancelled);
        }
        emit(_withNegotiationFacts(state));
    }
  }

  /// The touch [pointer] follows, while it is still being followed.
  RemoteTouchSession? _streamingTouch(String remoteSessionId, int pointer) {
    final touch = _touch;
    if (touch == null ||
        !touch.isStreaming ||
        touch.pointer != pointer ||
        touch.remoteSessionId != remoteSessionId) {
      return null;
    }
    return touch;
  }

  /// The channel [touch] travels on, while it is still the current one.
  WebRtcPeerSession? _channelOf(RemoteTouchSession touch) {
    final session = _session;
    if (session == null ||
        !identical(session, touch.channel) ||
        touch.generation != _generation) {
      return null;
    }
    return session;
  }

  /// The next move, or a keepalive, handed to the channel now.
  Future<void> _sendTouchMove(
    RemoteTouchSession touch,
    Emitter<WebRtcSessionState> emit, {
    required bool isKeepalive,
  }) async {
    final session = _channelOf(touch);
    if (session == null) return;
    final hadMoved = touch.hasMoved;
    final command = touch.move(
      _commandIdGenerator.next(RemoteCommandKind.touchMove),
      isKeepalive: isKeepalive,
    );
    final sending = _sendTouchMessage(
      session,
      touch,
      command,
      emit,
      isKeepalive: isKeepalive,
    );
    if (touch.hasMoved != hadMoved) {
      // Once per touch, not once per move.
      _reportTouch(touch);
      emit(_withNegotiationFacts(state));
    }
    await sending;
  }

  /// Takes the finger away: a `touch_cancel` while the channel is open, and only
  /// a local end when it is not, since nothing could carry it.
  Future<void> _cancelTouch(
    RemoteTouchSession touch,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final session = _channelOf(touch);
    if (session == null ||
        _controlChannelState != WebRtcDataChannelState.open) {
      _finishTouch(touch, phase: RemoteTouchPhase.cancelled);
      emit(_withNegotiationFacts(state));
      return;
    }
    final command = touch.cancel(
      _commandIdGenerator.next(RemoteCommandKind.touchCancel),
    );
    final sending = _sendTouchMessage(session, touch, command, emit);
    _reportTouch(touch);
    emit(_withNegotiationFacts(state));
    await sending;
  }

  /// Hands one message of [touch] to the channel. Starting the send happens
  /// before anything is awaited, so messages leave in the order they were made.
  Future<void> _sendTouchMessage(
    WebRtcPeerSession session,
    RemoteTouchSession touch,
    RemoteControlCommand command,
    Emitter<WebRtcSessionState> emit, {
    bool isKeepalive = false,
  }) async {
    final commandId = command.id;
    final kind = command.kind;
    final sentAt = touch.lastSentAt.inMilliseconds;
    final isSent = await session.sendRemoteControlCommand(command);
    if (isSent) {
      // Ids, seq and times only: never a coordinate.
      logDebug(switch (command) {
        RemoteTouchHoldCommand(:final touch) =>
          'touch_hold sent $commandId touch=$touch',
        RemoteTouchMoveCommand(:final seq) =>
          'touch_move sent $commandId seq=$seq'
              '${isKeepalive ? ' keepalive' : ''} +${sentAt}ms',
        RemoteTouchReleaseCommand(:final seq) =>
          'touch_release sent $commandId seq=$seq +${sentAt}ms',
        RemoteTouchCancelCommand(:final seq) =>
          'touch_cancel sent $commandId seq=$seq +${sentAt}ms',
        _ => '${kind.logName} sent $commandId',
      });
      return;
    }
    if (!identical(_touch, touch) || touch.generation != _generation) return;
    // The channel refused it: the touch cannot go on, and nothing is resent.
    logDebug('${kind.logName} not sent $commandId');
    _releaseTouchSettle(touch);
    _finishTouch(touch, failure: RemoteCommandOutcome.notSent);
    emit(_withNegotiationFacts(state));
  }

  /// What the tablet answered about [touch]. Returns whether [ack] was about a
  /// touch at all.
  Future<bool> _applyTouchAck(
    RemoteControlAck ack,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final touch = _touch;
    final message = touch?.messageOf(ack.commandId);
    if (touch == null || message == null) {
      if (ack.commandId != _unansweredHoldId) return false;
      // The answer to a hold whose touch is already over. Too late to do
      // anything with it, never too late to learn what the tablet runs.
      _unansweredHoldId = null;
      _learnTouchSupport(ack);
      logDebug('touch_hold answered after its touch ${ack.commandId}');
      return true;
    }

    final error = ack.error;
    switch (message) {
      case RemoteTouchMessage.hold:
        _unansweredHoldId = null;
        _learnTouchSupport(ack);
        if (error == null) {
          // The finger is down past the long press timeout. Nothing more.
          logDebug('touch_hold confirmed ${ack.commandId}');
          touch.confirmHold();
          _reportTouch(touch);
        } else if (error == RemoteControlError.unsupportedCommand) {
          touch.refuseHold();
          await _fallBackToLongPress(touch, emit);
          return true;
        } else if (touch.stage == RemoteTouchStage.cancelling) {
          // A cancel during the hold is answered this way too: the cancel's
          // own answer is the one that ends the touch.
          touch.refuseHold();
        } else {
          logDebug('touch_hold rejected ${ack.commandId}: ${error.code}');
          touch.refuseHold();
          _releaseTouchSettle(touch);
          _finishTouch(touch, failure: _outcomeOf(error));
        }

      case RemoteTouchMessage.move:
        // A move that is taken is never answered. One refusal is enough to
        // know the touch is gone, and the ones after it change nothing.
        if (error == null || touch.stage == RemoteTouchStage.cancelling) {
          return true;
        }
        logDebug('touch_move rejected ${ack.commandId}: ${error.code}');
        _releaseTouchSettle(touch);
        _finishTouch(touch, failure: _outcomeOf(error));

      case RemoteTouchMessage.release:
        if (error == null) {
          // The contact ended on the tablet: not that anything was dropped.
          logDebug('touch_release confirmed ${ack.commandId}');
          _settleGuard.accept(ack.commandId);
          _finishTouch(touch, phase: RemoteTouchPhase.released);
        } else {
          logDebug('touch_release rejected ${ack.commandId}: ${error.code}');
          _settleGuard.release(ack.commandId);
          _finishTouch(touch, failure: _outcomeOf(error));
        }

      case RemoteTouchMessage.cancel:
        // Whatever the answer, the touch is over on the tablet.
        _finishTouch(touch, phase: RemoteTouchPhase.cancelled);
    }
    emit(_withNegotiationFacts(state));
    return true;
  }

  /// The tablet does not run touch sessions: the touch ends here, and if the
  /// technician really held the press, the legacy long press goes out where it
  /// started. Nothing tries to reproduce the moves: a long press is all an older
  /// tablet can do with a hold.
  ///
  /// The touch_hold never ran there, so this never makes two long presses.
  Future<void> _fallBackToLongPress(
    RemoteTouchSession touch,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final wasCancelled = touch.stage == RemoteTouchStage.cancelling;
    logDebug(
      'touch_hold unsupported ${touch.holdId}'
      '${wasCancelled ? '' : ', long_press instead'}',
    );
    _releaseTouchSettle(touch);
    if (wasCancelled) {
      _finishTouch(touch, phase: RemoteTouchPhase.cancelled);
      emit(_withNegotiationFacts(state));
      return;
    }
    // No word about the touch: the long press speaks for itself.
    _finishTouch(touch);
    _lastTouch = null;
    emit(_withNegotiationFacts(state));

    final session = _sessionAcceptingCommands(
      touch.remoteSessionId,
      isAvailable: state.canSendRemoteLongPress,
    );
    if (session == null || !identical(session, touch.channel)) {
      logDebug('long_press fallback not possible ${touch.remoteSessionId}');
      return;
    }
    await _sendRemoteCommand(
      session,
      RemoteLongPressCommand(
        id: _commandIdGenerator.next(RemoteCommandKind.longPress),
        point: touch.initialPoint,
      ),
      emit,
    );
  }

  /// Only `ok` and `unsupported_command` to a hold say anything about it.
  void _learnTouchSupport(RemoteControlAck ack) {
    final error = ack.error;
    if (error == null) {
      _touchSupport = RemoteTouchSupport.supported;
    } else if (error == RemoteControlError.unsupportedCommand) {
      _touchSupport = RemoteTouchSupport.unsupported;
    }
  }

  /// Forgotten with the negotiation, the session or the channel it was learned on.
  void _resetTouchSupport() {
    _touchSupport = RemoteTouchSupport.unknown;
    _unansweredHoldId = null;
  }

  /// The release of [touch] will not be answered in a way that lets the screen
  /// settle on its own: whatever it holds back goes.
  void _releaseTouchSettle(RemoteTouchSession touch) {
    final releaseId = touch.releaseId;
    if (releaseId != null) _settleGuard.release(releaseId);
  }

  /// What the technician is told about [touch] while it lasts.
  void _reportTouch(RemoteTouchSession touch) {
    final phase = switch (touch.stage) {
      RemoteTouchStage.starting =>
        touch.hasMoved ? RemoteTouchPhase.dragging : RemoteTouchPhase.holding,
      RemoteTouchStage.active =>
        touch.hasMoved ? RemoteTouchPhase.dragging : RemoteTouchPhase.held,
      RemoteTouchStage.releasing => RemoteTouchPhase.releasing,
      RemoteTouchStage.cancelling => RemoteTouchPhase.cancelling,
      RemoteTouchStage.dead => null,
    };
    if (phase == null) return;
    _lastTouch = RemoteTouchFeedback(
      touchId: touch.touchId,
      phase: phase,
      hasMoved: touch.hasMoved,
    );
  }

  /// Ends [touch]: its timers stop, its ids are forgotten, and nothing else is
  /// sent for it. Says how it ended when [phase] or [failure] is given.
  void _finishTouch(
    RemoteTouchSession touch, {
    RemoteTouchPhase? phase,
    RemoteCommandOutcome? failure,
  }) {
    touch.end();
    if (identical(_touch, touch)) _touch = null;
    if (failure == RemoteCommandOutcome.touchEnded) {
      logDebug('touch ended touch=${touch.touchId}');
    } else if (phase == RemoteTouchPhase.cancelled) {
      logDebug('touch cancelled touch=${touch.touchId}');
    }
    if (phase == null && failure == null) return;
    _lastTouch = RemoteTouchFeedback(
      touchId: touch.touchId,
      phase: failure == null ? phase! : RemoteTouchPhase.failed,
      hasMoved: touch.hasMoved,
      failure: failure,
    );
  }

  /// The touch cannot be spoken about any more: its channel, its negotiation or
  /// its session is going away.
  ///
  /// With [tryCancel], and a channel still open, a `touch_cancel` goes out first,
  /// as a courtesy: nothing waits for its answer, and the tablet abandons the
  /// touch on its own when the channel, the peer connection or the session goes.
  void _abandonTouch({required bool tryCancel, RemoteCommandOutcome? failure}) {
    final touch = _touch;
    if (touch == null) return;
    final session = _session;
    if (tryCancel &&
        touch.isStreaming &&
        session != null &&
        identical(session, touch.channel) &&
        _controlChannelState == WebRtcDataChannelState.open) {
      final command = touch.cancel(
        _commandIdGenerator.next(RemoteCommandKind.touchCancel),
      );
      unawaited(session.sendRemoteControlCommand(command));
      logDebug(
        'touch_cancel sent ${command.id} seq=${command.seq} best effort',
      );
    }
    _releaseTouchSettle(touch);
    _finishTouch(
      touch,
      phase: failure == null ? RemoteTouchPhase.cancelled : null,
      failure: failure,
    );
  }

  /// The Atrás button.
  Future<void> _onRemoteBackRequested(
    WebRtcRemoteBackRequested event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final session = _sessionAcceptingCommands(
      event.remoteSessionId,
      isAvailable: state.canSendRemoteNavigation,
    );
    if (session == null) {
      logDebug('remote back ignored ${event.remoteSessionId}');
      return;
    }
    await _sendRemoteCommand(
      session,
      RemoteBackCommand(id: _commandIdGenerator.next(RemoteCommandKind.back)),
      emit,
    );
  }

  /// The Inicio button.
  Future<void> _onRemoteHomeRequested(
    WebRtcRemoteHomeRequested event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final session = _sessionAcceptingCommands(
      event.remoteSessionId,
      isAvailable: state.canSendRemoteNavigation,
    );
    if (session == null) {
      logDebug('remote home ignored ${event.remoteSessionId}');
      return;
    }
    await _sendRemoteCommand(
      session,
      RemoteHomeCommand(id: _commandIdGenerator.next(RemoteCommandKind.home)),
      emit,
    );
  }

  /// The Recientes button.
  Future<void> _onRemoteRecentsRequested(
    WebRtcRemoteRecentsRequested event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final session = _sessionAcceptingCommands(
      event.remoteSessionId,
      isAvailable: state.canSendRemoteNavigation,
    );
    if (session == null) {
      logDebug('remote recents ignored ${event.remoteSessionId}');
      return;
    }
    await _sendRemoteCommand(
      session,
      RemoteRecentsCommand(
        id: _commandIdGenerator.next(RemoteCommandKind.recents),
      ),
      emit,
    );
  }

  /// The Enviar texto and Vaciar campo buttons of the dialog.
  ///
  /// The dialog closed when it asked for this, and the text is gone from it, so one
  /// that cannot go out is reported and not given back: the technician writes it
  /// again.
  Future<void> _onRemoteTextRequested(
    WebRtcRemoteTextRequested event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final session = _sessionAcceptingCommands(
      event.remoteSessionId,
      isAvailable:
          state.canSendRemoteText && RemoteSetTextCommand.fits(event.text),
    );
    if (session == null) {
      logDebug('remote text ignored ${event.remoteSessionId}');
      if (_session?.remoteSessionId != event.remoteSessionId) return;
      _lastRemoteCommand = RemoteCommandFeedback(
        commandId: _commandIdGenerator.next(RemoteCommandKind.setText),
        kind: RemoteCommandKind.setText,
        outcome: RemoteCommandOutcome.notSent,
      );
      _lastTouch = null;
      emit(_withNegotiationFacts(state));
      return;
    }
    await _sendRemoteCommand(
      session,
      RemoteSetTextCommand(
        id: _commandIdGenerator.next(RemoteCommandKind.setText),
        text: event.text,
      ),
      emit,
    );
  }

  /// The Acción button.
  ///
  /// Asks for what a text asks for: the picture, so that the technician could see
  /// which field has focus, and nothing ahead of it.
  Future<void> _onRemoteImeEnterRequested(
    WebRtcRemoteImeEnterRequested event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final session = _sessionAcceptingCommands(
      event.remoteSessionId,
      isAvailable: state.canSendRemoteImeEnter,
    );
    if (session == null) {
      logDebug('remote ime_enter ignored ${event.remoteSessionId}');
      return;
    }
    await _sendRemoteCommand(
      session,
      RemoteImeEnterCommand(
        id: _commandIdGenerator.next(RemoteCommandKind.imeEnter),
      ),
      emit,
    );
  }

  /// What the surface says about the picture of this negotiation.
  ///
  /// A touch that loses its picture is cancelled: the technician can no longer
  /// see where the finger is. The surface going away cancels it too; this is the
  /// same rule seen from here.
  Future<void> _onRemotePictureChanged(
    WebRtcRemotePictureChanged event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    if (_session?.remoteSessionId != event.remoteSessionId) return;
    _isPictureDisplayed = event.isDisplayed;
    final touch = _touch;
    if (!event.isDisplayed && touch != null && touch.isStreaming) {
      await _cancelTouch(touch, emit);
      return;
    }
    final next = _withNegotiationFacts(state);
    if (next != state) emit(next);
  }

  /// The session a command aimed at [remoteSessionId] may be sent on, if any.
  ///
  /// [isAvailable] is what this kind of command asks of the state. A global
  /// action or an IME action settling, or a text unanswered, holds back every
  /// kind alike.
  WebRtcPeerSession? _sessionAcceptingCommands(
    String remoteSessionId, {
    required bool isAvailable,
  }) {
    final session = _session;
    if (session == null ||
        session.remoteSessionId != remoteSessionId ||
        !isAvailable ||
        _settleGuard.isActive ||
        _isTextPending ||
        // One interaction pending, whatever its stage: there is one finger.
        _touch != null) {
      return null;
    }
    return session;
  }

  bool get _isTextPending => _pendingCommands.commands.any(
    (pending) => pending.kind == RemoteCommandKind.setText,
  );

  /// An intent becomes a command now or it never does: there is no queue of
  /// commands waiting for the connection, or for a Back to settle.
  Future<void> _sendRemoteCommand(
    WebRtcPeerSession session,
    RemoteControlCommand command,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final generation = _generation;
    // What is needed after the await, so that a text does not have to be.
    final commandId = command.id;
    final kind = command.kind;
    // Tracked before it is sent: the acknowledgement must find it, however
    // quickly it comes back.
    _pendingCommands.track(
      command,
      onTimeout: (commandId) {
        if (isClosed) return;
        add(_WebRtcRemoteCommandTimedOut(commandId, generation));
      },
    );
    // From the moment it is sent: until it is answered, and then until the screen
    // had time to move.
    if (kind.settlesScreen) {
      _settleGuard.begin(
        commandId,
        onElapsed: (commandId) {
          if (isClosed) return;
          add(_WebRtcRemoteActionSettled(commandId, generation));
        },
      );
    }
    _lastRemoteCommand = RemoteCommandFeedback(
      commandId: commandId,
      kind: kind,
      outcome: RemoteCommandOutcome.pending,
    );
    _lastTouch = null;
    emit(_withNegotiationFacts(state));

    final isSent = await session.sendRemoteControlCommand(command);
    if (generation != _generation) return;

    if (isSent) {
      logDebug('${kind.logName} command sent $commandId');
      return;
    }
    if (_pendingCommands.settle(commandId) == null) return;
    _settleGuard.release(commandId);
    _reportCommand(commandId, RemoteCommandOutcome.notSent);
    emit(_withNegotiationFacts(state));
  }

  /// REST changed its mind about which session is `ACTIVE`.
  void _onRemoteSessionActivityChanged(
    WebRtcRemoteSessionActivityChanged event,
    Emitter<WebRtcSessionState> emit,
  ) {
    if (event.activeRemoteSessionId == _activeRemoteSessionId) return;
    _activeRemoteSessionId = event.activeRemoteSessionId;

    // A finger still down is taken away first, while the channel may still carry
    // a cancel: FINALIZAR never waits for a touch, and neither does any other
    // way out of ACTIVE. The tablet abandons the touch on its own as well.
    _abandonTouch(tryCancel: true);
    _resetTouchSupport();
    _lastTouch = null;

    // Nothing sent for the previous answer can be spoken about any more.
    _pendingCommands.clear();
    _settleGuard.clear();
    _lastRemoteCommand = null;

    final next = _withNegotiationFacts(state);
    if (next != state) emit(next);
  }

  void _onRemoteCommandTimedOut(
    _WebRtcRemoteCommandTimedOut event,
    Emitter<WebRtcSessionState> emit,
  ) {
    if (event.generation != _generation) return;
    final command = _pendingCommands.settle(event.commandId);
    if (command == null) return;

    // Reported and left there. The gesture may have run with its answer lost,
    // so sending it again could press something twice.
    logDebug('${command.kind.logName} timed out ${event.commandId}');
    _settleGuard.release(event.commandId);
    _reportCommand(event.commandId, RemoteCommandOutcome.timedOut);
    emit(_withNegotiationFacts(state));
  }

  void _onRemoteActionSettled(
    _WebRtcRemoteActionSettled event,
    Emitter<WebRtcSessionState> emit,
  ) {
    if (event.generation != _generation) return;
    _settleGuard.elapse(event.commandId);
    final next = _withNegotiationFacts(state);
    if (next != state) emit(next);
  }

  Future<void> _applyRemoteControlAck(
    RemoteControlAck ack,
    Emitter<WebRtcSessionState> emit,
  ) async {
    // A touch is not a pending command: its answers are recognised by the touch.
    if (await _applyTouchAck(ack, emit)) return;

    // Unknown, or answered already: only the first answer to a command counts,
    // and an answer that arrives after the timeout changes nothing.
    final command = _pendingCommands.settle(ack.commandId);
    if (command == null) {
      logDebug('control ack ignored ${ack.commandId}');
      return;
    }

    final error = ack.error;
    if (error == null) {
      logDebug('${command.kind.logName} confirmed ${ack.commandId}');
      _settleGuard.accept(ack.commandId);
    } else {
      logDebug(switch (command.kind) {
        RemoteCommandKind.longPress ||
        RemoteCommandKind.setText ||
        RemoteCommandKind.imeEnter =>
          '${command.kind.logName} rejected ${ack.commandId}: ${error.code}',
        _ => 'remote control command rejected: ${error.code}',
      });
      _settleGuard.release(ack.commandId);
    }
    _reportCommand(ack.commandId, _outcomeOf(error));
    emit(_withNegotiationFacts(state));
  }

  static RemoteCommandOutcome _outcomeOf(RemoteControlError? error) =>
      switch (error) {
        null => RemoteCommandOutcome.confirmed,
        RemoteControlError.accessibilityUnavailable =>
          RemoteCommandOutcome.accessibilityUnavailable,
        RemoteControlError.sessionNotActive =>
          RemoteCommandOutcome.sessionNotActive,
        RemoteControlError.gestureRejected =>
          RemoteCommandOutcome.gestureRejected,
        RemoteControlError.textTargetUnavailable =>
          RemoteCommandOutcome.textTargetUnavailable,
        RemoteControlError.textRejected => RemoteCommandOutcome.textRejected,
        RemoteControlError.imeActionUnavailable =>
          RemoteCommandOutcome.imeActionUnavailable,
        RemoteControlError.imeActionRejected =>
          RemoteCommandOutcome.imeActionRejected,
        RemoteControlError.touchEnded => RemoteCommandOutcome.touchEnded,
        RemoteControlError.invalidCommand ||
        RemoteControlError.unsupportedCommand ||
        RemoteControlError.unknown => RemoteCommandOutcome.incompatible,
      };

  /// Only the most recent command is reported. The answer to an older one settles
  /// that command and says nothing about what the technician did last.
  void _reportCommand(String commandId, RemoteCommandOutcome outcome) {
    final last = _lastRemoteCommand;
    if (last == null || last.commandId != commandId) return;
    _lastRemoteCommand = RemoteCommandFeedback(
      commandId: commandId,
      kind: last.kind,
      outcome: outcome,
    );
  }

  /// The channel stopped being open, so no acknowledgement can arrive: nothing
  /// is left to wait for, and no deadline needs to expire to say so.
  void _abandonPendingCommands() {
    if (_pendingCommands.length == 0) return;
    _pendingCommands.clear();
    final last = _lastRemoteCommand;
    if (last?.outcome == RemoteCommandOutcome.pending) {
      _reportCommand(last!.commandId, RemoteCommandOutcome.channelClosed);
    }
  }

  Future<void> _onPeerReported(
    _WebRtcPeerReported event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    // A callback of a peer connection that was already replaced or closed.
    if (event.generation != _generation) return;
    final session = _session;
    if (session == null) return;
    final remoteSessionId = session.remoteSessionId;

    switch (event.event) {
      case LocalIceCandidateGathered(:final candidate):
        // Queued whatever the moment: draining is what decides whether it goes
        // out now, and it keeps the order WebRTC produced them in.
        _pendingLocalIceCandidates.add(candidate);
        await _drainLocalIceCandidates(event.generation);

      case PeerConnectionStateChanged(state: final peerState):
        _applyPeerConnectionState(peerState, remoteSessionId, emit);

      case ControlChannelStateChanged(state: final channelState):
        _controlChannelState = channelState;
        if (channelState != WebRtcDataChannelState.open) {
          // Nothing can carry a cancel any more: the touch ends here, and the
          // tablet abandons it on its own when its channel goes.
          _abandonTouch(
            tryCancel: false,
            failure: _touch == null ? null : RemoteCommandOutcome.channelClosed,
          );
          _resetTouchSupport();
          _abandonPendingCommands();
          _settleGuard.clear();
        }
        final next = _withNegotiationFacts(state);
        if (next != state) emit(next);

      case RemoteControlAckReceived(:final ack):
        await _applyRemoteControlAck(ack, emit);

      case RemoteVideoTrackAvailable(:final track):
        // The screen of *this* peer connection: the generation guard above
        // already dropped the track of a replaced or closed one, so a stale
        // peer can never put its frames on screen. A later track of the same
        // negotiation replaces the earlier one.
        //
        // It is a capability next to the connection, not part of it: neither
        // the peer state nor the `control` channel changes, and "connected"
        // still means exactly what it meant before.
        logDebug('remote video track available $remoteSessionId');
        _remoteVideoTrack = track;
        final next = _withNegotiationFacts(state);
        if (next != state) emit(next);
    }
  }

  void _applyPeerConnectionState(
    WebRtcPeerConnectionState peerState,
    String remoteSessionId,
    Emitter<WebRtcSessionState> emit,
  ) {
    switch (peerState) {
      case WebRtcPeerConnectionState.fresh:
        break;

      case WebRtcPeerConnectionState.connecting:
        if (state is WebRtcPreparing || state is WebRtcOffering) {
          emit(
            _withNegotiationFacts(
              WebRtcConnecting(remoteSessionId: remoteSessionId),
            ),
          );
        }

      case WebRtcPeerConnectionState.connected:
        // Connected proves an answer was applied: nothing is overdue any more.
        _answerDeadlineTimer?.cancel();
        _answerDeadlineTimer = null;
        _isAnswerOverdue = false;
        _isOfferLost = false;
        _isTabletSilent = false;
        // The peers can talk. `RemoteSession` is *not* promoted to ACTIVE:
        // that transition does not exist in the backend and is never faked.
        emit(
          _withNegotiationFacts(
            WebRtcConnected(remoteSessionId: remoteSessionId),
          ),
        );

      case WebRtcPeerConnectionState.disconnected:
        // Transient: ICE may recover by itself. Nothing is destroyed and no
        // timer is started to force the issue.
        if (state is WebRtcConnected) {
          emit(
            _withNegotiationFacts(
              WebRtcInterrupted(remoteSessionId: remoteSessionId),
            ),
          );
        }

      case WebRtcPeerConnectionState.failed:
        _generation++;
        // Nothing can carry a cancel on a peer connection that failed.
        unawaited(_releaseNegotiation(tryCancelTouch: false));
        emit(
          WebRtcFailed(
            remoteSessionId: remoteSessionId,
            reason: WebRtcFailureReason.connectionFailed,
            isRecoveryScheduled: _isRecoveryScheduled,
          ),
        );

      case WebRtcPeerConnectionState.closed:
        _generation++;
        unawaited(_releaseNegotiation(tryCancelTouch: false));
        emit(WebRtcClosed(remoteSessionId));
    }
  }

  Future<void> _onSignalingReported(
    _WebRtcSignalingReported event,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final session = _session;
    final message = event.message;

    // No negotiation: an answer never creates one, and a candidate has nowhere
    // to go. This is also what a late message after a close looks like.
    if (session == null) return;
    // Defence in depth: the signaling client already drops anything that is
    // not addressed to the session this socket joined.
    if (message.remoteSessionId != session.remoteSessionId) return;

    switch (message) {
      case OfferReceived():
        // The console is the offerer. Answering would create glare, so an
        // incoming offer is reported and ignored — and it never tears the
        // current negotiation down.
        logDebug('incoming offer ignored ${message.remoteSessionId}');

      case AnswerReceived(:final answer):
        if (!_isOfferDelivered || _isAnswerAccepted) {
          // Nothing is waiting for an answer, or one was already applied.
          logDebug('unexpected answer ignored ${message.remoteSessionId}');
          return;
        }
        _isAnswerAccepted = true;
        _answerDeadlineTimer?.cancel();
        _answerDeadlineTimer = null;
        if (_isOfferLost) {
          // It was not lost after all: whoever held it answered. Applied like
          // any late answer, and nothing replaces it any more.
          logDebug(
            'answer to an offer taken for lost ${message.remoteSessionId}',
          );
          _isOfferLost = false;
          emit(_withNegotiationFacts(state));
        }
        if (_isAnswerOverdue || _isTabletSilent) {
          // Late, and still this negotiation's: the tablet was most likely
          // waiting for its user. Nothing about it was given up on.
          logDebug('late answer accepted ${message.remoteSessionId}');
          _isAnswerOverdue = false;
          _isTabletSilent = false;
          emit(_withNegotiationFacts(state));
        }
        final generation = _generation;
        try {
          await session.applyRemoteAnswer(answer);
        } catch (_) {
          if (generation != _generation) return;
          logDebug('remote description rejected ${message.remoteSessionId}');
          await _releaseNegotiation();
          emit(
            WebRtcFailed(
              remoteSessionId: message.remoteSessionId,
              reason: WebRtcFailureReason.negotiationFailed,
              isRecoveryScheduled: _isRecoveryScheduled,
            ),
          );
          return;
        }
        if (generation != _generation) return;
        logDebug('remote description applied ${message.remoteSessionId}');
        _isRemoteDescriptionApplied = true;
        await _drainRemoteIceCandidates(generation);

      case IceCandidateReceived(:final candidate):
        // Queued unconditionally: before the answer there is no remote
        // description to attach it to, and afterwards the queue is what keeps
        // the candidates in the order they arrived.
        _pendingRemoteIceCandidates.add(candidate);
        await _drainRemoteIceCandidates(_generation);
    }
  }

  /// Relays the local candidates, oldest first, once the offer is out.
  ///
  /// `setLocalDescription` starts the gathering, so candidates routinely exist
  /// before `webrtc:offer` has been acknowledged. Sending one then would reach
  /// a device that has no offer yet.
  Future<void> _drainLocalIceCandidates(int generation) async {
    if (!_isOfferDelivered || _isDrainingLocalIce) return;
    _isDrainingLocalIce = true;
    try {
      while (_pendingLocalIceCandidates.isNotEmpty) {
        if (generation != _generation) return;
        final candidate = _pendingLocalIceCandidates.removeAt(0);
        final result = await _signalingClient.sendIceCandidate(candidate);
        if (!result.isDelivered) {
          // A candidate that did not make it never closes anything: a
          // connected session survives on the pairs it already has, and an
          // unfinished one is judged by ICE, not by this relay. Nothing is
          // resent, so a broken relay cannot turn into a flood.
          logDebug('ICE candidate not delivered ${candidate.remoteSessionId}');
        }
      }
    } finally {
      _isDrainingLocalIce = false;
    }
  }

  /// Applies the remote candidates, oldest first, once the answer is applied.
  Future<void> _drainRemoteIceCandidates(int generation) async {
    if (!_isRemoteDescriptionApplied || _isDrainingRemoteIce) return;
    _isDrainingRemoteIce = true;
    try {
      while (_pendingRemoteIceCandidates.isNotEmpty) {
        if (generation != _generation) return;
        final session = _session;
        if (session == null) return;
        final candidate = _pendingRemoteIceCandidates.removeAt(0);
        try {
          await session.addRemoteIceCandidate(candidate);
        } catch (_) {
          // One candidate the browser refused. ICE has the others.
          logDebug(
            'remote ICE candidate rejected ${candidate.remoteSessionId}',
          );
        }
      }
    } finally {
      _isDrainingRemoteIce = false;
    }
  }

  /// Closes the peer connection and forgets everything that belonged to it.
  ///
  /// Called from every ending: a new negotiation, a lost signaling room, a
  /// closed assistance, a failure and `close()`. It is safe to call twice, and
  /// it is the only place that releases these resources.
  Future<void> _releaseNegotiation({bool tryCancelTouch = true}) async {
    // While the session and its channel are still known: a finger still down
    // gets a cancel if the channel can carry one, and is forgotten either way.
    _abandonTouch(tryCancel: tryCancelTouch);
    _resetTouchSupport();
    _lastTouch = null;

    final subscription = _peerSubscription;
    final session = _session;
    _peerSubscription = null;
    _session = null;
    _isOfferDelivered = false;
    _isAnswerAccepted = false;
    _isRemoteDescriptionApplied = false;
    _answerDeadlineTimer?.cancel();
    _answerDeadlineTimer = null;
    _isAnswerOverdue = false;
    _isOfferLost = false;
    _pendingLocalIceCandidates.clear();
    _pendingRemoteIceCandidates.clear();
    _controlChannelState = WebRtcDataChannelState.closed;
    // The track dies with its peer connection; only the reference is held.
    _remoteVideoTrack = null;
    _isPictureDisplayed = false;
    _pendingCommands.clear();
    _settleGuard.clear();
    _lastRemoteCommand = null;

    // Not awaited: the subscription stops delivering the moment it is
    // cancelled, and the generation already drops anything late. Its future
    // only reports the clean-up, and waiting for it would hold a replacement
    // back for nothing.
    unawaited(subscription?.cancel());
    await session?.close();
  }

  /// The same state, carrying the current `control` channel state, remote screen
  /// and remote control status. Anything that is not a live negotiation is
  /// returned unchanged.
  WebRtcSessionState _withNegotiationFacts(WebRtcSessionState current) =>
      switch (current) {
        WebRtcPreparing(:final remoteSessionId) => WebRtcPreparing(
          remoteSessionId: remoteSessionId,
          controlChannelState: _controlChannelState,
          remoteVideoTrack: _remoteVideoTrack,
          remoteControl: _remoteControlOf(remoteSessionId),
          isAnswerOverdue: _isAnswerOverdue,
          isRecoveryScheduled: _isRecoveryScheduled,
          isTabletSilent: _isTabletSilent,
          isOfferLost: _isOfferLost,
        ),
        WebRtcOffering(:final remoteSessionId) => WebRtcOffering(
          remoteSessionId: remoteSessionId,
          controlChannelState: _controlChannelState,
          remoteVideoTrack: _remoteVideoTrack,
          remoteControl: _remoteControlOf(remoteSessionId),
          isAnswerOverdue: _isAnswerOverdue,
          isRecoveryScheduled: _isRecoveryScheduled,
          isTabletSilent: _isTabletSilent,
          isOfferLost: _isOfferLost,
        ),
        WebRtcConnecting(:final remoteSessionId) => WebRtcConnecting(
          remoteSessionId: remoteSessionId,
          controlChannelState: _controlChannelState,
          remoteVideoTrack: _remoteVideoTrack,
          remoteControl: _remoteControlOf(remoteSessionId),
          isAnswerOverdue: _isAnswerOverdue,
          isRecoveryScheduled: _isRecoveryScheduled,
          isTabletSilent: _isTabletSilent,
          isOfferLost: _isOfferLost,
        ),
        WebRtcConnected(:final remoteSessionId) => WebRtcConnected(
          remoteSessionId: remoteSessionId,
          controlChannelState: _controlChannelState,
          remoteVideoTrack: _remoteVideoTrack,
          remoteControl: _remoteControlOf(remoteSessionId),
          isAnswerOverdue: _isAnswerOverdue,
          isRecoveryScheduled: _isRecoveryScheduled,
          isTabletSilent: _isTabletSilent,
          isOfferLost: _isOfferLost,
        ),
        WebRtcInterrupted(:final remoteSessionId) => WebRtcInterrupted(
          remoteSessionId: remoteSessionId,
          controlChannelState: _controlChannelState,
          remoteVideoTrack: _remoteVideoTrack,
          remoteControl: _remoteControlOf(remoteSessionId),
          isAnswerOverdue: _isAnswerOverdue,
          isRecoveryScheduled: _isRecoveryScheduled,
          isTabletSilent: _isTabletSilent,
          isOfferLost: _isOfferLost,
        ),
        WebRtcFailed(:final remoteSessionId, :final reason) => WebRtcFailed(
          remoteSessionId: remoteSessionId,
          reason: reason,
          isRecoveryScheduled: _isRecoveryScheduled,
        ),
        _ => current,
      };

  RemoteControlStatus _remoteControlOf(String remoteSessionId) =>
      RemoteControlStatus(
        isSessionActive: _activeRemoteSessionId == remoteSessionId,
        lastCommand: _lastRemoteCommand,
        pendingCommands: _pendingCommands.length,
        isSettling: _settleGuard.isActive,
        isTextPending: _isTextPending,
        isPictureDisplayed: _isPictureDisplayed,
        isTouchActive: _touch != null,
        lastTouch: _lastTouch,
      );
}
