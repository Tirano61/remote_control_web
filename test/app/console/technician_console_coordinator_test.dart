import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/app/console/technician_console_coordinator.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/auth/domain/usecases/log_out.dart';
import 'package:remote_control_web/features/auth/domain/usecases/restore_session.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/auth/presentation/bloc/user_session/user_session_bloc.dart';
import 'package:remote_control_web/features/remote_session/data/repositories/remote_session_repository_impl.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/activate_remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/create_remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_web/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_web/features/signaling/data/technician_signaling_client_impl.dart';
import 'package:remote_control_web/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_web/features/signaling/domain/entities/webrtc_session_description.dart';
import 'package:remote_control_web/features/support/domain/entities/support_request.dart';
import 'package:remote_control_web/features/support/domain/entities/support_request_status.dart';
import 'package:remote_control_web/features/support/domain/usecases/assign_support_request.dart';
import 'package:remote_control_web/features/support/domain/usecases/load_support_requests.dart';
import 'package:remote_control_web/features/support/presentation/bloc/support_requests/support_requests_bloc.dart';
import 'package:remote_control_web/features/technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import 'package:remote_control_web/features/technician_realtime/presentation/bloc/technician_realtime/technician_realtime_bloc.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_web/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../support/auth_test_doubles.dart';
import '../../support/console_test_doubles.dart';
import '../../support/realtime_test_doubles.dart';
import '../../support/remote_session_test_doubles.dart';
import '../../support/webrtc_test_doubles.dart';

