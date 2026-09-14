import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/remote_session/data/repositories/remote_session_repository_impl.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';
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
