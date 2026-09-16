import 'dart:async';

import '../../core/error/failure.dart';
import '../../features/auth/presentation/bloc/user_session/user_session_bloc.dart';
import '../../features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import '../../features/signaling/domain/client/technician_signaling_client.dart';
import '../../features/signaling/domain/entities/signaling_relay_result.dart';
import '../../features/support/presentation/bloc/support_requests/support_requests_bloc.dart';
import '../../features/technician_realtime/domain/client/technician_realtime_client.dart';
import '../../features/technician_realtime/domain/entities/remote_session_active_notice.dart';
import '../../features/technician_realtime/domain/entities/remote_session_closed_notice.dart';
import '../../features/technician_realtime/domain/entities/signaling_error_code.dart';
import '../../features/technician_realtime/domain/entities/technician_realtime_status.dart';
import '../../features/technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import '../../features/technician_realtime/presentation/bloc/technician_realtime/technician_realtime_bloc.dart';
import '../../features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

/// Shown on the login page after the `/technicians` handshake was rejected.
const String kRealtimeSessionRejectedNotice =
    'Tu sesión dejó de ser válida. Inicia sesión nuevamente.';

/// Wires the console features together without letting them know each other.
///
/// Every BLoC stays ignorant of the others — none of them imports another —
/// and the rules that only make sense at the level of the whole console live
/// here:
///
/// ```text
/// authenticated                      -> connect /technicians + GET current
/// signed out                         -> disconnect + forget the session
/// socket connected + live session    -> remote-session:join
/// socket lost                        -> the join is no longer valid
/// joined + peer ready + live session -> negotiate WebRTC
/// joined without the peer            -> wait: an offer would reach nobody
/// signaling room lost                -> incomplete negotiations are dropped
/// live session gone                  -> the peer connection is released
/// CONNECTING + connected + control   -> POST /remote-sessions/:id/activate
/// remote-session:active              -> GET current (never the event as state)
/// remote-session:closed              -> GET current (never the event as state)
/// live session disappeared           -> reload the support request queue
/// socket handshake rejected          -> the user session is over
/// relay refused NOT_JOINED           -> join the room again, once
/// relay refused UNAUTHORIZED         -> GET current (never a sign out)
/// relay refused UNAVAILABLE          -> GET current
/// relay refused INVALID_PAYLOAD      -> nothing: it is a contract bug
/// ```
///
/// Five facts are kept strictly apart, because they fail independently:
///
/// ```text
/// socket connected     TechnicianRealtimeBloc
/// signaling joined     SignalingJoinBloc
/// peer ready           SignalingJoined.peerJoined
/// WebRTC connected     WebRtcSessionBloc
/// control channel open WebRtcSessionBloc
/// ```
class TechnicianConsoleCoordinator {
  TechnicianConsoleCoordinator({
    required UserSessionBloc userSessionBloc,
    required RemoteSessionBloc remoteSessionBloc,
    required TechnicianRealtimeBloc technicianRealtimeBloc,
    required SignalingJoinBloc signalingJoinBloc,
    required SupportRequestsBloc supportRequestsBloc,
    required WebRtcSessionBloc webRtcSessionBloc,
    required TechnicianRealtimeClient realtimeClient,
    required TechnicianSignalingClient signalingClient,
  }) : _userSessionBloc = userSessionBloc,
       _remoteSessionBloc = remoteSessionBloc,
       _technicianRealtimeBloc = technicianRealtimeBloc,
       _signalingJoinBloc = signalingJoinBloc,
       _supportRequestsBloc = supportRequestsBloc,
       _webRtcSessionBloc = webRtcSessionBloc,
       _realtimeClient = realtimeClient,
       _signalingClient = signalingClient;

  /// A refused relay may trigger at most one automatic rejoin and one
  /// automatic REST reconciliation per connection.
  ///
  /// This is the guard that makes `relay fails -> refresh -> join -> fails
  /// -> refresh -> ...` impossible. A problem that survives both attempts is
  /// not something more requests would fix; it is recovered by the next
  /// reconnection, which resets the counters, or by the user.
  static const int maxAutomaticRejoinsPerConnection = 1;
  static const int maxAutomaticReconciliationsPerConnection = 1;

