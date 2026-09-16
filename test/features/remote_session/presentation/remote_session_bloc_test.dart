import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/remote_session/data/repositories/remote_session_repository_impl.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/activate_remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/create_remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_web/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';

import '../../../support/console_test_doubles.dart';
import '../../../support/remote_session_test_doubles.dart';

void main() {
  late FakeRemoteSessionRepository repository;

  RemoteSessionBloc buildBloc() => RemoteSessionBloc(
    loadCurrentRemoteSession: LoadCurrentRemoteSession(repository: repository),
    createRemoteSession: CreateRemoteSession(repository: repository),
    activateRemoteSession: ActivateRemoteSession(repository: repository),
    closeRemoteSession: CloseRemoteSession(repository: repository),
  );

  setUp(() => repository = FakeRemoteSessionRepository());

  group('startup', () {
    test('no live session ends in Idle', () async {
      repository.current = null;
      final bloc = buildBloc();

      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(bloc.state, isA<RemoteSessionIdle>());
      expect(bloc.state.hasLiveSession, isFalse);
      expect(bloc.state.failure, isNull);
      expect(repository.currentCount, 1);
      await bloc.close();
    });

    test('a CONNECTING session is recovered', () async {
      repository.current = buildRemoteSession();
      final bloc = buildBloc();

      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      final state = bloc.state as RemoteSessionConnecting;
      expect(state.session.id, remoteSessionId);
      expect(state.session.status, RemoteSessionStatus.connecting);
      expect(state.hasLiveSession, isTrue);
      await bloc.close();
    });

    test('an ACTIVE session is recovered and never simulated', () async {
      repository.current = buildRemoteSession(
        status: RemoteSessionStatus.active,
        connectedAt: DateTime.utc(2026, 3, 11, 9, 34),
      );
      final bloc = buildBloc();

      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionActive);

      expect(bloc.state, isA<RemoteSessionActive>());
      expect(bloc.state.hasLiveSession, isTrue);
      await bloc.close();
    });

    test('a CLOSED session is not an assistance', () async {
      // The endpoint never returns one, but a client that trusted `status`
      // blindly would show a finished session as if it were open.
      repository.current = buildRemoteSession(
        status: RemoteSessionStatus.closed,
      );
      final bloc = buildBloc();

      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(bloc.state, isA<RemoteSessionIdle>());
      await bloc.close();
    });

    test('a 401 is reported so the console can end the session', () async {
      repository.currentFailure = const AuthFailure();
      final bloc = buildBloc();

      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionFailure);

      expect(bloc.state.lastFailure, isA<AuthFailure>());
      await bloc.close();
    });

    test('an unreachable backend leaves a retryable failure', () async {
      repository.currentFailure = const NetworkFailure();
      final bloc = buildBloc();

      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionFailure);

      expect(bloc.state.failure, isA<NetworkFailure>());

      repository
        ..currentFailure = null
        ..currentFailureAfterFirstRead = null
        ..current = buildRemoteSession();
      bloc.add(const RemoteSessionRefreshRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      expect(bloc.state.hasLiveSession, isTrue);
      await bloc.close();
    });
  });

  group('create', () {
    test('an accepted request produces a CONNECTING session', () async {
      repository.current = null;
      final bloc = buildBloc();

      bloc.add(const RemoteSessionCreateRequested(requestId));
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      expect(repository.createdSupportRequestIds, [requestId]);
      expect(bloc.state.session!.supportRequestId, requestId);
      expect(bloc.state.session!.status, RemoteSessionStatus.connecting);
      await bloc.close();
    });

    test('a second click while creating does not send a second POST', () async {
      final gate = Completer<void>();
      repository.createGate = gate.future;
      final bloc = buildBloc();

      bloc.add(const RemoteSessionCreateRequested(requestId));
      await bloc.stream.firstWhere(
        (state) => state is RemoteSessionIdle && state.isStarting,
      );
      bloc.add(const RemoteSessionCreateRequested(requestId));
      await Future<void>.delayed(Duration.zero);

      expect(repository.createdSupportRequestIds, [requestId]);

      gate.complete();
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);
      await bloc.close();
    });

    test('a 409 reconciles with GET current and shows the live session', () async {
      // The technician already holds a session: the backend refuses a second
      // one, and the console recovers the real state instead of failing.
      repository
        ..createFailure = const ConflictFailure(kCreateConflictMessage)
        ..current = buildRemoteSession(supportRequestId: 'another-request');
      final bloc = buildBloc();

      bloc.add(const RemoteSessionCreateRequested(requestId));
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      expect(bloc.state.hasLiveSession, isTrue);
      expect(bloc.state.session!.supportRequestId, 'another-request');
      // Reconciled: there is nothing the user has to do about it.
      expect(bloc.state.failure, isNull);
      expect(repository.currentCount, 1);
      await bloc.close();
    });

    test('a 409 with no live session reports the conflict', () async {
      // The other 409 reasons: the device is offline, the request was not
      // accepted, or it already produced a session.
      repository
        ..createFailure = const ConflictFailure(kCreateConflictMessage)
        ..current = null;
      final bloc = buildBloc();

      bloc.add(const RemoteSessionCreateRequested(requestId));
      await bloc.stream.firstWhere(
        (state) => state is RemoteSessionIdle && state.failure != null,
      );

      expect(bloc.state.hasLiveSession, isFalse);
      expect(bloc.state.failure, isA<ConflictFailure>());
      expect(bloc.state.failure!.message, kCreateConflictMessage);
      await bloc.close();
    });

    test('a 403 is reported and keeps the console usable', () async {
      repository.createFailure = const ForbiddenFailure('Sin permisos.');
      final bloc = buildBloc();

      bloc.add(const RemoteSessionCreateRequested(requestId));
      await bloc.stream.firstWhere(
        (state) => state is RemoteSessionIdle && state.failure != null,
      );

      expect(bloc.state.failure, isA<ForbiddenFailure>());
      // A refused start does not ask for a reconciliation.
      expect(repository.currentCount, 0);
      await bloc.close();
    });

    test('a 401 is surfaced as such', () async {
      repository.createFailure = const AuthFailure();
      final bloc = buildBloc();

      bloc.add(const RemoteSessionCreateRequested(requestId));
      await bloc.stream.firstWhere((state) => state.lastFailure != null);

      expect(bloc.state.lastFailure, isA<AuthFailure>());
      await bloc.close();
    });

    test('no second session is started while one is live', () async {
      repository.current = buildRemoteSession();
      final bloc = buildBloc();
      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      bloc.add(const RemoteSessionCreateRequested('another-request'));
      await Future<void>.delayed(Duration.zero);

      expect(repository.createdSupportRequestIds, isEmpty);
      await bloc.close();
    });
  });

  group('activate', () {
    /// A bloc showing the live `CONNECTING` session the backend has.
    Future<RemoteSessionBloc> connectedBloc() async {
      repository.current = buildRemoteSession();
      final bloc = buildBloc()..add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);
      return bloc;
    }

    test('a CONNECTING session becomes ACTIVE through REST', () async {
      final bloc = await connectedBloc();

      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state is RemoteSessionActive);

      expect(repository.activatedIds, [remoteSessionId]);
      // The POST answer is not taken as the state: current is read again.
      expect(repository.currentCount, 2);
      final session = bloc.state.session!;
      expect(session.status, RemoteSessionStatus.active);
      expect(session.connectedAt, isNotNull);
      expect(bloc.state.failure, isNull);
      await bloc.close();
    });

    test('the assistance stays visible while it is in flight', () async {
      final bloc = await connectedBloc();
      final gate = Completer<void>();
      repository.activateGate = gate.future;

      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state.isActivating);

      // Not a loading screen: the session the technician is working on stays.
      expect(bloc.state, isA<RemoteSessionConnecting>());
      expect(bloc.state.session!.id, remoteSessionId);
      expect(bloc.state.isActivating, isTrue);

      gate.complete();
      await bloc.stream.firstWhere((state) => state is RemoteSessionActive);
      await bloc.close();
    });

    test('a second request while one is in flight is dropped', () async {
      final bloc = await connectedBloc();
      final gate = Completer<void>();
      repository.activateGate = gate.future;

      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state.isActivating);
      bloc
        ..add(const RemoteSessionActivationRequested(remoteSessionId))
        ..add(const RemoteSessionActivationRequested(remoteSessionId));
      await Future<void>.delayed(Duration.zero);

      expect(repository.activatedIds, [remoteSessionId]);

      gate.complete();
      await bloc.stream.firstWhere((state) => state is RemoteSessionActive);
      expect(repository.activatedIds, [remoteSessionId]);
      await bloc.close();
    });

    test('an ACTIVE session is never activated again', () async {
      repository.current = buildRemoteSession(
        status: RemoteSessionStatus.active,
        connectedAt: DateTime.utc(2026, 3, 11, 9, 35, 12),
      );
      final bloc = buildBloc()..add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionActive);

      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await Future<void>.delayed(Duration.zero);

      expect(repository.activatedIds, isEmpty);
      await bloc.close();
    });

    test('an id that is not the current session is ignored', () async {
      final bloc = await connectedBloc();

      bloc.add(const RemoteSessionActivationRequested('another-session'));
      await Future<void>.delayed(Duration.zero);

      // Ownership is never taken from the event: nothing is sent and the id
      // is not adopted.
      expect(repository.activatedIds, isEmpty);
      expect(bloc.state.session!.id, remoteSessionId);
      await bloc.close();
    });

    test('nothing is activated without a live session', () async {
      repository.current = null;
      final bloc = buildBloc()..add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await Future<void>.delayed(Duration.zero);

      expect(repository.activatedIds, isEmpty);
      await bloc.close();
    });

    test('a 409 is reconciled with REST', () async {
      final bloc = await connectedBloc();
      repository
        ..activateFailure = const ConflictFailure(kActivateConflictMessage)
        // What the backend really has: the tablet closed it meanwhile.
        ..current = null;

      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(repository.activatedIds, [remoteSessionId]);
      expect(repository.currentCount, 2);
      // No fictional CONNECTING session is kept alive.
      expect(bloc.state.hasLiveSession, isFalse);
      await bloc.close();
    });

    test('a 409 whose session is still live shows what REST answers', () async {
      final bloc = await connectedBloc();
      repository
        ..activateFailure = const ConflictFailure(kActivateConflictMessage)
        ..current = buildRemoteSession(
          status: RemoteSessionStatus.active,
          connectedAt: DateTime.utc(2026, 3, 11, 9, 35, 12),
        );

      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state is RemoteSessionActive);

      // It was activated by the race, not by this console. Not an error.
      expect(bloc.state.failure, isNull);
      expect(bloc.state.session!.connectedAt, isNotNull);
      await bloc.close();
    });

    test('a 404 is reconciled the same way', () async {
      final bloc = await connectedBloc();
      repository
        ..activateFailure = const NotFoundFailure()
        ..current = null;

      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(repository.currentCount, 2);
      expect(bloc.state.hasLiveSession, isFalse);
      await bloc.close();
    });

    test('a network failure keeps the session and offers a retry', () async {
      final bloc = await connectedBloc();
      repository.activateFailure = const NetworkFailure();

      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state.failure != null);

      // The peers are still connected; only the confirmation failed.
      expect(bloc.state, isA<RemoteSessionConnecting>());
      expect(bloc.state.session!.id, remoteSessionId);
      expect(bloc.state.isActivating, isFalse);
      expect(bloc.state.canRetryActivation, isTrue);
      expect(bloc.state.failure!.message, kRemoteSessionActivationFailedNotice);
      // Nothing was re-read: the failure never reached the backend.
      expect(repository.currentCount, 1);
      await bloc.close();
    });

    test('the offered retry activates again and succeeds', () async {
      final bloc = await connectedBloc();
      repository.activateFailure = const NetworkFailure();
      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state.canRetryActivation);

      repository.activateFailure = null;
      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state is RemoteSessionActive);

      expect(repository.activatedIds, [remoteSessionId, remoteSessionId]);
      expect(bloc.state.session!.status, RemoteSessionStatus.active);
      await bloc.close();
    });

    test('a 401 is reported as an AuthFailure for the console', () async {
      final bloc = await connectedBloc();
      repository.activateFailure = const AuthFailure();

      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state.failure != null);

      expect(bloc.state.lastFailure, isA<AuthFailure>());
      // A rejected token is not something a retry could fix.
      expect(bloc.state.canRetryActivation, isFalse);
      await bloc.close();
    });

    test('a 403 is reported without inventing ownership', () async {
      final bloc = await connectedBloc();
      repository.activateFailure = const ForbiddenFailure();

      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state.failure != null);

      expect(bloc.state.failure, isA<ForbiddenFailure>());
      expect(bloc.state.session!.id, remoteSessionId);
      expect(bloc.state.canRetryActivation, isFalse);
      await bloc.close();
    });

    test('dismissing the notice drops the retry offer with it', () async {
      final bloc = await connectedBloc();
      repository.activateFailure = const NetworkFailure();
      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state.canRetryActivation);

      bloc.add(const RemoteSessionNoticeDismissed());
      await bloc.stream.firstWhere((state) => state.failure == null);

      expect(bloc.state.canRetryActivation, isFalse);
      expect(bloc.state, isA<RemoteSessionConnecting>());
      await bloc.close();
    });

    test('activate, load current and close stay separate operations', () async {
      final bloc = await connectedBloc();

      bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
      await bloc.stream.firstWhere((state) => state is RemoteSessionActive);

      expect(repository.activatedIds, [remoteSessionId]);
      expect(repository.closedIds, isEmpty);
      expect(repository.createdSupportRequestIds, isEmpty);
      await bloc.close();
    });
  });

  group('close', () {
    test('closing ends in Idle after re-reading GET current', () async {
      repository.current = buildRemoteSession();
      final bloc = buildBloc();
      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(repository.closedIds, [remoteSessionId]);
      // REST is the source of truth: the close is followed by a read.
      expect(repository.currentCount, 2);
      expect(bloc.state.hasLiveSession, isFalse);
      expect(bloc.state.failure, isNull);
      await bloc.close();
    });

    test('a second close while one is in flight is dropped', () async {
      repository.current = buildRemoteSession();
      final gate = Completer<void>();
      repository.closeGate = gate.future;
      final bloc = buildBloc();
      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere(
        (state) => state is RemoteSessionLive && state.isClosing,
      );
      bloc.add(const RemoteSessionCloseRequested());
      await Future<void>.delayed(Duration.zero);

      expect(repository.closedIds, [remoteSessionId]);

      gate.complete();
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
      await bloc.close();
    });

    test('a 409 reconciles instead of blocking the UI', () async {
      // The tablet closed it first, so the close conflicts and the session is
      // already gone.
      repository.current = buildRemoteSession();
      final bloc = buildBloc();
      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      repository
        ..closeFailure = const ConflictFailure(kCloseConflictMessage)
        ..current = null;
      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(bloc.state.hasLiveSession, isFalse);
      // Reconciled to the same outcome the user asked for: no error shown.
      expect(bloc.state.failure, isNull);
      expect(repository.currentCount, 2);
      await bloc.close();
    });

    test('a 409 with the session still live tells the user', () async {
      repository.current = buildRemoteSession();
      final bloc = buildBloc();
      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      repository.closeFailure = const ConflictFailure(kCloseConflictMessage);
      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere(
        (state) => state is RemoteSessionLive && !state.isClosing,
      );

      expect(bloc.state.hasLiveSession, isTrue);
      expect(bloc.state.failure, isA<ConflictFailure>());
      await bloc.close();
    });

    test('a network failure keeps the known session and offers a retry', () async {
      repository.current = buildRemoteSession();
      final bloc = buildBloc();
      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      repository.closeFailure = const NetworkFailure();
      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere(
        (state) => state is RemoteSessionLive && state.failure != null,
      );

      expect(bloc.state.hasLiveSession, isTrue);
      expect(bloc.state.session!.id, remoteSessionId);
      expect(bloc.state.failure, isA<NetworkFailure>());
      // The session is not promoted to CLOSED locally.
      expect(bloc.state.session!.status, RemoteSessionStatus.connecting);
      await bloc.close();
    });

    test('the notice can be dismissed without losing the session', () async {
      repository.current = buildRemoteSession();
      final bloc = buildBloc();
      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      repository.closeFailure = const NetworkFailure();
      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state.failure != null);

      bloc.add(const RemoteSessionNoticeDismissed());
      await bloc.stream.firstWhere((state) => state.failure == null);

      expect(bloc.state.hasLiveSession, isTrue);
      await bloc.close();
    });
  });

  group('refresh', () {
    test('a session closed elsewhere disappears on the next read', () async {
      repository.current = buildRemoteSession();
      final bloc = buildBloc();
      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      // The tablet closed it: the backend now answers `remoteSession: null`.
      repository.current = null;
      bloc.add(const RemoteSessionRefreshRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(bloc.state.hasLiveSession, isFalse);
      await bloc.close();
    });

    test('a failed refresh preserves the known session', () async {
      repository.current = buildRemoteSession();
      final bloc = buildBloc();
      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      repository.currentFailure = const NetworkFailure();
      bloc.add(const RemoteSessionRefreshRequested());
      await bloc.stream.firstWhere((state) => state.failure != null);

      expect(bloc.state.hasLiveSession, isTrue);
      expect(bloc.state.session!.id, remoteSessionId);
      expect(
        bloc.state.failure!.message,
        kRemoteSessionRefreshFailedNotice,
      );
      await bloc.close();
    });

    test('signing out forgets everything held in memory', () async {
      repository.current = buildRemoteSession();
      final bloc = buildBloc();
      bloc.add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      bloc.add(const RemoteSessionCleared());
      await bloc.stream.firstWhere((state) => state is RemoteSessionInitial);

      expect(bloc.state.session, isNull);
      await bloc.close();
    });
  });
}