/// Lets the event loop drain, so the BLoCs process everything the coordinator
/// dispatched. Several rules chain across BLoCs, hence more than one turn.
Future<void> settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late FakeAuthRemoteDataSource auth;
  late InMemoryUserTokenStorage storage;
  late FakeRemoteSessionRepository remoteSessions;
  late FakeSupportRequestRepository supportRequests;
  late FakeTechnicianRealtimeClient realtime;
  late TechnicianSignalingClientImpl signaling;
  late FakeWebRtcPeerClient peers;

  late UserSessionBloc userSessionBloc;
  late RemoteSessionBloc remoteSessionBloc;
  late TechnicianRealtimeBloc realtimeBloc;
  late SignalingJoinBloc signalingJoinBloc;
  late SupportRequestsBloc supportRequestsBloc;
  late WebRtcSessionBloc webRtcSessionBloc;
  late TechnicianConsoleCoordinator coordinator;

  setUp(() {
    auth = FakeAuthRemoteDataSource()..checkStatusResponse = technicianSession;
    storage = InMemoryUserTokenStorage()..token = 'stored-user-jwt';
    remoteSessions = FakeRemoteSessionRepository();
    supportRequests = FakeSupportRequestRepository();
    realtime = FakeTechnicianRealtimeClient();
    // The real signaling client over the fake transport: the coordinator rules
    // are exercised through actual relay acknowledgements, not a script.
    signaling = TechnicianSignalingClientImpl(
      transport: realtime,
      ackTimeout: const Duration(milliseconds: 50),
    );
    peers = FakeWebRtcPeerClient();

    final authRepository = AuthRepositoryImpl(
      remoteDataSource: auth,
      tokenStorage: storage,
    );

    userSessionBloc = UserSessionBloc(
      restoreSession: RestoreSession(repository: authRepository),
      logOut: LogOut(repository: authRepository),
    );
    remoteSessionBloc = RemoteSessionBloc(
      loadCurrentRemoteSession: LoadCurrentRemoteSession(
        repository: remoteSessions,
      ),
      createRemoteSession: CreateRemoteSession(repository: remoteSessions),
      activateRemoteSession: ActivateRemoteSession(repository: remoteSessions),
      closeRemoteSession: CloseRemoteSession(repository: remoteSessions),
    );
    realtimeBloc = TechnicianRealtimeBloc(client: realtime);
    signalingJoinBloc = SignalingJoinBloc(client: realtime);
    supportRequestsBloc = SupportRequestsBloc(
      loadSupportRequests: LoadSupportRequests(repository: supportRequests),
      assignSupportRequest: AssignSupportRequest(repository: supportRequests),
    );
    // The real negotiation logic over a fake peer client: no browser, but the
    // readiness rules are exercised exactly as they run in production.
    webRtcSessionBloc = WebRtcSessionBloc(
      peerClient: peers,
      signalingClient: signaling,
      iceConfiguration: const WebRtcIceConfiguration(),
    );

    coordinator = TechnicianConsoleCoordinator(
      userSessionBloc: userSessionBloc,
      remoteSessionBloc: remoteSessionBloc,
      technicianRealtimeBloc: realtimeBloc,
      signalingJoinBloc: signalingJoinBloc,
      supportRequestsBloc: supportRequestsBloc,
      webRtcSessionBloc: webRtcSessionBloc,
      realtimeClient: realtime,
      signalingClient: signaling,
    );
  });

  tearDown(() async {
    await coordinator.dispose();
    await Future.wait([
      userSessionBloc.close(),
      remoteSessionBloc.close(),
      realtimeBloc.close(),
      signalingJoinBloc.close(),
      supportRequestsBloc.close(),
      webRtcSessionBloc.close(),
    ]);
    await signaling.dispose();
    await realtime.dispose();
  });

  /// Starts the console with an authenticated technician.
  Future<void> signIn() async {
    userSessionBloc.add(UserSessionSignedIn(technicianSession));
    await settle();
    coordinator.start();
    await settle();
  }

  group('user session', () {
    test('an authenticated user connects and reads the current session', () async {
      await signIn();

      expect(realtime.connectCount, 1);
      expect(remoteSessions.currentCount, 1);
    });

    test('signing out disconnects and forgets the session', () async {
      remoteSessions.current = buildRemoteSession();
      await signIn();
      realtime.emitConnected();
      await settle();
      expect(remoteSessionBloc.state.hasLiveSession, isTrue);

      userSessionBloc.add(const UserSessionSignOutRequested());
      await settle();

      expect(realtime.disconnectCount, 1);
      expect(remoteSessionBloc.state, isA<RemoteSessionInitial>());
      expect(signalingJoinBloc.state, isA<SignalingIdle>());
    });

    test('a rejected handshake ends the user session', () async {
      await signIn();

      realtime.emitAuthenticationError();
      await settle();

      expect(userSessionBloc.state, isA<UserSessionUnauthenticated>());
      expect(
        (userSessionBloc.state as UserSessionUnauthenticated).notice,
        kRealtimeSessionRejectedNotice,
      );
      // The stored User JWT is gone: there is no refresh token.
      expect(storage.token, isNull);
    });

    test('a transport failure never signs the user out', () async {
      await signIn();

      realtime.emitNetworkError();
      realtime.emitReconnecting();
      await settle();

      expect(userSessionBloc.state, isA<UserSessionAuthenticated>());
      expect(storage.token, isNotNull);
    });

    test('a 401 from REST ends the user session too', () async {
      remoteSessions.currentFailure = const AuthFailure();
      await signIn();

      expect(userSessionBloc.state, isA<UserSessionUnauthenticated>());
    });
  });

  group('remote-session:join', () {
    test('a CONNECTING session is joined once the socket is up', () async {
      remoteSessions.current = buildRemoteSession();
      await signIn();

      realtime.emitConnected();
      await settle();

      expect(realtime.joinedSessionIds, [remoteSessionId]);
      expect(signalingJoinBloc.state, isA<SignalingJoined>());
    });

    test('an ACTIVE session is joined as well', () async {
      remoteSessions.current = buildRemoteSession(
        status: RemoteSessionStatus.active,
      );
      await signIn();

      realtime.emitConnected();
      await settle();

      expect(realtime.joinedSessionIds, [remoteSessionId]);
    });

    test('a session created later is joined without a new connection', () async {
      await signIn();
      realtime.emitConnected();
      await settle();
      expect(realtime.joinedSessionIds, isEmpty);

      remoteSessionBloc.add(const RemoteSessionCreateRequested(requestId));
      await settle();

      expect(realtime.joinedSessionIds, [remoteSessionId]);
    });

    test('no live session means no join at all', () async {
      remoteSessions.current = null;
      await signIn();

      realtime.emitConnected();
      await settle();

      expect(realtime.joinedSessionIds, isEmpty);
      expect(signalingJoinBloc.state, isA<SignalingIdle>());
    });

    test('a connected socket alone is not a joined session', () async {
      remoteSessions.current = null;
      await signIn();
      realtime.emitConnected();
      await settle();

      // The two facts are separate on purpose.
      expect(realtimeBloc.state.isConnected, isTrue);
      expect(signalingJoinBloc.state.isJoined, isFalse);
    });

    test('refreshing the same session does not join twice', () async {
      remoteSessions.current = buildRemoteSession();
      await signIn();
      realtime.emitConnected();
      await settle();
      expect(realtime.joinedSessionIds, hasLength(1));

      remoteSessionBloc.add(const RemoteSessionRefreshRequested());
      await settle();
      remoteSessionBloc.add(const RemoteSessionRefreshRequested());
      await settle();

      expect(realtime.joinedSessionIds, hasLength(1));
    });

    test('a reconnection joins the session again', () async {
      remoteSessions.current = buildRemoteSession();
      await signIn();
      realtime.emitConnected();
      await settle();
      expect(realtime.joinedSessionIds, hasLength(1));

      // Rooms die with the connection.
      realtime.emitReconnecting();
      await settle();
      expect(signalingJoinBloc.state, isA<SignalingIdle>());

      realtime.emitConnected();
      await settle();

      expect(realtime.joinedSessionIds, [remoteSessionId, remoteSessionId]);
      expect(signalingJoinBloc.state, isA<SignalingJoined>());
    });
  });

  group('WebRTC readiness', () {
    /// A console with a live, joined session. [peerAlreadyJoined] is what the
    /// join ACK reports.
    Future<void> signInWithLiveSession({
      bool peerAlreadyJoined = false,
    }) async {
      remoteSessions.current = buildRemoteSession();
      supportRequests.requests = [buildSupportRequest()];
      realtime.peerJoinedOnJoin = peerAlreadyJoined;
      await signIn();
      realtime.emitConnected();
      await settle();
      expect(signalingJoinBloc.state, isA<SignalingJoined>());
    }

    /// The backend relayed the offer.
    Future<void> deliverOffer() async {
      realtime.answerRelayAck({
        'delivered': true,
        'remoteSessionId': remoteSessionId,
      });
      await settle();
    }

    Iterable<String> relayedEvents() =>
        realtime.emittedSignaling.map((emission) => emission.event);

    test('being joined is not enough to start negotiating', () async {
      await signInWithLiveSession();

      // The room is joined but the tablet is not in it: an offer would be
      // relayed to nobody.
      expect((signalingJoinBloc.state as SignalingJoined).peerJoined, isFalse);
      expect(peers.sessions, isEmpty);
      expect(realtime.emittedSignaling, isEmpty);
    });

    test('remote-session:peer-joined is what starts it', () async {
      await signInWithLiveSession();

      realtime.emitPeerJoined(remoteSessionId);
      await settle();

      expect(peers.sessions, hasLength(1));
      expect(peers.last.remoteSessionId, remoteSessionId);
      expect(relayedEvents(), ['webrtc:offer']);
    });

    test('an ACK that already reports the tablet needs no event', () async {
      await signInWithLiveSession(peerAlreadyJoined: true);

      expect(peers.sessions, hasLength(1));
      expect(relayedEvents(), ['webrtc:offer']);
    });

    test('repeated readiness never produces a second negotiation', () async {
      await signInWithLiveSession(peerAlreadyJoined: true);
      await deliverOffer();

      realtime
        ..emitPeerJoined(remoteSessionId)
        ..emitPeerJoined(remoteSessionId);
      remoteSessionBloc.add(const RemoteSessionRefreshRequested());
      await settle();

      expect(peers.sessions, hasLength(1));
      expect(
        relayedEvents().where((event) => event == 'webrtc:offer'),
        hasLength(1),
      );
    });

    test('readiness for another session negotiates nothing', () async {
      await signInWithLiveSession();

      realtime.emitPeerJoined('a-different-session');
      await settle();

      expect(peers.sessions, isEmpty);
    });

    test('a socket that drops keeps a connected peer connection', () async {
      await signInWithLiveSession(peerAlreadyJoined: true);
      await deliverOffer();
      peers.last.emitPeerState(WebRtcPeerConnectionState.connected);
      await settle();
      expect(webRtcSessionBloc.state, isA<WebRtcConnected>());

      realtime.emitReconnecting();
      await settle();

      // WebRTC is peer to peer: signaling is not in the path any more.
      expect(peers.last.isClosed, isFalse);
      expect(webRtcSessionBloc.state, isA<WebRtcConnected>());

      // Reconnected, rejoined, the tablet still there: no second offer.
      realtime.emitConnected();
      await settle();

      expect(peers.sessions, hasLength(1));
      expect(
        relayedEvents().where((event) => event == 'webrtc:offer'),
        hasLength(1),
      );
    });

    test('an incomplete negotiation is dropped when the socket drops', () async {
      await signInWithLiveSession(peerAlreadyJoined: true);
      await deliverOffer();
      expect(peers.sessions, hasLength(1));

      realtime.emitReconnecting();
      await settle();

      expect(peers.last.isClosed, isTrue);
      expect(webRtcSessionBloc.state, isA<WebRtcIdle>());
    });

    test('an assistance closed by the tablet releases everything', () async {
      await signInWithLiveSession(peerAlreadyJoined: true);
      await deliverOffer();

      remoteSessions.current = null;
      realtime.emitRemoteSessionClosed(remoteSessionId);
      await settle();

      expect(peers.last.isClosed, isTrue);
      expect(webRtcSessionBloc.state, isA<WebRtcIdle>());
    });

    test('signing out releases everything too', () async {
      await signInWithLiveSession(peerAlreadyJoined: true);
      await deliverOffer();

      userSessionBloc.add(const UserSessionSignOutRequested());
      await settle();

      expect(peers.last.isClosed, isTrue);
      expect(webRtcSessionBloc.state, isA<WebRtcIdle>());
    });
  });

  group('RemoteSession activation', () {
    /// A console with a live `CONNECTING` session and a negotiation under way:
    /// socket up, room joined, tablet inside, offer relayed.
    Future<void> signInNegotiating() async {
      remoteSessions.current = buildRemoteSession();
      supportRequests.requests = [buildSupportRequest()];
      realtime.peerJoinedOnJoin = true;
      await signIn();
      realtime.emitConnected();
      await settle();
      realtime.answerRelayAck({
        'delivered': true,
        'remoteSessionId': remoteSessionId,
      });
      await settle();
      expect(peers.sessions, hasLength(1));
    }

    /// The peers reached each other and the control channel is usable.
    Future<void> establishWebRtc() async {
      peers.last
        ..emitPeerState(WebRtcPeerConnectionState.connected)
        ..emitControlChannelState(WebRtcDataChannelState.open);
      await settle();
    }

    test('a negotiating session is not activated', () async {
      await signInNegotiating();

      // Joined, peer ready, offer delivered: none of that is a connection.
      expect(webRtcSessionBloc.state.isConnected, isFalse);
      expect(remoteSessions.activatedIds, isEmpty);
      expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
    });

    test('a connected peer with a channel still opening is not enough', () async {
      await signInNegotiating();

      peers.last
        ..emitControlChannelState(WebRtcDataChannelState.connecting)
        ..emitPeerState(WebRtcPeerConnectionState.connected);
      await settle();

      expect(webRtcSessionBloc.state, isA<WebRtcConnected>());
      expect(webRtcSessionBloc.state.isControlChannelOpen, isFalse);
      expect(remoteSessions.activatedIds, isEmpty);
    });

    test('an open channel without a connected peer is not enough', () async {
      await signInNegotiating();

      // The data channel can report `open` while ICE is still settling.
      peers.last.emitControlChannelState(WebRtcDataChannelState.open);
      await settle();

      expect(webRtcSessionBloc.state.isControlChannelOpen, isTrue);
      expect(webRtcSessionBloc.state.isConnected, isFalse);
      expect(remoteSessions.activatedIds, isEmpty);
    });

    test('both conditions together activate exactly once', () async {
      await signInNegotiating();

      await establishWebRtc();

      expect(remoteSessions.activatedIds, [remoteSessionId]);
      expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
      expect(remoteSessionBloc.state.session!.connectedAt, isNotNull);
    });

    test('the channel opening last activates just as well', () async {
      await signInNegotiating();

      peers.last.emitPeerState(WebRtcPeerConnectionState.connected);
      await settle();
      expect(remoteSessions.activatedIds, isEmpty);

      peers.last.emitControlChannelState(WebRtcDataChannelState.open);
      await settle();

      expect(remoteSessions.activatedIds, [remoteSessionId]);
    });

    test('repeated events and refreshes never activate twice', () async {
      await signInNegotiating();
      await establishWebRtc();

      peers.last
        ..emitPeerState(WebRtcPeerConnectionState.connected)
        ..emitPeerState(WebRtcPeerConnectionState.connected)
        ..emitControlChannelState(WebRtcDataChannelState.open)
        ..emitControlChannelState(WebRtcDataChannelState.open);
      remoteSessionBloc.add(const RemoteSessionRefreshRequested());
      realtime.emitPeerJoined(remoteSessionId);
      await settle();

      expect(remoteSessions.activatedIds, [remoteSessionId]);
    });

    test('a session already ACTIVE is never activated', () async {
      remoteSessions.current = buildRemoteSession(
        status: RemoteSessionStatus.active,
        connectedAt: DateTime.utc(2026, 3, 11, 9, 35, 12),
      );
      realtime.peerJoinedOnJoin = true;
      await signIn();
      realtime.emitConnected();
      await settle();
      realtime.answerRelayAck({
        'delivered': true,
        'remoteSessionId': remoteSessionId,
      });
      await settle();

      await establishWebRtc();

      expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
      expect(remoteSessions.activatedIds, isEmpty);
    });

    test('REST decides the state, not the activate response', () async {
      await signInNegotiating();
      final readsBefore = remoteSessions.currentCount;

      await establishWebRtc();

      // POST /activate, then GET /remote-sessions/current.
      expect(remoteSessions.activatedIds, [remoteSessionId]);
      expect(remoteSessions.currentCount, readsBefore + 1);
      expect(remoteSessionBloc.state.session!.status,
          RemoteSessionStatus.active);
    });

    test('a 409 is reconciled with REST', () async {
      await signInNegotiating();
      remoteSessions
        ..activateFailure = const ConflictFailure(kActivateConflictMessage)
        // Closed concurrently by the tablet while the peers were connecting.
        ..current = null;

      await establishWebRtc();

      expect(remoteSessions.activatedIds, [remoteSessionId]);
      // No fictional CONNECTING session survives.
      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(remoteSessionBloc.state.hasLiveSession, isFalse);
    });

    test('a network failure preserves the peer connection', () async {
      await signInNegotiating();
      remoteSessions.activateFailure = const NetworkFailure();

      await establishWebRtc();

      expect(remoteSessions.activatedIds, [remoteSessionId]);
      // P2P is untouched: WebRTC does not care that one REST call failed.
      expect(peers.last.isClosed, isFalse);
      expect(webRtcSessionBloc.state, isA<WebRtcConnected>());
      expect(webRtcSessionBloc.state.isControlChannelOpen, isTrue);
      // And the assistance is still the one the backend gave us.
      expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
      expect(remoteSessionBloc.state.session!.id, remoteSessionId);
      expect(remoteSessionBloc.state.canRetryActivation, isTrue);
    });

    test('a failed activation is not retried by the next state change', () async {
      await signInNegotiating();
      remoteSessions.activateFailure = const NetworkFailure();
      await establishWebRtc();
      expect(remoteSessions.activatedIds, hasLength(1));

      // Everything that would re-evaluate readiness: no retry loop.
      remoteSessionBloc.add(const RemoteSessionRefreshRequested());
      realtime.emitPeerJoined(remoteSessionId);
      peers.last.emitPeerState(WebRtcPeerConnectionState.connected);
      await settle();

      expect(remoteSessions.activatedIds, hasLength(1));
    });

    test('a peer connection that comes back gets a new attempt', () async {
      await signInNegotiating();
      remoteSessions.activateFailure = const NetworkFailure();
      await establishWebRtc();
      expect(remoteSessions.activatedIds, hasLength(1));

      // The connection blinked and recovered: a genuinely new episode.
      peers.last.emitPeerState(WebRtcPeerConnectionState.disconnected);
      await settle();
      remoteSessions.activateFailure = null;
      peers.last.emitPeerState(WebRtcPeerConnectionState.connected);
      await settle();

      expect(remoteSessions.activatedIds, hasLength(2));
      expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
    });

    test('a 401 ends the user session', () async {
      await signInNegotiating();
      remoteSessions.activateFailure = const AuthFailure();

      await establishWebRtc();

      expect(userSessionBloc.state, isA<UserSessionUnauthenticated>());
      expect(realtime.disconnectCount, 1);
    });

    test('a socket that dropped does not prevent the activation', () async {
      await signInNegotiating();
      peers.last.emitPeerState(WebRtcPeerConnectionState.connected);
      await settle();

      // Signaling is gone, the peers are not: /activate is REST.
      realtime.emitReconnecting();
      await settle();
      peers.last.emitControlChannelState(WebRtcDataChannelState.open);
      await settle();

      expect(peers.last.isClosed, isFalse);
      expect(remoteSessions.activatedIds, [remoteSessionId]);
    });

    test('an assistance that ends forgets the activation guard', () async {
      await signInNegotiating();
      await establishWebRtc();
      expect(remoteSessions.activatedIds, hasLength(1));

      remoteSessions.current = null;
      realtime.emitRemoteSessionClosed(remoteSessionId);
      await settle();

      expect(remoteSessionBloc.state.hasLiveSession, isFalse);
      expect(peers.last.isClosed, isTrue);
      // Nothing was activated on the way out.
      expect(remoteSessions.activatedIds, hasLength(1));
    });
  });

  group('remote-session:active', () {
    Future<void> signInWithConnectingSession() async {
      remoteSessions.current = buildRemoteSession();
      await signIn();
      realtime.emitConnected();
      await settle();
    }

    test('triggers a REST reconciliation instead of mutating the state', () async {
      await signInWithConnectingSession();
      expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
      final readsBefore = remoteSessions.currentCount;

      // What the backend really has when it emits the event.
      remoteSessions.current = buildRemoteSession(
        status: RemoteSessionStatus.active,
        connectedAt: DateTime.utc(2026, 3, 11, 9, 35, 12),
      );
      realtime.emitRemoteSessionActive(remoteSessionId);
      await settle();

      expect(remoteSessions.currentCount, readsBefore + 1);
      expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
      expect(remoteSessionBloc.state.session!.connectedAt, isNotNull);
    });

    test('the event alone never promotes the session', () async {
      await signInWithConnectingSession();

      // The backend still answers CONNECTING — the event is not the state.
      realtime.emitRemoteSessionActive(remoteSessionId);
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
      expect(remoteSessionBloc.state.session!.connectedAt, isNull);
    });

    test('an event for another session is ignored', () async {
      await signInWithConnectingSession();
      final readsBefore = remoteSessions.currentCount;

      realtime.emitRemoteSessionActive('another-session');
      await settle();

      // Its id is never adopted, and nothing is re-read for it.
      expect(remoteSessions.currentCount, readsBefore);
      expect(remoteSessionBloc.state.session!.id, remoteSessionId);
    });

    test('the echo of our own activation costs no extra request', () async {
      remoteSessions.current = buildRemoteSession();
      realtime.peerJoinedOnJoin = true;
      await signIn();
      realtime.emitConnected();
      await settle();
      realtime.answerRelayAck({
        'delivered': true,
        'remoteSessionId': remoteSessionId,
      });
      await settle();

      final gate = Completer<void>();
      remoteSessions.activateGate = gate.future;
      peers.last
        ..emitPeerState(WebRtcPeerConnectionState.connected)
        ..emitControlChannelState(WebRtcDataChannelState.open);
      await settle();
      final readsBefore = remoteSessions.currentCount;

      // The backend emits the event to us as well, while our POST is still
      // unanswered. Its own response already ends in a GET current.
      realtime.emitRemoteSessionActive(remoteSessionId);
      await settle();
      expect(remoteSessions.currentCount, readsBefore);

      gate.complete();
      await settle();

      expect(remoteSessions.currentCount, readsBefore + 1);
      expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
    });

    test('an already ACTIVE session is not re-read', () async {
      remoteSessions.current = buildRemoteSession(
        status: RemoteSessionStatus.active,
        connectedAt: DateTime.utc(2026, 3, 11, 9, 35, 12),
      );
      await signIn();
      realtime.emitConnected();
      await settle();
      final readsBefore = remoteSessions.currentCount;

      realtime.emitRemoteSessionActive(remoteSessionId);
      await settle();

      expect(remoteSessions.currentCount, readsBefore);
    });
  });

  group('remote-session:closed', () {
    test('triggers a REST reconciliation and refreshes the queue', () async {
      remoteSessions.current = buildRemoteSession();
      supportRequests.requests = [buildSupportRequest()];
      await signIn();
      realtime.emitConnected();
      await settle();
      final readsBefore = remoteSessions.currentCount;
      final queueLoadsBefore = supportRequests.loadCount;

      // The tablet ended the assistance.
      remoteSessions.current = null;
      realtime.emitRemoteSessionClosed(remoteSessionId);
      await settle();

      expect(remoteSessions.currentCount, readsBefore + 1);
      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(supportRequests.loadCount, queueLoadsBefore + 1);
      expect(signalingJoinBloc.state, isA<SignalingIdle>());
    });

    test('an event for another session never closes the current one', () async {
      remoteSessions.current = buildRemoteSession();
      await signIn();
      realtime.emitConnected();
      await settle();

      // Whatever the id is, the state comes from REST — and REST still has a
      // live session.
      realtime.emitRemoteSessionClosed('a-different-session');
      await settle();

      expect(remoteSessionBloc.state.hasLiveSession, isTrue);
      expect(remoteSessionBloc.state.session!.id, remoteSessionId);
    });
  });

  group('support-request:updated', () {
    final assigned = buildSupportRequest(
      status: SupportRequestStatus.assigned,
      technician: technicianId,
    );

    /// The console after TOMAR SOLICITUD: the request is `ASSIGNED` to this
    /// technician, the queue is loaded and the socket is up. [afterwards] is
    /// what `GET /support-requests` answers from then on.
    Future<void> signInWithAssignedRequest({
      List<SupportRequest>? afterwards,
    }) async {
      remoteSessions.current = null;
      supportRequests
        ..requests = [assigned]
        ..requestsAfterFirstLoad = afterwards;
      await signIn();
      realtime.emitConnected();
      supportRequestsBloc.add(const SupportRequestsRequested());
      await settle();
    }

    SupportRequestsLoaded queue() =>
        supportRequestsBloc.state as SupportRequestsLoaded;

    for (final (status, closedAt) in [
      (SupportRequestStatus.accepted, null),
      (SupportRequestStatus.rejected, DateTime.utc(2026, 3, 11, 9, 32)),
      (SupportRequestStatus.cancelled, DateTime.utc(2026, 3, 11, 9, 32)),
    ]) {
      test('${status.wireValue} is read from GET /support-requests', () async {
        await signInWithAssignedRequest(
          afterwards: [
            buildSupportRequest(
              status: status,
              technician: technicianId,
              closedAt: closedAt,
            ),
          ],
        );
        final loadsBefore = supportRequests.loadCount;

        realtime.emitSupportRequestUpdated(requestId);
        await settle();

        expect(supportRequests.loadCount, loadsBefore + 1);
        expect(queue().requests.single.status, status);
        expect(queue().isRefreshing, isFalse);
        // A trigger for the queue and nothing else: no assistance is started
        // and no signaling or WebRTC is touched.
        expect(remoteSessions.createdSupportRequestIds, isEmpty);
        expect(realtime.joinedSessionIds, isEmpty);
        expect(peers.sessions, isEmpty);
      });
    }

    test('the event alone never changes the request', () async {
      await signInWithAssignedRequest(
        afterwards: [
          buildSupportRequest(
            status: SupportRequestStatus.accepted,
            technician: technicianId,
          ),
        ],
      );
      final gate = Completer<void>();
      supportRequests.loadGate = gate.future;

      realtime.emitSupportRequestUpdated(requestId);
      await settle();

      // REST has not answered yet, so nothing moved.
      expect(queue().isRefreshing, isTrue);
      expect(queue().requests.single.status, SupportRequestStatus.assigned);

      gate.complete();
      await settle();

      expect(queue().requests.single.status, SupportRequestStatus.accepted);
    });

    test('REST decides even when it disagrees with the event', () async {
      // The backend still answers ASSIGNED: the console shows ASSIGNED.
      await signInWithAssignedRequest();

      realtime.emitSupportRequestUpdated(requestId);
      await settle();

      expect(queue().requests.single.status, SupportRequestStatus.assigned);
    });

    test('any valid id refreshes the whole queue', () async {
      await signInWithAssignedRequest();
      final loadsBefore = supportRequests.loadCount;

      realtime.emitSupportRequestUpdated('a-request-not-on-screen');
      await settle();

      expect(supportRequests.loadCount, loadsBefore + 1);
      // Its id is not adopted as a row.
      expect(queue().requests.map((r) => r.id), [requestId]);
    });

    test('a burst during a refresh in flight stays consistent', () async {
      await signInWithAssignedRequest(
        afterwards: [
          buildSupportRequest(
            status: SupportRequestStatus.accepted,
            technician: technicianId,
          ),
        ],
      );
      final loadsBefore = supportRequests.loadCount;
      final gate = Completer<void>();
      supportRequests.loadGate = gate.future;

      realtime
        ..emitSupportRequestUpdated(requestId)
        ..emitSupportRequestUpdated(requestId);
      supportRequestsBloc.add(const SupportRequestsRefreshRequested());
      await settle();

      // No GET next to the one in flight...
      expect(supportRequests.loadCount, loadsBefore + 1);

      gate.complete();
      supportRequests.loadGate = null;
      await settle();

      // ...and the whole burst is answered by a single follow-up GET.
      expect(supportRequests.loadCount, loadsBefore + 2);
      expect(queue().requests.single.status, SupportRequestStatus.accepted);
      expect(queue().isRefreshing, isFalse);
      expect(queue().failure, isNull);

      // A later event is served again, and nothing loops on its own.
      realtime.emitSupportRequestUpdated(requestId);
      await settle();
      expect(supportRequests.loadCount, loadsBefore + 3);
      await settle();
      expect(supportRequests.loadCount, loadsBefore + 3);
    });

    test('an event during a GET that read ASSIGNED is not lost', () async {
      await signInWithAssignedRequest();
      final loadsBefore = supportRequests.loadCount;
      final gate = Completer<void>();
      supportRequests.loadGate = gate.future;

      // GET #1 is out — the technician pressed ACTUALIZAR — and reads ASSIGNED.
      supportRequestsBloc.add(const SupportRequestsRefreshRequested());
      await settle();

      // The tablet accepts: commit, then the event, while GET #1 travels.
      supportRequests.requests = [
        buildSupportRequest(
          status: SupportRequestStatus.accepted,
          technician: technicianId,
        ),
      ];
      realtime.emitSupportRequestUpdated(requestId);
      await settle();
      expect(supportRequests.loadCount, loadsBefore + 1);

      gate.complete();
      await settle();

      // GET #1 answered the stale ASSIGNED; GET #2 brought ACCEPTED.
      expect(supportRequests.loadCount, loadsBefore + 2);
      expect(queue().requests.single.status, SupportRequestStatus.accepted);
      expect(queue().isRefreshing, isFalse);
    });

    test('a reconnection during a GET in flight is coalesced', () async {
      await signInWithAssignedRequest();
      final loadsBefore = supportRequests.loadCount;
      final gate = Completer<void>();
      supportRequests.loadGate = gate.future;
      supportRequestsBloc.add(const SupportRequestsRefreshRequested());
      await settle();

      // The tablet accepted while the socket was down.
      supportRequests.requests = [
        buildSupportRequest(
          status: SupportRequestStatus.accepted,
          technician: technicianId,
        ),
      ];
      realtime.emitReconnecting();
      await settle();
      realtime.emitConnected();
      await settle();
      expect(supportRequests.loadCount, loadsBefore + 1);

      gate.complete();
      await settle();

      expect(supportRequests.loadCount, loadsBefore + 2);
      expect(queue().requests.single.status, SupportRequestStatus.accepted);
    });

    test('a pending refresh does not survive signing out', () async {
      await signInWithAssignedRequest();
      final loadsBefore = supportRequests.loadCount;
      final gate = Completer<void>();
      supportRequests.loadGate = gate.future;
      supportRequestsBloc.add(const SupportRequestsRefreshRequested());
      await settle();
      realtime.emitSupportRequestUpdated(requestId);
      await settle();

      userSessionBloc.add(const UserSessionSignOutRequested());
      await settle();
      gate.complete();
      await settle();

      // The GET already out answers, and nothing follows it.
      expect(supportRequests.loadCount, loadsBefore + 1);
    });

    test('a 401 during a GET in flight runs no pending refresh', () async {
      await signInWithAssignedRequest();
      final loadsBefore = supportRequests.loadCount;
      final gate = Completer<void>();
      supportRequests.loadGate = gate.future;
      supportRequestsBloc.add(const SupportRequestsRefreshRequested());
      await settle();
      realtime.emitSupportRequestUpdated(requestId);
      await settle();

      supportRequests.loadFailure = const AuthFailure();
      gate.complete();
      await settle();

      expect(supportRequests.loadCount, loadsBefore + 1);
      expect(queue().failure, isA<AuthFailure>());
    });

    test('a network failure keeps the queue and the assistance', () async {
      supportRequests.requests = [
        buildSupportRequest(
          status: SupportRequestStatus.accepted,
          technician: technicianId,
        ),
      ];
      remoteSessions.current = buildRemoteSession();
      await signIn();
      realtime.emitConnected();
      supportRequestsBloc.add(const SupportRequestsRequested());
      await settle();
      final sessionReadsBefore = remoteSessions.currentCount;

      supportRequests.loadFailure = const NetworkFailure();
      realtime.emitSupportRequestUpdated(requestId);
      await settle();

      expect(queue().requests, hasLength(1));
      expect(queue().failure, isA<NetworkFailure>());
      // The assistance is not this event's business.
      expect(remoteSessionBloc.state.hasLiveSession, isTrue);
      expect(remoteSessions.currentCount, sessionReadsBefore);
      expect(remoteSessions.closedIds, isEmpty);
      expect(userSessionBloc.state, isA<UserSessionAuthenticated>());
    });

    test('an event after signing out requests nothing', () async {
      await signInWithAssignedRequest();
      userSessionBloc.add(const UserSessionSignOutRequested());
      await settle();
      final loadsBefore = supportRequests.loadCount;

      realtime.emitSupportRequestUpdated(requestId);
      await settle();

      expect(supportRequests.loadCount, loadsBefore);
    });

    test('a reconnection re-reads the queue, the first connection does not', () async {
      await signInWithAssignedRequest(
        afterwards: [
          buildSupportRequest(
            status: SupportRequestStatus.accepted,
            technician: technicianId,
          ),
        ],
      );
      // Only the console's own first load so far.
      expect(supportRequests.loadCount, 1);

      // The tablet accepted while the socket was down: the event is lost.
      realtime.emitReconnecting();
      await settle();
      realtime.emitConnected();
      await settle();

      expect(supportRequests.loadCount, 2);
      expect(queue().requests.single.status, SupportRequestStatus.accepted);
    });
  });

  group('support-request:queue-updated', () {
    const otherTechnicianId = '99999999-8888-7777-6666-555555555555';
    final waiting = buildSupportRequest();
    final takenByOther = buildSupportRequest(
      status: SupportRequestStatus.assigned,
      technician: otherTechnicianId,
      assignedAt: DateTime.utc(2026, 3, 11, 9, 31),
    );
    final cancelled = buildSupportRequest(
      status: SupportRequestStatus.cancelled,
      closedAt: DateTime.utc(2026, 3, 11, 9, 31),
    );

    /// The console with the queue loaded and the socket up. [initially] is
    /// what the first `GET /support-requests` answers, [afterwards] what
    /// every later one does.
    Future<void> signInWithQueue({
      required List<SupportRequest> initially,
      List<SupportRequest>? afterwards,
    }) async {
      remoteSessions.current = null;
      supportRequests
        ..requests = initially
        ..requestsAfterFirstLoad = afterwards;
      await signIn();
      realtime.emitConnected();
      supportRequestsBloc.add(const SupportRequestsRequested());
      await settle();
    }

    SupportRequestsLoaded queue() =>
        supportRequestsBloc.state as SupportRequestsLoaded;

    test('a new WAITING request is read from GET /support-requests', () async {
      await signInWithQueue(initially: const [], afterwards: [waiting]);
      expect(queue().waiting, isEmpty);
      final loadsBefore = supportRequests.loadCount;

      realtime.emitSupportRequestQueueUpdated(requestId);
      await settle();

      expect(supportRequests.loadCount, loadsBefore + 1);
      expect(queue().waiting.map((r) => r.id), [requestId]);
      expect(queue().isRefreshing, isFalse);
      // A trigger for the queue and nothing else.
      expect(supportRequests.assignedIds, isEmpty);
      expect(remoteSessions.createdSupportRequestIds, isEmpty);
      expect(realtime.joinedSessionIds, isEmpty);
      expect(peers.sessions, isEmpty);
    });

    test('a request taken by another console leaves WAITING', () async {
      await signInWithQueue(initially: [waiting], afterwards: [takenByOther]);
      expect(queue().waiting, hasLength(1));

      realtime.emitSupportRequestQueueUpdated(requestId);
      await settle();

      expect(queue().waiting, isEmpty);
      // REST says whose it is; the console neither assigned nor adopted it.
      expect(queue().assignedTo(technicianId), isEmpty);
      expect(queue().requests.single.technicianId, otherTechnicianId);
      expect(supportRequests.assignedIds, isEmpty);
    });

    test('a WAITING request cancelled by the tablet leaves WAITING', () async {
      await signInWithQueue(initially: [waiting], afterwards: [cancelled]);

      realtime.emitSupportRequestQueueUpdated(requestId);
      await settle();

      expect(queue().waiting, isEmpty);
      expect(queue().history.map((r) => r.id), [requestId]);
    });

    test('the event alone never adds, removes or changes a row', () async {
      await signInWithQueue(initially: [waiting], afterwards: [takenByOther]);
      final gate = Completer<void>();
      supportRequests.loadGate = gate.future;

      // Its id is a request this console does not even show.
      realtime.emitSupportRequestQueueUpdated('a-request-not-on-screen');
      await settle();

      expect(queue().isRefreshing, isTrue);
      expect(queue().requests, [waiting]);

      gate.complete();
      await settle();

      // Whatever REST answers, and only that.
      expect(queue().requests, [takenByOther]);
    });

    test('an event during a GET in flight is not lost', () async {
      await signInWithQueue(initially: const []);
      final loadsBefore = supportRequests.loadCount;
      final gate = Completer<void>();
      supportRequests.loadGate = gate.future;

      // GET #1 is out and reads an empty queue.
      supportRequestsBloc.add(const SupportRequestsRefreshRequested());
      await settle();

      // The tablet asks for help: commit, then the event, while GET #1
      // travels.
      supportRequests.requests = [waiting];
      realtime.emitSupportRequestQueueUpdated(requestId);
      await settle();
      expect(supportRequests.loadCount, loadsBefore + 1);

      gate.complete();
      await settle();

      // GET #1 answered the stale empty queue; GET #2 brought the request.
      expect(supportRequests.loadCount, loadsBefore + 2);
      expect(queue().waiting.map((r) => r.id), [requestId]);
      expect(queue().isRefreshing, isFalse);
    });

    test('a burst during a GET in flight costs one extra GET', () async {
      await signInWithQueue(initially: const [], afterwards: [waiting]);
      final loadsBefore = supportRequests.loadCount;
      final gate = Completer<void>();
      supportRequests.loadGate = gate.future;
      supportRequestsBloc.add(const SupportRequestsRefreshRequested());
      await settle();

      realtime
        ..emitSupportRequestQueueUpdated(requestId)
        ..emitSupportRequestQueueUpdated('another-request')
        ..emitSupportRequestQueueUpdated(requestId);
      await settle();
      expect(supportRequests.loadCount, loadsBefore + 1);

      gate.complete();
      supportRequests.loadGate = null;
      await settle();

      expect(supportRequests.loadCount, loadsBefore + 2);
      expect(queue().waiting.map((r) => r.id), [requestId]);
      expect(queue().isRefreshing, isFalse);

      // Nothing loops on its own.
      await settle();
      expect(supportRequests.loadCount, loadsBefore + 2);
    });

    for (final queueFirst in [true, false]) {
      final order = queueFirst
          ? 'queue-updated then updated'
          : 'updated then queue-updated';

      test('$order, during a GET in flight, coalesce', () async {
        final mine = buildSupportRequest(
          id: 'mine',
          status: SupportRequestStatus.assigned,
          technician: technicianId,
        );
        await signInWithQueue(initially: [mine]);
        final loadsBefore = supportRequests.loadCount;
        final gate = Completer<void>();
        supportRequests.loadGate = gate.future;
        supportRequestsBloc.add(const SupportRequestsRefreshRequested());
        await settle();

        // Both changes commit while GET #1 travels: a new WAITING request
        // and the tablet accepting the one assigned here.
        final accepted = mine.copyWith(status: SupportRequestStatus.accepted);
        supportRequests.requests = [waiting, accepted];
        if (queueFirst) {
          realtime
            ..emitSupportRequestQueueUpdated(requestId)
            ..emitSupportRequestUpdated('mine');
        } else {
          realtime
            ..emitSupportRequestUpdated('mine')
            ..emitSupportRequestQueueUpdated(requestId);
        }
        await settle();
        expect(supportRequests.loadCount, loadsBefore + 1);

        gate.complete();
        supportRequests.loadGate = null;
        await settle();

        expect(supportRequests.loadCount, loadsBefore + 2);
        expect(queue().waiting.map((r) => r.id), [requestId]);
        expect(
          queue().assignedTo(technicianId).single.status,
          SupportRequestStatus.accepted,
        );
        expect(queue().isRefreshing, isFalse);
        expect(queue().failure, isNull);
      });

      test('$order, while idle, cost one GET plus one follow-up', () async {
        await signInWithQueue(initially: const [], afterwards: [waiting]);
        final loadsBefore = supportRequests.loadCount;

        if (queueFirst) {
          realtime
            ..emitSupportRequestQueueUpdated(requestId)
            ..emitSupportRequestUpdated(requestId);
        } else {
          realtime
            ..emitSupportRequestUpdated(requestId)
            ..emitSupportRequestQueueUpdated(requestId);
        }
        await settle();

        // The first starts a GET, the second is coalesced behind it.
        expect(supportRequests.loadCount, loadsBefore + 2);
        expect(queue().waiting.map((r) => r.id), [requestId]);
        expect(queue().isRefreshing, isFalse);
      });
    }

    test('a reconnection still re-reads the queue, once', () async {
      await signInWithQueue(initially: const [], afterwards: [waiting]);
      final loadsBefore = supportRequests.loadCount;

      // The request was created while the socket was down: its event is lost.
      realtime.emitReconnecting();
      await settle();
      realtime.emitConnected();
      await settle();

      expect(supportRequests.loadCount, loadsBefore + 1);
      expect(queue().waiting.map((r) => r.id), [requestId]);
    });

    test('an event after signing out requests nothing', () async {
      await signInWithQueue(initially: [waiting]);
      userSessionBloc.add(const UserSessionSignOutRequested());
      await settle();
      final loadsBefore = supportRequests.loadCount;

      realtime.emitSupportRequestQueueUpdated(requestId);
      await settle();

      expect(supportRequests.loadCount, loadsBefore);
    });

    test('a pending refresh does not survive signing out', () async {
      await signInWithQueue(initially: const []);
      final loadsBefore = supportRequests.loadCount;
      final gate = Completer<void>();
      supportRequests.loadGate = gate.future;
      supportRequestsBloc.add(const SupportRequestsRefreshRequested());
      await settle();
      realtime.emitSupportRequestQueueUpdated(requestId);
      await settle();

      userSessionBloc.add(const UserSessionSignOutRequested());
      await settle();
      gate.complete();
      await settle();

      expect(supportRequests.loadCount, loadsBefore + 1);
    });

    test('a 401 during a GET in flight runs no pending refresh', () async {
      await signInWithQueue(initially: const []);
      final loadsBefore = supportRequests.loadCount;
      final gate = Completer<void>();
      supportRequests.loadGate = gate.future;
      supportRequestsBloc.add(const SupportRequestsRefreshRequested());
      await settle();
      realtime.emitSupportRequestQueueUpdated(requestId);
      await settle();

      supportRequests.loadFailure = const AuthFailure();
      gate.complete();
      await settle();

      expect(supportRequests.loadCount, loadsBefore + 1);
      expect(queue().failure, isA<AuthFailure>());
    });

    test('a network failure keeps the queue, and a later event syncs', () async {
      await signInWithQueue(initially: [waiting]);

      supportRequests.loadFailure = const NetworkFailure();
      realtime.emitSupportRequestQueueUpdated(requestId);
      await settle();

      expect(queue().requests, [waiting]);
      expect(queue().failure, isA<NetworkFailure>());
      expect(userSessionBloc.state, isA<UserSessionAuthenticated>());

      // The network is back and the request was taken meanwhile.
      supportRequests
        ..loadFailure = null
        ..requests = [takenByOther];
      realtime.emitSupportRequestQueueUpdated(requestId);
      await settle();

      expect(queue().waiting, isEmpty);
      expect(queue().failure, isNull);
    });
  });

  group('refused relay', () {
    const sdp = 'v=0 o=- 46117 2 IN IP4 127.0.0.1';
    const offer = WebRtcOffer(remoteSessionId: remoteSessionId, sdp: sdp);

    /// A console with a live, joined session, ready to relay.
    Future<void> signInWithJoinedSession() async {
      remoteSessions.current = buildRemoteSession();
      supportRequests.requests = [buildSupportRequest()];
      await signIn();
      realtime.emitConnected();
      await settle();
      expect(signalingJoinBloc.state, isA<SignalingJoined>());
    }

    /// Sends an offer and answers its acknowledgement with [error].
    Future<SignalingRelayResult> relayRefusedWith(String error) async {
      final pending = signaling.sendOffer(offer);
      realtime.answerRelayAck({'delivered': false, 'error': error});
      final result = await pending;
      await settle();
      return result;
    }

    test('NOT_JOINED joins the room again, and only once', () async {
      await signInWithJoinedSession();
      final joinsBefore = realtime.joinedSessionIds.length;

      await relayRefusedWith('NOT_JOINED');

      // Back into the room: that is the documented fix, and the only one.
      expect(realtime.joinedSessionIds.length, joinsBefore + 1);
      expect(signalingJoinBloc.state, isA<SignalingJoined>());
      // The refused message is never resent by the console.
      expect(realtime.emittedSignaling, hasLength(1));

      // A second refusal on the same connection stops there: no loop.
      await relayRefusedWith('NOT_JOINED');
      expect(realtime.joinedSessionIds.length, joinsBefore + 1);
    });

    test('a reconnection allows the automatic rejoin again', () async {
      await signInWithJoinedSession();
      await relayRefusedWith('NOT_JOINED');
      final joinsBefore = realtime.joinedSessionIds.length;

      realtime.emitReconnecting();
      await settle();
      realtime.emitConnected();
      await settle();
      // The reconnection itself joins once.
      expect(realtime.joinedSessionIds.length, joinsBefore + 1);

      await relayRefusedWith('NOT_JOINED');

      expect(realtime.joinedSessionIds.length, joinsBefore + 2);
    });

    test('NOT_JOINED for another session is not joined at all', () async {
      await signInWithJoinedSession();
      final joinsBefore = realtime.joinedSessionIds.length;

      // The console only ever joins what REST gave it.
      realtime.joinRoom('another-session');
      final pending = signaling.sendOffer(
        const WebRtcOffer(remoteSessionId: 'another-session', sdp: sdp),
      );
      realtime.answerRelayAck({'delivered': false, 'error': 'NOT_JOINED'});
      await pending;
      await settle();

      expect(realtime.joinedSessionIds.length, joinsBefore);
    });

    test('UNAUTHORIZED reconciles over REST and keeps the User JWT', () async {
      await signInWithJoinedSession();
      final readsBefore = remoteSessions.currentCount;

      final result = await relayRefusedWith('UNAUTHORIZED');

      expect(result, isA<SignalingRelayRefused>());
      // An ownership failure, not an expired token: GET /remote-sessions/current
      // is what decides, and the session stays signed in.
      expect(remoteSessions.currentCount, readsBefore + 1);
      expect(userSessionBloc.state, isA<UserSessionAuthenticated>());
      expect(storage.token, 'stored-user-jwt');
    });

    test('UNAUTHORIZED on a session the tablet closed ends the assistance', () async {
      await signInWithJoinedSession();
      // The session was closed while the relay was travelling.
      remoteSessions.current = null;

      await relayRefusedWith('UNAUTHORIZED');

      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(signalingJoinBloc.state, isA<SignalingIdle>());
      expect(userSessionBloc.state, isA<UserSessionAuthenticated>());
    });

    test('UNAVAILABLE reconciles over REST once', () async {
      await signInWithJoinedSession();
      final readsBefore = remoteSessions.currentCount;

      await relayRefusedWith('UNAVAILABLE');
      expect(remoteSessions.currentCount, readsBefore + 1);

      // Transient or not, it is not retried in a loop.
      await relayRefusedWith('UNAVAILABLE');
      expect(remoteSessions.currentCount, readsBefore + 1);
    });

    test('INVALID_PAYLOAD refreshes nothing and rejoins nothing', () async {
      await signInWithJoinedSession();
      final readsBefore = remoteSessions.currentCount;
      final joinsBefore = realtime.joinedSessionIds.length;

      await relayRefusedWith('INVALID_PAYLOAD');
      await relayRefusedWith('INVALID_PAYLOAD');

      // A contract bug: no refresh loop, no rejoin, nothing to recover.
      expect(remoteSessions.currentCount, readsBefore);
      expect(realtime.joinedSessionIds.length, joinsBefore);
      expect(signalingJoinBloc.state, isA<SignalingJoined>());
    });

    test('an unknown code is acted upon by nobody', () async {
      await signInWithJoinedSession();
      final readsBefore = remoteSessions.currentCount;
      final joinsBefore = realtime.joinedSessionIds.length;

      await relayRefusedWith('RATE_LIMITED');

      expect(remoteSessions.currentCount, readsBefore);
      expect(realtime.joinedSessionIds.length, joinsBefore);
    });

    test('a new assistance gets its own budget on the same socket', () async {
      const secondSessionId = '7f2a5c7e-8b10-4c88-9d0a-3d1b9e649a0f';
      await signInWithJoinedSession();
      await relayRefusedWith('UNAVAILABLE');
      final readsBefore = remoteSessions.currentCount;

      // The assistance ended and the technician started another one; the
      // socket never dropped.
      remoteSessions.current = buildRemoteSession(id: secondSessionId);
      remoteSessionBloc.add(const RemoteSessionRefreshRequested());
      await settle();
      expect(signalingJoinBloc.state.remoteSessionId, secondSessionId);

      final pending = signaling.sendOffer(
        const WebRtcOffer(remoteSessionId: secondSessionId, sdp: sdp),
      );
      realtime.answerRelayAck({'delivered': false, 'error': 'UNAVAILABLE'});
      await pending;
      await settle();

      // The refusal of the previous assistance does not spend this one's
      // reconciliation.
      expect(remoteSessions.currentCount, greaterThan(readsBefore + 1));
    });

    test('a delivered relay changes nothing in the console', () async {
      await signInWithJoinedSession();
      final readsBefore = remoteSessions.currentCount;
      final joinsBefore = realtime.joinedSessionIds.length;

      final pending = signaling.sendOffer(offer);
      realtime.answerRelayAck({
        'delivered': true,
        'remoteSessionId': remoteSessionId,
      });
      await pending;
      await settle();

      expect(remoteSessions.currentCount, readsBefore);
      expect(realtime.joinedSessionIds.length, joinsBefore);
      // Delivered means relayed, never "the peer applied it": the session is
      // still CONNECTING and only REST can move it.
      expect(remoteSessionBloc.state, isA<RemoteSessionConnecting>());
    });
  });

  group('close from the console', () {
    test('ending the assistance refreshes the support request queue', () async {
      remoteSessions.current = buildRemoteSession();
      supportRequests.requests = [buildSupportRequest()];
      await signIn();
      realtime.emitConnected();
      await settle();
      final queueLoadsBefore = supportRequests.loadCount;

      remoteSessionBloc.add(const RemoteSessionCloseRequested());
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(supportRequests.loadCount, queueLoadsBefore + 1);
    });
  });
}