  final UserSessionBloc _userSessionBloc;
  final RemoteSessionBloc _remoteSessionBloc;
  final TechnicianRealtimeBloc _technicianRealtimeBloc;
  final SignalingJoinBloc _signalingJoinBloc;
  final SupportRequestsBloc _supportRequestsBloc;
  final WebRtcSessionBloc _webRtcSessionBloc;
  final TechnicianRealtimeClient _realtimeClient;
  final TechnicianSignalingClient _signalingClient;

  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// Whether the console currently believes an assistance is open.
  ///
  /// Only used to notice the transition "there was one, now there is none",
  /// which is when the support request queue is worth re-reading: its request
  /// has just become `COMPLETED`.
  bool _hadLiveSession = false;

  bool _isStarted = false;

  /// What the counters below belong to. They are reset whenever a new socket
  /// or a new assistance appears, because either is a genuinely new situation
  /// that deserves its own budget.
  int? _guardedConnectionId;
  String? _guardedRemoteSessionId;
  int _rejoinsOnConnection = 0;
  int _reconciliationsOnConnection = 0;

  /// The (session, WebRTC readiness) an activation was already asked for.
  ///
  /// Readiness is re-evaluated on every WebRTC state change, every refreshed
  /// `RemoteSession` and every rebuild, so without this a connected peer would
  /// produce one `POST /remote-sessions/:id/activate` per notification. The
  /// backend is idempotent, but that is not a reason to ask it repeatedly.
  ///
  /// A failed activation keeps the guard set: retrying on the very state
  /// change the failure produced is how a tight loop is built. What re-arms it
  /// is a genuinely new situation — a new assistance, or a peer connection
  /// that went away and came back — plus the explicit retry the user is
  /// offered, which goes straight to the BLoC and is one request per press.
  (String, int)? _requestedActivation;

  /// Counts the episodes of "the peers can really exchange data".
  ///
  /// It is the coordinator's equivalent of the negotiation generation the
  /// WebRTC BLoC keeps to itself: a connection that dropped and came back is a
  /// different episode, and deserves its own activation budget.
  int _webRtcReadinessEpisode = 0;
  bool _isWebRtcEstablished = false;

  /// The (connection, session) a negotiation was already asked for.
  ///
  /// Readiness is re-evaluated on many triggers, and a negotiation that failed
  /// must not be restarted by the next one: only a genuinely new situation — a
  /// new socket or a new assistance — asks again. The BLoC additionally
  /// refuses to replace a peer connection that is still usable, so the two
  /// guards together make "one negotiation per readiness" true from both
  /// sides.
  (int, String)? _requestedNegotiation;

  void start() {
    if (_isStarted) return;
    _isStarted = true;

    _subscriptions
      ..add(_userSessionBloc.stream.listen(_onUserSessionChanged))
      ..add(_technicianRealtimeBloc.stream.listen(_onRealtimeStatusChanged))
      ..add(_remoteSessionBloc.stream.listen(_onRemoteSessionChanged))
      ..add(_signalingJoinBloc.stream.listen(_onSignalingJoinChanged))
      ..add(_webRtcSessionBloc.stream.listen(_onWebRtcSessionChanged))
      ..add(_realtimeClient.remoteSessionClosed.listen(_onRemoteSessionClosed))
      ..add(
        _realtimeClient.remoteSessionActivated.listen(_onRemoteSessionActive),
      )
      ..add(_signalingClient.relayRefusals.listen(_onRelayRefused));

    // The console is opened by an already authenticated session, so the
    // current state has to be acted upon and not only its future changes.
    _onUserSessionChanged(_userSessionBloc.state);
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _isStarted = false;
  }

  void _onUserSessionChanged(UserSessionState state) {
    if (state is UserSessionAuthenticated) {
      // Connecting does not wait for a remote session: the namespace also
      // delivers notifications addressed to the technician.
      _technicianRealtimeBloc.add(const TechnicianRealtimeConnectRequested());
      // Whatever is in memory, the backend decides whether an assistance is
      // open. This is what makes an F5 recover on its own.
      _remoteSessionBloc.add(const RemoteSessionStarted());
      return;
    }

    _technicianRealtimeBloc.add(const TechnicianRealtimeDisconnectRequested());
    _signalingJoinBloc.add(const SignalingJoinReset());
    // Signing out ends the assistance for this console, so the peer
    // connection and its data channel go with it.
    _webRtcSessionBloc.add(const WebRtcSessionTerminated());
    _remoteSessionBloc.add(const RemoteSessionCleared());
    _hadLiveSession = false;
    _requestedNegotiation = null;
    _forgetWebRtcReadiness();
    _clearRelayGuards();
  }

