import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/app/console/technician_console_coordinator.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/auth/domain/usecases/log_out.dart';
import 'package:remote_control_web/features/auth/domain/usecases/restore_session.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/auth/presentation/bloc/user_session/user_session_bloc.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/create_remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_web/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_web/features/signaling/data/technician_signaling_client_impl.dart';
import 'package:remote_control_web/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_web/features/signaling/domain/entities/webrtc_session_description.dart';
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
