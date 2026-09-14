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
import 'package:remote_control_web/features/support/domain/usecases/assign_support_request.dart';
import 'package:remote_control_web/features/support/domain/usecases/load_support_requests.dart';
import 'package:remote_control_web/features/support/presentation/bloc/support_requests/support_requests_bloc.dart';
import 'package:remote_control_web/features/technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import 'package:remote_control_web/features/technician_realtime/presentation/bloc/technician_realtime/technician_realtime_bloc.dart';

import '../../support/auth_test_doubles.dart';
import '../../support/console_test_doubles.dart';
import '../../support/realtime_test_doubles.dart';
import '../../support/remote_session_test_doubles.dart';

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

  late UserSessionBloc userSessionBloc;
  late RemoteSessionBloc remoteSessionBloc;
  late TechnicianRealtimeBloc realtimeBloc;
  late SignalingJoinBloc signalingJoinBloc;
  late SupportRequestsBloc supportRequestsBloc;
  late TechnicianConsoleCoordinator coordinator;

  setUp(() {
    auth = FakeAuthRemoteDataSource()..checkStatusResponse = technicianSession;
    storage = InMemoryUserTokenStorage()..token = 'stored-user-jwt';
    remoteSessions = FakeRemoteSessionRepository();
    supportRequests = FakeSupportRequestRepository();
    realtime = FakeTechnicianRealtimeClient();

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

    coordinator = TechnicianConsoleCoordinator(
      userSessionBloc: userSessionBloc,
      remoteSessionBloc: remoteSessionBloc,
      technicianRealtimeBloc: realtimeBloc,
      signalingJoinBloc: signalingJoinBloc,
      supportRequestsBloc: supportRequestsBloc,
      realtimeClient: realtime,
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
    ]);
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