  void _onRealtimeStatusChanged(TechnicianRealtimeStatus status) {
    if (status is TechnicianRealtimeConnectionError &&
        status.isAuthenticationError) {
      // The handshake validates the very same User JWT the REST calls use, and
      // there is no refresh token: the session is over. A transport failure
      // never gets here.
      _userSessionBloc.add(
        const UserSessionInvalidated(notice: kRealtimeSessionRejectedNotice),
      );
      return;
    }

    if (status.isConnected) {
      _resetRelayGuards(connectionId: status.connectionId);
      _joinLiveSessionIfPossible();
      // Readiness is never carried over a reconnection: this socket has to be
      // told again, by its own join ACK or by `remote-session:peer-joined`.
      _negotiateWebRtcIfReady();
      return;
    }

    // Rooms do not survive the connection, so nothing is joined any more. The
    // peer connection is not touched here: that is decided when the join state
    // changes, and a connected one survives a socket that dropped.
    _signalingJoinBloc.add(const SignalingJoinReset());
  }

  void _onRemoteSessionChanged(RemoteSessionState state) {
    final failure = state.lastFailure;
    if (failure is AuthFailure) {
      _userSessionBloc.add(const UserSessionInvalidated());
    }

    if (state.hasLiveSession) {
      _hadLiveSession = true;
      _resetRelayGuards(remoteSessionId: state.session?.id);
      _joinLiveSessionIfPossible();
      _negotiateWebRtcIfReady();
      // A session that comes back from REST as `CONNECTING` while the peers
      // are already talking is exactly the case this stage exists for — an
      // F5 in the middle of an assistance, for instance.
      _activateIfEstablished();
      return;
    }

    _signalingJoinBloc.add(const SignalingJoinReset());
    // No live session — closed from here, closed by the tablet, or never
    // there. Whatever WebRTC still holds belongs to an assistance that is
    // over: peer connection, data channel and both candidate queues go.
    _requestedNegotiation = null;
    _requestedActivation = null;
    _webRtcSessionBloc.add(const WebRtcSessionTerminated());

    if (_hadLiveSession && state is! RemoteSessionLoading) {
      // The assistance is over — closed from here or from the tablet. Its
      // support request is `COMPLETED` now, so the queue is stale.
      _hadLiveSession = false;
      _supportRequestsBloc.add(const SupportRequestsRefreshRequested());
    }
  }

  /// The signaling room changed hands: joined, lost, or the tablet arrived.
  void _onSignalingJoinChanged(SignalingJoinState state) {
    if (state is SignalingJoined) {
      _negotiateWebRtcIfReady();
      return;
    }

    // Not in the room any more. An incomplete negotiation cannot finish
    // without signaling — the answer and the remaining candidates would never
    // arrive — while a connected one is peer to peer and is left exactly as it
    // is. The BLoC makes that distinction; from here both cases look alike.
    _requestedNegotiation = null;
    _webRtcSessionBloc.add(const WebRtcSignalingLost());
  }

  /// The WebRTC negotiation reported something.
  ///
  /// Only one question is asked here: can the two ends really exchange data
  /// now — the peer connection is `connected` **and** the `control` channel is
  /// `open`. Everything before that is negotiation noise as far as the
  /// `RemoteSession` is concerned.
  void _onWebRtcSessionChanged(WebRtcSessionState state) {
    final isEstablished = state.isConnected && state.isControlChannelOpen;
    if (isEstablished && !_isWebRtcEstablished) {
      // A new episode of "the peers can work". The previous one's activation
      // budget does not carry over.
      _webRtcReadinessEpisode++;
    }
    _isWebRtcEstablished = isEstablished;

    _activateIfEstablished();
  }

  /// `remote-session:active` arrived over `/technicians`.
  ///
  /// The console that asked for the activation receives this too, so the
  /// common case is an echo of something already being reconciled.
  void _onRemoteSessionActive(RemoteSessionActiveNotice notice) {
    final state = _remoteSessionBloc.state;
    final session = state.session;

    // An event naming a session this console does not hold changes nothing:
    // its id is never adopted, and ownership is never taken from realtime.
    if (session == null || session.id != notice.remoteSessionId) return;
    // Our own activation is still in flight; its response already ends in a
    // `GET /remote-sessions/current`. A second one would be a duplicate.
    if (state.isActivating) return;
    // Already known to be `ACTIVE`: REST has nothing new to tell.
    if (session.isActive) return;

    // The event is a trigger, never the state: the session is not promoted
    // locally, and `connectedAt` comes from the backend or from nowhere.
    _remoteSessionBloc.add(const RemoteSessionRefreshRequested());
  }

