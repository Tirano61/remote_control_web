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
import '../../../../remote_control/domain/services/remote_navigation_guard.dart';
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
/// was lost. While a global action settles, new commands are dropped rather than
/// held for later, for the same reason.
///
/// Security: SDP and ICE candidate contents never reach the log, and neither do
/// the coordinates of a gesture. What is logged is the lifecycle — created, relayed,
/// applied, connected, failed — and the opaque id of a command.
class WebRtcSessionBloc extends Bloc<WebRtcSessionEvent, WebRtcSessionState> {
  WebRtcSessionBloc({
    required WebRtcPeerClient peerClient,
    required TechnicianSignalingClient signalingClient,
    required WebRtcIceConfiguration iceConfiguration,
    RemoteControlCommandIdGenerator? commandIdGenerator,
    Duration remoteCommandMargin = defaultRemoteCommandMargin,
    Duration navigationSettleDuration = remoteNavigationSettleDuration,
  }) : _peerClient = peerClient,
       _signalingClient = signalingClient,
       _iceConfiguration = iceConfiguration,
       _commandIdGenerator =
           commandIdGenerator ?? SequentialRemoteControlCommandIdGenerator(),
       _pendingCommands = PendingRemoteCommands(margin: remoteCommandMargin),
       _navigationGuard = RemoteNavigationGuard(
         settleDuration: navigationSettleDuration,
       ),
       super(const WebRtcIdle()) {
    on<WebRtcNegotiationRequested>(_onNegotiationRequested);
    on<WebRtcSignalingLost>(_onSignalingLost);
    on<WebRtcSessionTerminated>(_onTerminated);
    on<WebRtcRemoteTapRequested>(_onRemoteTapRequested);
    on<WebRtcRemoteSwipeRequested>(_onRemoteSwipeRequested);
    on<WebRtcRemoteBackRequested>(_onRemoteBackRequested);
    on<WebRtcRemoteHomeRequested>(_onRemoteHomeRequested);
    on<WebRtcRemoteRecentsRequested>(_onRemoteRecentsRequested);
    on<WebRtcRemoteSessionActivityChanged>(_onRemoteSessionActivityChanged);
    on<_WebRtcRemoteCommandTimedOut>(_onRemoteCommandTimedOut);
    on<_WebRtcRemoteNavigationSettled>(_onRemoteNavigationSettled);
    on<_WebRtcPeerReported>(_onPeerReported);
    on<_WebRtcSignalingReported>(_onSignalingReported);

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

  /// The session REST says is `ACTIVE`. It comes from outside and outlives any
  /// one negotiation: after an F5 it is known before a peer connection exists.
  String? _activeRemoteSessionId;

  /// Commands of the current negotiation still waiting for an answer.
  final PendingRemoteCommands _pendingCommands;

  /// The most recent command of the current negotiation.
  RemoteCommandFeedback? _lastRemoteCommand;

  /// Holds new commands back while a global action of the current negotiation
  /// is under way.
  final RemoteNavigationGuard _navigationGuard;

  @override
  Future<void> close() async {
    // Before anything is awaited: a deadline must not outlive this call.
    _pendingCommands.clear();
    _navigationGuard.clear();
    await _incomingSubscription.cancel();
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
    if (state.remoteSessionId == remoteSessionId && state.hasNegotiation) {
      logDebug('negotiation already in place $remoteSessionId');
      return;
    }

    _generation++;
    final generation = _generation;
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
          ),
        );
        return;
      }

      logDebug('offer relayed $remoteSessionId');
      _isOfferDelivered = true;
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
        ),
      );
    }
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

  /// The session a command aimed at [remoteSessionId] may be sent on, if any.
  ///
  /// [isAvailable] is what this kind of command asks of the state. A global
  /// action settling holds back every kind alike.
  WebRtcPeerSession? _sessionAcceptingCommands(
    String remoteSessionId, {
    required bool isAvailable,
  }) {
    final session = _session;
    if (session == null ||
        session.remoteSessionId != remoteSessionId ||
        !isAvailable ||
        _navigationGuard.isActive) {
      return null;
    }
    return session;
  }

  /// An intent becomes a command now or it never does: there is no queue of
  /// commands waiting for the connection, or for a Back to settle.
  Future<void> _sendRemoteCommand(
    WebRtcPeerSession session,
    RemoteControlCommand command,
    Emitter<WebRtcSessionState> emit,
  ) async {
    final generation = _generation;
    // Tracked before it is sent: the acknowledgement must find it, however
    // quickly it comes back.
    _pendingCommands.track(
      command,
      onTimeout: (commandId) {
        if (isClosed) return;
        add(_WebRtcRemoteCommandTimedOut(commandId, generation));
      },
    );
    if (command is RemoteNavigationCommand) {
      _navigationGuard.begin(
        command.id,
        onElapsed: (commandId) {
          if (isClosed) return;
          add(_WebRtcRemoteNavigationSettled(commandId, generation));
        },
      );
    }
    _lastRemoteCommand = RemoteCommandFeedback(
      commandId: command.id,
      kind: command.kind,
      outcome: RemoteCommandOutcome.pending,
    );
    emit(_withNegotiationFacts(state));

    final isSent = await session.sendRemoteControlCommand(command);
    if (generation != _generation) return;

    if (isSent) {
      logDebug('${command.kind.name} command sent ${command.id}');
      return;
    }
    if (_pendingCommands.settle(command.id) == null) return;
    _navigationGuard.release(command.id);
    _reportCommand(command.id, RemoteCommandOutcome.notSent);
    emit(_withNegotiationFacts(state));
  }

  /// REST changed its mind about which session is `ACTIVE`.
  void _onRemoteSessionActivityChanged(
    WebRtcRemoteSessionActivityChanged event,
    Emitter<WebRtcSessionState> emit,
  ) {
    if (event.activeRemoteSessionId == _activeRemoteSessionId) return;
    _activeRemoteSessionId = event.activeRemoteSessionId;

    // Nothing sent for the previous answer can be spoken about any more.
    _pendingCommands.clear();
    _navigationGuard.clear();
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
    logDebug('${command.kind.name} timed out ${event.commandId}');
    _navigationGuard.release(event.commandId);
    _reportCommand(event.commandId, RemoteCommandOutcome.timedOut);
    emit(_withNegotiationFacts(state));
  }

  void _onRemoteNavigationSettled(
    _WebRtcRemoteNavigationSettled event,
    Emitter<WebRtcSessionState> emit,
  ) {
    if (event.generation != _generation) return;
    _navigationGuard.elapse(event.commandId);
    final next = _withNegotiationFacts(state);
    if (next != state) emit(next);
  }

  void _applyRemoteControlAck(
    RemoteControlAck ack,
    Emitter<WebRtcSessionState> emit,
  ) {
    // Unknown, or answered already: only the first answer to a command counts,
    // and an answer that arrives after the timeout changes nothing.
    final command = _pendingCommands.settle(ack.commandId);
    if (command == null) {
      logDebug('control ack ignored ${ack.commandId}');
      return;
    }

    final error = ack.error;
    if (error == null) {
      logDebug('${command.kind.name} confirmed ${ack.commandId}');
      _navigationGuard.accept(ack.commandId);
    } else {
      logDebug('remote control command rejected: ${error.code}');
      _navigationGuard.release(ack.commandId);
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
          _abandonPendingCommands();
          _navigationGuard.clear();
        }
        final next = _withNegotiationFacts(state);
        if (next != state) emit(next);

      case RemoteControlAckReceived(:final ack):
        _applyRemoteControlAck(ack, emit);

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
        unawaited(_releaseNegotiation());
        emit(
          WebRtcFailed(
            remoteSessionId: remoteSessionId,
            reason: WebRtcFailureReason.connectionFailed,
          ),
        );

      case WebRtcPeerConnectionState.closed:
        _generation++;
        unawaited(_releaseNegotiation());
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
  Future<void> _releaseNegotiation() async {
    final subscription = _peerSubscription;
    final session = _session;
    _peerSubscription = null;
    _session = null;
    _isOfferDelivered = false;
    _isAnswerAccepted = false;
    _isRemoteDescriptionApplied = false;
    _pendingLocalIceCandidates.clear();
    _pendingRemoteIceCandidates.clear();
    _controlChannelState = WebRtcDataChannelState.closed;
    // The track dies with its peer connection; only the reference is held.
    _remoteVideoTrack = null;
    _pendingCommands.clear();
    _navigationGuard.clear();
    _lastRemoteCommand = null;

    await subscription?.cancel();
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
        ),
        WebRtcOffering(:final remoteSessionId) => WebRtcOffering(
          remoteSessionId: remoteSessionId,
          controlChannelState: _controlChannelState,
          remoteVideoTrack: _remoteVideoTrack,
          remoteControl: _remoteControlOf(remoteSessionId),
        ),
        WebRtcConnecting(:final remoteSessionId) => WebRtcConnecting(
          remoteSessionId: remoteSessionId,
          controlChannelState: _controlChannelState,
          remoteVideoTrack: _remoteVideoTrack,
          remoteControl: _remoteControlOf(remoteSessionId),
        ),
        WebRtcConnected(:final remoteSessionId) => WebRtcConnected(
          remoteSessionId: remoteSessionId,
          controlChannelState: _controlChannelState,
          remoteVideoTrack: _remoteVideoTrack,
          remoteControl: _remoteControlOf(remoteSessionId),
        ),
        WebRtcInterrupted(:final remoteSessionId) => WebRtcInterrupted(
          remoteSessionId: remoteSessionId,
          controlChannelState: _controlChannelState,
          remoteVideoTrack: _remoteVideoTrack,
          remoteControl: _remoteControlOf(remoteSessionId),
        ),
        _ => current,
      };

  RemoteControlStatus _remoteControlOf(String remoteSessionId) =>
      RemoteControlStatus(
        isSessionActive: _activeRemoteSessionId == remoteSessionId,
        lastCommand: _lastRemoteCommand,
        pendingCommands: _pendingCommands.length,
        isNavigationSettling: _navigationGuard.isActive,
      );
}
