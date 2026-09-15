import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/logging/debug_log.dart';
import '../../../../signaling/domain/client/technician_signaling_client.dart';
import '../../../../signaling/domain/entities/remote_signaling_message.dart';
import '../../../../signaling/domain/entities/webrtc_ice_candidate.dart';
import '../../../domain/client/webrtc_peer_client.dart';
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
/// createSession -> control channel -> createOffer + setLocalDescription
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
/// Security: SDP and ICE candidate contents never reach the log. What is
/// logged is the lifecycle — created, relayed, applied, connected, failed.
class WebRtcSessionBloc extends Bloc<WebRtcSessionEvent, WebRtcSessionState> {
  WebRtcSessionBloc({
    required WebRtcPeerClient peerClient,
    required TechnicianSignalingClient signalingClient,
    required WebRtcIceConfiguration iceConfiguration,
  }) : _peerClient = peerClient,
       _signalingClient = signalingClient,
       _iceConfiguration = iceConfiguration,
       super(const WebRtcIdle()) {
    on<WebRtcNegotiationRequested>(_onNegotiationRequested);
    on<WebRtcSignalingLost>(_onSignalingLost);
    on<WebRtcSessionTerminated>(_onTerminated);
    on<_WebRtcPeerReported>(_onPeerReported);
    on<_WebRtcSignalingReported>(_onSignalingReported);

    _incomingSubscription = _signalingClient.incoming.listen(
      (message) => add(_WebRtcSignalingReported(message)),
    );
  }

  final WebRtcPeerClient _peerClient;
  final TechnicianSignalingClient _signalingClient;
  final WebRtcIceConfiguration _iceConfiguration;

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

  @override
  Future<void> close() async {
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

    emit(WebRtcPreparing(remoteSessionId: remoteSessionId));

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

      final offer = await session.createLocalOffer();
      if (generation != _generation) return;
      emit(
        WebRtcOffering(
          remoteSessionId: remoteSessionId,
          controlChannelState: _controlChannelState,
        ),
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
          WebRtcConnecting(
            remoteSessionId: remoteSessionId,
            controlChannelState: _controlChannelState,
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
    await _releaseNegotiation();
    if (state is WebRtcIdle) return;
    emit(const WebRtcIdle());
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
        final next = _withControlChannelState(state, channelState);
        if (next != state) emit(next);

      case ControlChannelMessageReceived():
        // The channel carries no protocol yet. Nothing is parsed, nothing is
        // answered, and the payload is not logged.
        break;
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
            WebRtcConnecting(
              remoteSessionId: remoteSessionId,
              controlChannelState: _controlChannelState,
            ),
          );
        }

      case WebRtcPeerConnectionState.connected:
        // The peers can talk. `RemoteSession` is *not* promoted to ACTIVE:
        // that transition does not exist in the backend and is never faked.
        emit(
          WebRtcConnected(
            remoteSessionId: remoteSessionId,
            controlChannelState: _controlChannelState,
          ),
        );

      case WebRtcPeerConnectionState.disconnected:
        // Transient: ICE may recover by itself. Nothing is destroyed and no
        // timer is started to force the issue.
        if (state is WebRtcConnected) {
          emit(
            WebRtcInterrupted(
              remoteSessionId: remoteSessionId,
              controlChannelState: _controlChannelState,
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

    await subscription?.cancel();
    await session?.close();
  }

  /// The same state with a new `control` channel state.
  static WebRtcSessionState _withControlChannelState(
    WebRtcSessionState current,
    WebRtcDataChannelState channelState,
  ) => switch (current) {
    WebRtcPreparing(:final remoteSessionId) => WebRtcPreparing(
      remoteSessionId: remoteSessionId,
      controlChannelState: channelState,
    ),
    WebRtcOffering(:final remoteSessionId) => WebRtcOffering(
      remoteSessionId: remoteSessionId,
      controlChannelState: channelState,
    ),
    WebRtcConnecting(:final remoteSessionId) => WebRtcConnecting(
      remoteSessionId: remoteSessionId,
      controlChannelState: channelState,
    ),
    WebRtcConnected(:final remoteSessionId) => WebRtcConnected(
      remoteSessionId: remoteSessionId,
      controlChannelState: channelState,
    ),
    WebRtcInterrupted(:final remoteSessionId) => WebRtcInterrupted(
      remoteSessionId: remoteSessionId,
      controlChannelState: channelState,
    ),
    _ => current,
  };
}