  void _onRemoteSessionClosed(RemoteSessionClosedNotice notice) {
    // The event is a trigger, never the state: its id is not adopted and the
    // current session is not closed locally, not even when the ids match.
    // REST decides, here as everywhere else.
    _remoteSessionBloc.add(const RemoteSessionRefreshRequested());
  }

  /// A `webrtc:*` relay was refused by the backend.
  ///
  /// The message itself is never resent from here: whoever produced it — the
  /// WebRTC layer — decides that, and it does so with a peer connection whose
  /// state this class knows nothing about. What is decided here is only what
  /// the *console* has to put right.
  void _onRelayRefused(SignalingRelayRefused refusal) {
    final error = refusal.error;

    // The socket is not in the room, whatever an earlier join ACK said.
    // Membership is already forgotten by the client; the way back is
    // `remote-session:join`, not a retry of the refused message.
    if (error == SignalingErrorCode.notJoined) {
      _rejoinAfterLostMembership(refusal.remoteSessionId);
      return;
    }

    // `UNAUTHORIZED` on a relay is not "the User JWT expired": it is an
    // ownership check — the session does not exist, is CLOSED, or is not this
    // technician's, three cases the backend makes indistinguishable on
    // purpose. The token is therefore left alone (a rejected token arrives as
    // a `connect_error` instead) and REST is asked what the truth is.
    //
    // `UNAVAILABLE` is a transient server side condition, but the session may
    // equally have stopped being available, so it reconciles the same way.
    if (error == SignalingErrorCode.unauthorized ||
        error == SignalingErrorCode.unavailable) {
      _reconcileAfterRelayRefusal();
      return;
    }

    // `INVALID_PAYLOAD` is a programming/contract error: neither a refresh nor
    // a rejoin would change it, and the payload is never bent to "make it
    // pass". An unknown future code is kept as a refusal and acted upon by
    // nobody, which is the safe default.
  }

  void _rejoinAfterLostMembership(String remoteSessionId) {
    if (_rejoinsOnConnection >= maxAutomaticRejoinsPerConnection) return;

    final status = _technicianRealtimeBloc.state;
    final connectionId = status.connectionId;
    if (!status.isConnected || connectionId == null) return;

    final session = _remoteSessionBloc.state.session;
    if (session == null || !session.isLive) return;
    // The refusal belongs to a session the console no longer holds; joining
    // it again would be adopting an id that did not come from REST.
    if (session.id != remoteSessionId) return;

    _rejoinsOnConnection++;
    _signalingJoinBloc
      ..add(const SignalingJoinReset())
      ..add(
        SignalingJoinRequested(
          remoteSessionId: session.id,
          connectionId: connectionId,
          // This connection already settled a join for this session; only an
          // insisting request gets past the de-duplication.
          force: true,
        ),
      );
  }

  void _reconcileAfterRelayRefusal() {
    if (_reconciliationsOnConnection >=
        maxAutomaticReconciliationsPerConnection) {
      return;
    }
    _reconciliationsOnConnection++;
    // REST decides, here as everywhere else. The remote session state that
    // comes back is what closes the assistance, if it is over.
    _remoteSessionBloc.add(const RemoteSessionRefreshRequested());
  }

  /// Forgets everything the guards were scoped to. The next connection or
  /// assistance starts from a clean budget.
  void _clearRelayGuards() {
    _guardedConnectionId = null;
    _guardedRemoteSessionId = null;
    _rejoinsOnConnection = 0;
    _reconciliationsOnConnection = 0;
  }

  /// Gives the guards a fresh budget when the situation they guard changed.
  ///
  /// Each caller reports only what it knows about, so the other half of the
  /// scope is kept as it is.
  void _resetRelayGuards({int? connectionId, String? remoteSessionId}) {
    final nextConnectionId = connectionId ?? _guardedConnectionId;
    final nextRemoteSessionId = remoteSessionId ?? _guardedRemoteSessionId;
    if (nextConnectionId == _guardedConnectionId &&
        nextRemoteSessionId == _guardedRemoteSessionId) {
      return;
    }
    _guardedConnectionId = nextConnectionId;
    _guardedRemoteSessionId = nextRemoteSessionId;
    _rejoinsOnConnection = 0;
    _reconciliationsOnConnection = 0;
  }

