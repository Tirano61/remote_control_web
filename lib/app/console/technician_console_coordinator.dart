import 'dart:async';

import '../../core/error/failure.dart';
import '../../core/logging/debug_log.dart';
import '../../features/auth/presentation/bloc/user_session/user_session_bloc.dart';
import '../../features/devices/presentation/bloc/devices/devices_bloc.dart';
import '../../features/remote_control/domain/entities/remote_control_status.dart';
import '../../features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import '../../features/signaling/domain/client/technician_signaling_client.dart';
import '../../features/signaling/domain/entities/signaling_relay_result.dart';
import '../../features/support/presentation/bloc/support_requests/support_requests_bloc.dart';
import '../../features/technician_realtime/domain/client/technician_realtime_client.dart';
import '../../features/technician_realtime/domain/entities/device_presence_updated_notice.dart';
import '../../features/technician_realtime/domain/entities/remote_session_active_notice.dart';
import '../../features/technician_realtime/domain/entities/remote_session_closed_notice.dart';
import '../../features/technician_realtime/domain/entities/signaling_error_code.dart';
import '../../features/technician_realtime/domain/entities/support_request_queue_updated_notice.dart';
import '../../features/technician_realtime/domain/entities/support_request_updated_notice.dart';
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
/// socket reconnected                 -> GET /devices + GET /support-requests
///                                       + GET /remote-sessions/current (check)
/// socket lost                        -> remote control suspended, at once;
///                                       the join is no longer valid
/// joined + peer ready + live session -> negotiate WebRTC
/// joined without the peer            -> wait: an offer would reach nobody
/// signaling room lost                -> incomplete negotiations are dropped
/// live session gone                  -> the peer connection is released
/// CONNECTING + connected + control   -> POST /remote-sessions/:id/activate
/// ACTIVE, not closing, confirmed by a
///   read since the socket came back,
///   socket connected                 -> remote control may be used
/// another session replaces the held  -> the old peer connection is released
/// WebRTC failed, session still live  -> GET current, then one new offer,
///                                       on a bounded, spaced schedule
/// offer unanswered past its deadline -> the same, replacing only that
///                                       negotiation; a late answer still
///                                       counts while nothing replaced it
/// REINTENTAR on the connection       -> the same, with a fresh schedule
/// tap refused session_not_active     -> GET current (the tap is not resent)
/// remote-session:active              -> GET current (never the event as state)
/// remote-session:closed (held id)    -> remote control and WebRTC end at once,
///                                       the session ends, then GET current
/// remote-session:closed (other id)   -> GET current
/// join refused UNAUTHORIZED          -> GET current (once per connection)
/// support-request:updated            -> GET /support-requests (idem)
/// support-request:queue-updated      -> GET /support-requests (idem)
/// device:presence-updated            -> GET /devices + GET /support-requests
/// live session disappeared          -> reload the support request queue
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
    required DevicesBloc devicesBloc,
    required WebRtcSessionBloc webRtcSessionBloc,
    required TechnicianRealtimeClient realtimeClient,
    required TechnicianSignalingClient signalingClient,
    List<Duration> webRtcRecoveryDelays = defaultWebRtcRecoveryDelays,
  }) : assert(webRtcRecoveryDelays.isNotEmpty),
       _webRtcRecoveryDelays = webRtcRecoveryDelays,
       _userSessionBloc = userSessionBloc,
       _remoteSessionBloc = remoteSessionBloc,
       _technicianRealtimeBloc = technicianRealtimeBloc,
       _signalingJoinBloc = signalingJoinBloc,
       _supportRequestsBloc = supportRequestsBloc,
       _devicesBloc = devicesBloc,
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

  /// When each automatic WebRTC recovery attempt of a run of failures starts,
  /// counted from the failure — or the unanswered offer — that asks for it.
  ///
  /// One entry per attempt, so the list is also the budget. Spaced on purpose:
  /// on the T10A, with the browser's UDP blocked, every new peer connection
  /// failed 17–20 s after its offer, and two attempts in a row were spent —
  /// and the console gave up for good — half a minute before the network came
  /// back. Spread like this the attempts cover about two minutes of outage.
  ///
  /// Every attempt reads REST first, so one whose read fails is spent like
  /// any other and the next one reads again: a failed read never parks the
  /// recovery. The schedule starts over when a peer connection really works
  /// again, on a socket reconnection, for a new session, and on REINTENTAR.
  static const List<Duration> defaultWebRtcRecoveryDelays = [
    Duration.zero,
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  /// The number of automatic attempts in [defaultWebRtcRecoveryDelays].
  static const int maxAutomaticWebRtcRecoveriesPerSession = 4;

  final List<Duration> _webRtcRecoveryDelays;

  final UserSessionBloc _userSessionBloc;
  final RemoteSessionBloc _remoteSessionBloc;
  final TechnicianRealtimeBloc _technicianRealtimeBloc;
  final SignalingJoinBloc _signalingJoinBloc;
  final SupportRequestsBloc _supportRequestsBloc;
  final DevicesBloc _devicesBloc;
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

  /// The last socket connection seen while signed in, or `null` before the
  /// first one.
  ///
  /// Only used to tell a reconnection from the first handshake: events emitted
  /// while the socket was down are lost for good, so a reconnection re-reads
  /// the queue, while the first connection needs nothing — the console has
  /// just loaded it.
  int? _lastConnectionId;

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

  /// The last command whose `session_not_active` already asked REST for the
  /// truth.
  String? _reconciledCommandId;

  /// The (connection, session) a negotiation was already asked for.
  ///
  /// Readiness is re-evaluated on many triggers, and a negotiation that failed
  /// must not be restarted by the next one: only a genuinely new situation — a
  /// new socket or a new assistance — asks again. The BLoC additionally
  /// refuses to replace a peer connection that is still usable, so the two
  /// guards together make "one negotiation per readiness" true from both
  /// sides.
  (int, String)? _requestedNegotiation;

  /// Numbers the authority checks sent to the [RemoteSessionBloc]. Never reset,
  /// so a check of a previous connection can never answer a later one.
  int _authorityCheckCounter = 0;

  /// The check remote control waits for: a successful read that started after
  /// the socket last came back. Until the session state answers it, the
  /// session on screen is not taken as confirmed, whatever it says.
  int _requiredAuthorityCheck = 0;

  /// The live session the console last acted upon, to notice another one
  /// replacing it.
  String? _heldRemoteSessionId;

  /// WebRTC recovery: the session it is for, how many attempts of its
  /// schedule were used, the attempt waiting for its time, the check a
  /// renegotiation waits for, and whether the current failure — or unanswered
  /// offer — was already looked at.
  String? _webRtcRecoverySessionId;
  int _webRtcRecoveries = 0;
  Timer? _webRtcRecoveryTimer;
  int? _webRtcRecoveryCheck;
  bool _isWebRtcFailureSeen = false;
  bool _isUnansweredOfferSeen = false;

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
      ..add(
        _realtimeClient.supportRequestUpdated.listen(_onSupportRequestUpdated),
      )
      ..add(
        _realtimeClient.supportRequestQueueUpdated.listen(
          _onSupportRequestQueueUpdated,
        ),
      )
      ..add(
        _realtimeClient.devicePresenceUpdated.listen(_onDevicePresenceUpdated),
      )
      ..add(_signalingClient.relayRefusals.listen(_onRelayRefused))
      ..add(_webRtcSessionBloc.connectionRetries.listen(_onConnectionRetry));

    // The console is opened by an already authenticated session, so the
    // current state has to be acted upon and not only its future changes.
    _onUserSessionChanged(_userSessionBloc.state);
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _webRtcRecoveryTimer?.cancel();
    _webRtcRecoveryTimer = null;
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
    // A reload coalesced behind a GET in flight would otherwise run after the
    // sign out.
    _supportRequestsBloc.add(const SupportRequestsPendingRefreshDiscarded());
    _devicesBloc.add(const DevicesPendingRefreshDiscarded());
    _hadLiveSession = false;
    _lastConnectionId = null;
    _requestedNegotiation = null;
    _heldRemoteSessionId = null;
    _requiredAuthorityCheck = 0;
    _forgetWebRtcReadiness();
    _forgetWebRtcRecovery();
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
      final previousConnectionId = _lastConnectionId;
      _lastConnectionId = status.connectionId;
      if (previousConnectionId != null &&
          previousConnectionId != status.connectionId) {
        // Remote control stays suspended until REST says the session is still
        // this technician's. Required before the request even leaves, so
        // that no state already on screen can answer for it.
        _requestAuthorityCheck(requiredForControl: true);
        // A new socket is a genuinely new situation: whatever the recovery
        // had spent is given back, and the join below negotiates again.
        _restartWebRtcRecovery();
        // No notification is replayed: whatever the tablet answered, created
        // or cancelled while the socket was down — and every presence change
        // of every device, `device:presence-updated` included — is only known
        // to REST. Both collections are re-read, because both show presence.
        // The remote session is too: a `remote-session:closed` sent while the
        // socket was down — a `SYSTEM` close above all — is lost for good.
        _reconcilePresenceAndQueue();
      }
      _publishControlAuthority();
      _resetRelayGuards(connectionId: status.connectionId);
      _joinLiveSessionIfPossible();
      // Readiness is never carried over a reconnection: this socket has to be
      // told again, by its own join ACK or by `remote-session:peer-joined`.
      _negotiateWebRtcIfReady();
      return;
    }

    // First, before anything is awaited anywhere: without the socket the
    // console cannot hear a `remote-session:closed`, so it no longer knows the
    // session is still its own. Remote control is suspended — a finger still
    // down is lifted, whatever is pending is dropped — and comes back only
    // after a read made once the socket is back.
    _publishControlAuthority();
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

    final liveId = state.hasLiveSession ? state.session!.id : null;
    final heldId = _heldRemoteSessionId;
    if (heldId != null && liveId != null && heldId != liveId) {
      // REST answered with a different assistance than the one the console
      // held: the old one is over. Nothing of it is inherited — not its peer
      // connection, its channel, its pending commands nor its room — and the
      // new one goes through the usual join and negotiation.
      logDebug('remote session replaced $heldId -> $liveId');
      _signalingJoinBloc.add(const SignalingJoinReset());
      _webRtcSessionBloc.add(const WebRtcSessionTerminated());
      _requestedNegotiation = null;
      _requestedActivation = null;
      _forgetWebRtcRecovery();
    }
    _heldRemoteSessionId = liveId;

    // Remote control stops the moment the close is asked for, not when the
    // backend confirms it, and comes back only if that close fails.
    _publishControlAuthority();

    if (state.hasLiveSession) {
      _hadLiveSession = true;
      _continueWebRtcRecovery();
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
    _forgetWebRtcRecovery();

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

    // A join refused `UNAUTHORIZED` is how a session closed meanwhile — by the
    // tablet, or by the backend while this socket was away — looks from
    // signaling. REST says which; the budget keeps it to one read.
    if (state is SignalingUnavailable &&
        state.error == SignalingErrorCode.unauthorized) {
      _reconcileAfterRelayRefusal();
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
      // budget does not carry over, and neither does the recovery schedule: a
      // connection that really worked again ends the run of failures.
      _webRtcReadinessEpisode++;
      _restartWebRtcRecovery();
    }
    _isWebRtcEstablished = isEstablished;

    if (state is WebRtcFailed) {
      if (!_isWebRtcFailureSeen) {
        _isWebRtcFailureSeen = true;
        logDebug(
          'webrtc failed ${state.remoteSessionId} (${state.reason.name})',
        );
        _scheduleWebRtcRecovery(state.remoteSessionId);
      }
    } else {
      _isWebRtcFailureSeen = false;
    }

    // An offer nobody answered. Most often the user of the tablet is reading
    // Android's MediaProjection dialog, which nothing in the protocol says; the
    // same silence is a refused or a lost offer. Nothing is torn down for it:
    // the recovery reads REST first, waits its turn, and only then replaces
    // that negotiation — and a late answer, while it is still there, counts.
    if (state.isAnswerOverdue) {
      if (!_isUnansweredOfferSeen) {
        _isUnansweredOfferSeen = true;
        logDebug('webrtc offer unanswered ${state.remoteSessionId}');
        _scheduleWebRtcRecovery(state.remoteSessionId!);
      }
    } else {
      _isUnansweredOfferSeen = false;
    }

    _activateIfEstablished();
    _reconcileAfterCommandRefusal(state.remoteControl.lastCommand);
  }

  /// The tablet says this session is not `ACTIVE`, while the console believed it
  /// was. One of the two is behind and REST decides which: the command is not
  /// sent again, and the peer connection is left as it is.
  void _reconcileAfterCommandRefusal(RemoteCommandFeedback? command) {
    if (command == null ||
        command.outcome != RemoteCommandOutcome.sessionNotActive) {
      return;
    }
    // One command, one read: every other state change still carries this one.
    if (command.commandId == _reconciledCommandId) return;
    _reconciledCommandId = command.commandId;
    _remoteSessionBloc.add(const RemoteSessionRefreshRequested());
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

  /// `remote-session:closed` arrived over `/technicians`: the tablet closed
  /// the assistance (`DEVICE`) or the backend did (`SYSTEM`). Any other value
  /// means the same: the session is over.
  ///
  /// The backend emits it after the close committed, and a closed session never
  /// reopens. For the session the console holds it is therefore acted upon at
  /// once, before any REST answer: remote control is withdrawn — a finger still
  /// down is lifted, pending commands are dropped — and the peer connection, its
  /// data channel and the room are released. The session itself ends in the
  /// [RemoteSessionBloc], which also makes sure no read, in flight or not,
  /// brings it back. REST is read afterwards, as always.
  ///
  /// An event about any other id never touches the session on screen: its id
  /// is not adopted, and it only triggers that same read.
  void _onRemoteSessionClosed(RemoteSessionClosedNotice notice) {
    final held = _remoteSessionBloc.state.session;
    if (held != null && held.id == notice.remoteSessionId) {
      _webRtcSessionBloc
        ..add(const WebRtcRemoteSessionActivityChanged(null))
        ..add(const WebRtcSessionTerminated());
      _signalingJoinBloc.add(const SignalingJoinReset());
      _requestedNegotiation = null;
      _requestedActivation = null;
      _forgetWebRtcRecovery();
    }
    _remoteSessionBloc.add(
      RemoteSessionClosedReported(
        notice.remoteSessionId,
        endedBy: notice.endedBy,
      ),
    );
  }

  /// `support-request:updated` arrived over `/technicians`: the tablet
  /// accepted, rejected or cancelled a request assigned to this technician.
  void _onSupportRequestUpdated(SupportRequestUpdatedNotice notice) {
    // A console that is signing out has no queue worth a request, and no User
    // JWT to spend on one.
    if (_userSessionBloc.state is! UserSessionAuthenticated) return;

    // The event is a trigger, never the state: it carries no status, so no
    // row is looked up or rewritten here, and no assistance is started. The
    // whole queue is re-read, as documented, whatever id the event names;
    // the BLoC's in-flight guard is what keeps a burst from piling up GETs.
    _supportRequestsBloc.add(const SupportRequestsRefreshRequested());
  }

  /// `support-request:queue-updated` arrived over `/technicians`: the shared
  /// `WAITING` queue changed — a new request, one taken by a technician (this
  /// one or another), or one cancelled by the tablet before being taken.
  ///
  /// It is kept apart from [_onSupportRequestUpdated] on purpose: different
  /// audience, different meaning. Both answer with the same GET today.
  void _onSupportRequestQueueUpdated(SupportRequestQueueUpdatedNotice notice) {
    if (_userSessionBloc.state is! UserSessionAuthenticated) return;

    // No card is added, removed or moved from the event: REST says whether the
    // request is `WAITING`, `ASSIGNED` or `CANCELLED`. A burst — every console
    // hears every change — is coalesced by the BLoC's pending refresh.
    _supportRequestsBloc.add(const SupportRequestsRefreshRequested());
  }

  /// `device:presence-updated` arrived over `/technicians`: some device went
  /// `ONLINE` or `OFFLINE` — the event does not say which, on purpose.
  ///
  /// Presence is shown in two places, each with its own source of truth —
  /// `Device.isOnline` in the device list, `SupportRequest.device.isOnline` on
  /// every request card — so both are re-read, whichever section is on
  /// screen. Nothing is copied from one BLoC to the other and no row is
  /// touched from here: the `deviceId` is not even looked at, because the
  /// GETs answer for every device at once.
  void _onDevicePresenceUpdated(DevicePresenceUpdatedNotice notice) {
    if (_userSessionBloc.state is! UserSessionAuthenticated) return;
    _reconcilePresenceAndQueue();
  }

  /// `GET /devices` and `GET /support-requests`.
  ///
  /// A burst — several devices, or a tablet that bounced — is coalesced by
  /// each BLoC's pending refresh: one GET in flight plus at most one after
  /// it, and an event arriving during a GET is never lost.
  void _reconcilePresenceAndQueue() {
    _devicesBloc.add(const DevicesRefreshRequested());
    _supportRequestsBloc.add(const SupportRequestsRefreshRequested());
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
  void _negotiateWebRtcIfReady({bool replacesUnansweredOffer = false}) {
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

    _webRtcSessionBloc.add(
      WebRtcNegotiationRequested(
        session.id,
        replacesUnansweredOffer: replacesUnansweredOffer,
      ),
    );
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
  /// The transition is one way. If the peer connection fails after the backend
  /// has been told the assistance started, the session stays `ACTIVE` server
  /// side: the console renegotiates within its recovery budget, and if nobody
  /// takes part in the session any more the backend closes it on its own
  /// (`endedBy: SYSTEM`, after its grace period). Nothing here reverts it.
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

  /// Asks REST whether the session is still this technician's, with a
  /// receipt the session state reports once a read started afterwards
  /// succeeded. With [requiredForControl], remote control waits for it.
  int _requestAuthorityCheck({bool requiredForControl = false}) {
    final check = ++_authorityCheckCounter;
    if (requiredForControl) _requiredAuthorityCheck = check;
    _remoteSessionBloc.add(RemoteSessionAuthorityCheckRequested(check));
    return check;
  }

  /// Tells the WebRTC layer which session remote control may run on, if any.
  ///
  /// All of this has to hold, and is evaluated again on every change of any
  /// of it:
  ///
  /// ```text
  /// signed in
  /// + RemoteSession ACTIVE, and no close in flight
  /// + its last read succeeded (isVerified)
  /// + a read made after the socket last came back answered (authority check)
  /// + the /technicians socket is connected
  /// ```
  ///
  /// The socket is part of it because it is how the console hears
  /// `remote-session:closed`: without it, the backend may close the session —
  /// automatically, after its grace period — and the console would not know.
  /// The peer connection and its data channel are *not* part of it: they say
  /// the tablet can be reached, never that the technician may reach it.
  ///
  /// The WebRTC BLoC drops what it had pending the moment this becomes `null`,
  /// so a suspension takes effect at once and is never queued behind a REST
  /// call.
  void _publishControlAuthority() {
    final state = _remoteSessionBloc.state;
    final isAuthorized =
        _userSessionBloc.state is UserSessionAuthenticated &&
        state is RemoteSessionActive &&
        !state.isClosing &&
        state.isVerified &&
        state.answeredAuthorityCheck >= _requiredAuthorityCheck &&
        _technicianRealtimeBloc.state.isConnected;
    _webRtcSessionBloc.add(
      WebRtcRemoteSessionActivityChanged(
        isAuthorized ? state.session.id : null,
      ),
    );
  }

  /// Whether the negotiation of [remoteSessionId] still needs recovering: it
  /// failed, or its offer is unanswered. Anything else — a new negotiation
  /// started by a reconnection, a late answer, a close — means it does not.
  bool _needsWebRtcRecovery(String remoteSessionId) {
    final webRtc = _webRtcSessionBloc.state;
    if (webRtc.remoteSessionId != remoteSessionId) return false;
    return webRtc is WebRtcFailed || webRtc.isAnswerOverdue;
  }

  /// Plans the next recovery attempt for the session the console holds.
  ///
  /// Nothing is renegotiated on the spot: a failure is also what a session
  /// closed by the backend looks like from WebRTC, so every attempt reads REST
  /// first — see [_runWebRtcRecoveryAttempt]. One attempt at a time, each one
  /// at its place in [defaultWebRtcRecoveryDelays], and never more than there
  /// are places: exhausted, the console says so and waits for REINTENTAR or a
  /// genuinely new situation.
  void _scheduleWebRtcRecovery(String remoteSessionId) {
    final session = _remoteSessionBloc.state.session;
    if (session == null || !session.isLive || session.id != remoteSessionId) {
      return;
    }
    if (_webRtcRecoverySessionId != session.id) {
      _cancelWebRtcRecoveryAttempt();
      _webRtcRecoverySessionId = session.id;
      _webRtcRecoveries = 0;
    }
    // One attempt at a time: a failure reported while one is planned or
    // reading REST is what that attempt is already about.
    if (_webRtcRecoveryTimer != null || _webRtcRecoveryCheck != null) return;
    if (_webRtcRecoveries >= _webRtcRecoveryDelays.length) {
      logDebug('webrtc recovery budget exhausted ${session.id}');
      _publishWebRtcRecoveryScheduled(false);
      return;
    }
    final delay = _webRtcRecoveryDelays[_webRtcRecoveries];
    _webRtcRecoveries++;
    logDebug(
      'webrtc recovery $_webRtcRecoveries/${_webRtcRecoveryDelays.length} '
      'planned in ${delay.inMilliseconds} ms ${session.id}',
    );
    _publishWebRtcRecoveryScheduled(true);
    _webRtcRecoveryTimer = Timer(delay, _runWebRtcRecoveryAttempt);
  }

  /// The attempt's time came: REST is asked whether the session is still this
  /// technician's, with a receipt [_continueWebRtcRecovery] waits for.
  void _runWebRtcRecoveryAttempt() {
    _webRtcRecoveryTimer = null;
    if (!_isStarted) return;
    final sessionId = _webRtcRecoverySessionId;
    final session = _remoteSessionBloc.state.session;
    if (sessionId == null ||
        session == null ||
        !session.isLive ||
        session.id != sessionId ||
        !_needsWebRtcRecovery(sessionId)) {
      // Recovered, replaced or over meanwhile: nothing left to do.
      _publishWebRtcRecoveryScheduled(false);
      return;
    }
    logDebug('webrtc recovery checking the session $sessionId');
    _webRtcRecoveryCheck = _requestAuthorityCheck();
  }

  /// Renegotiates once REST confirmed the session the recovery is for.
  ///
  /// A new offer goes out only if, by then, all of this still holds: the
  /// session REST answered with is the one that failed, live, and read after
  /// the attempt started; the negotiation still needs it — a reconnection or a
  /// late answer may have settled it meanwhile — and the usual readiness of
  /// [_negotiateWebRtcIfReady] holds: socket, room and tablet. The WebRTC BLoC
  /// releases the old peer connection before making the new one, so there are
  /// never two, and it never reuses the old data channel.
  ///
  /// A read that fails spends the attempt, and the next one is planned: the
  /// network that broke the peer connection is often the one breaking REST.
  ///
  /// Whether the tablet can share its screen again without asking is the
  /// tablet's business: if Android needs a new MediaProjection consent, the
  /// user is asked there, and nothing here works around it.
  void _continueWebRtcRecovery() {
    final check = _webRtcRecoveryCheck;
    if (check == null) return;
    final state = _remoteSessionBloc.state;
    final session = state.session;
    final sessionId = _webRtcRecoverySessionId;
    if (session == null || !session.isLive || session.id != sessionId) {
      _webRtcRecoveryCheck = null;
      _publishWebRtcRecoveryScheduled(false);
      return;
    }
    if (state.failedAuthorityCheck >= check) {
      // The read failed. Not a confirmation, and not a reason to stop either.
      _webRtcRecoveryCheck = null;
      logDebug('webrtc recovery could not confirm the session $sessionId');
      if (_needsWebRtcRecovery(session.id)) {
        _scheduleWebRtcRecovery(session.id);
      } else {
        _publishWebRtcRecoveryScheduled(false);
      }
      return;
    }
    // Not answered yet: keep waiting for the read that carries the receipt.
    if (!state.isVerified || state.answeredAuthorityCheck < check) return;
    _webRtcRecoveryCheck = null;
    final webRtc = _webRtcSessionBloc.state;
    if (!_needsWebRtcRecovery(session.id)) {
      _publishWebRtcRecoveryScheduled(false);
      return;
    }
    logDebug('webrtc recovery ${session.id}');
    _publishWebRtcRecoveryScheduled(false);
    _requestedNegotiation = null;
    _negotiateWebRtcIfReady(
      replacesUnansweredOffer:
          webRtc is! WebRtcFailed && webRtc.isAnswerOverdue,
    );
  }

  /// REINTENTAR on the connection: a fresh schedule, starting now. It still
  /// goes through REST like every other attempt.
  void _onConnectionRetry(String remoteSessionId) {
    final session = _remoteSessionBloc.state.session;
    if (session == null || !session.isLive || session.id != remoteSessionId) {
      return;
    }
    if (_webRtcRecoveryCheck != null) return;
    _restartWebRtcRecovery();
    _webRtcRecoverySessionId = session.id;
    _scheduleWebRtcRecovery(session.id);
  }

  /// Gives the schedule back: nothing planned, nothing spent. A check already
  /// in flight still completes and is judged then.
  void _restartWebRtcRecovery() {
    _cancelWebRtcRecoveryAttempt();
    _webRtcRecoveries = 0;
  }

  void _cancelWebRtcRecoveryAttempt() {
    final timer = _webRtcRecoveryTimer;
    if (timer == null) return;
    timer.cancel();
    _webRtcRecoveryTimer = null;
    _publishWebRtcRecoveryScheduled(false);
  }

  void _publishWebRtcRecoveryScheduled(bool isScheduled) {
    _webRtcSessionBloc.add(
      WebRtcAutomaticRecoveryChanged(isScheduled: isScheduled),
    );
  }

  void _forgetWebRtcRecovery() {
    _cancelWebRtcRecoveryAttempt();
    _webRtcRecoverySessionId = null;
    _webRtcRecoveries = 0;
    _webRtcRecoveryCheck = null;
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