  /// Starts a WebRTC negotiation when, and only when, all of this holds:
  ///
  /// ```text
  /// RemoteSession live (CONNECTING or ACTIVE)
  /// + the socket is connected
  /// + this socket joined that session's signaling room
  /// + joined id == RemoteSession.id
  /// + peerJoined == true
  /// + no negotiation was already asked for on this connection
  /// ```
  ///
  /// `joined == true` is deliberately not enough. An offer relayed into a room
  /// the tablet has not entered is handed to nobody and silently dropped, and
  /// nothing would ever answer it.
  void _negotiateWebRtcIfReady() {
    final join = _signalingJoinBloc.state;
    if (join is! SignalingJoined || !join.peerJoined) return;

    final status = _technicianRealtimeBloc.state;
    final connectionId = status.connectionId;
    if (!status.isConnected || connectionId == null) return;

    final session = _remoteSessionBloc.state.session;
    if (session == null || !session.isLive) return;
    // Readiness that is not about the assistance the console holds is not
    // readiness: an id is never adopted from signaling.
    if (session.id != join.remoteSessionId) return;

    final negotiation = (connectionId, session.id);
    if (_requestedNegotiation == negotiation) return;
    _requestedNegotiation = negotiation;

    _webRtcSessionBloc.add(WebRtcNegotiationRequested(session.id));
  }

  /// Confirms to the backend that the assistance really started, when — and
  /// only when — all of this holds:
  ///
  /// ```text
  /// RemoteSession.status == CONNECTING
  /// + RTCPeerConnectionState == connected
  /// + the `control` data channel is open
  /// + both features are talking about the same RemoteSession
  /// + no activation is in flight for it
  /// + none was already asked for in this readiness episode
  /// ```
  ///
  /// Each of the first two is deliberately insufficient on its own. A peer
  /// connection whose channel is still `connecting` cannot carry a single
  /// command, and a channel that opened while ICE is still settling is not a
  /// working assistance either — whichever callback happens to arrive first.
  ///
  /// Signaling is not part of the condition at all: joined, `peerJoined`, a
  /// delivered offer and a received answer are all steps towards a connection,
  /// not the connection. A socket that dropped afterwards changes nothing —
  /// WebRTC is peer to peer and `/activate` is REST.
  ///
  /// Known limitation of this stage: the transition is one way. If the peer
  /// connection fails after the backend has been told the assistance started —
  /// or while `/activate` is still unanswered — the session stays `ACTIVE`
  /// server side until somebody closes it. Nothing here reverts it, there is
  /// no heartbeat and no automatic close: deciding when a broken connection
  /// should end an assistance is a lifecycle policy, and it belongs to its own
  /// stage rather than to a silent rollback made from the client.
  void _activateIfEstablished() {
    final webRtc = _webRtcSessionBloc.state;
    if (!webRtc.isConnected || !webRtc.isControlChannelOpen) return;

    final sessionState = _remoteSessionBloc.state;
    // `CONNECTING` is the only activable status. An `ACTIVE` session is
    // already where the backend would put it, and asking again would be a
    // request made for nothing.
    if (sessionState is! RemoteSessionConnecting) return;
    if (sessionState.isActivating) return;

    final session = sessionState.session;
    // Readiness that is not about the assistance the console holds is not
    // readiness: an id is never adopted from the WebRTC layer either.
    if (session.id != webRtc.remoteSessionId) return;

    final activation = (session.id, _webRtcReadinessEpisode);
    if (_requestedActivation == activation) return;
    _requestedActivation = activation;

    _remoteSessionBloc.add(RemoteSessionActivationRequested(session.id));
  }

  /// Forgets what the activation guard was scoped to.
  void _forgetWebRtcReadiness() {
    _requestedActivation = null;
    _isWebRtcEstablished = false;
  }

  void _joinLiveSessionIfPossible() {
    final status = _technicianRealtimeBloc.state;
    final connectionId = status.connectionId;
    if (!status.isConnected || connectionId == null) return;

    final session = _remoteSessionBloc.state.session;
    if (session == null || !session.isLive) return;

    // The BLoC drops this when it is the same session over the same
    // connection, so repeated triggers cannot produce a second join.
    _signalingJoinBloc.add(
      SignalingJoinRequested(
        remoteSessionId: session.id,
        connectionId: connectionId,
      ),
    );
  }
}
