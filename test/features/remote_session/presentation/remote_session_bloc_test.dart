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
  late InMemoryPendingRemoteSessionCloseStore pendingCloses;

  RemoteSessionBloc buildBloc({
    List<Duration> closeRetryDelays = RemoteSessionBloc.defaultCloseRetryDelays,
  }) => RemoteSessionBloc(
    loadCurrentRemoteSession: LoadCurrentRemoteSession(repository: repository),
    createRemoteSession: CreateRemoteSession(repository: repository),
    activateRemoteSession: ActivateRemoteSession(repository: repository),
    closeRemoteSession: CloseRemoteSession(repository: repository),
    pendingCloseStore: pendingCloses,
    closeRetryDelays: closeRetryDelays,
  );

  setUp(() {
    repository = FakeRemoteSessionRepository();
    pendingCloses = InMemoryPendingRemoteSessionCloseStore();
  });

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

    test(
      'a 409 reconciles with GET current and shows the live session',
      () async {
        // The technician already holds a session: the backend refuses a second
        // one, and the console recovers the real state instead of failing.
        repository
          ..createFailure = const ConflictFailure(kCreateConflictMessage)
          ..current = buildRemoteSession(supportRequestId: 'another-request');
        final bloc = buildBloc();

        bloc.add(const RemoteSessionCreateRequested(requestId));
        await bloc.stream.firstWhere(
          (state) => state is RemoteSessionConnecting,
        );

        expect(bloc.state.hasLiveSession, isTrue);
        expect(bloc.state.session!.supportRequestId, 'another-request');
        // Reconciled: there is nothing the user has to do about it.
        expect(bloc.state.failure, isNull);
        expect(repository.currentCount, 1);
        await bloc.close();
      },
    );

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

  group('FINALIZAR is final for this console', () {
    final active = buildRemoteSession(
      status: RemoteSessionStatus.active,
      connectedAt: DateTime.utc(2026, 3, 11, 9, 35, 12),
    );

    /// A bloc whose automatic close retries are short enough for a test.
    RemoteSessionBloc quickBloc() => buildBloc(
      closeRetryDelays: const [
        Duration(milliseconds: 5),
        Duration(milliseconds: 5),
      ],
    );

    Future<RemoteSessionBloc> activeBloc({RemoteSessionBloc? bloc}) async {
      repository.current = active;
      final started = (bloc ?? buildBloc())..add(const RemoteSessionStarted());
      await started.stream.firstWhere((state) => state is RemoteSessionActive);
      return started;
    }

    /// Every state emitted from now on.
    List<RemoteSessionState> record(RemoteSessionBloc bloc) {
      final states = <RemoteSessionState>[];
      final subscription = bloc.stream.listen(states.add);
      addTearDown(subscription.cancel);
      return states;
    }

    test('the session stops being live before the POST answers', () async {
      final bloc = await activeBloc();
      final gate = Completer<void>();
      repository.closeGate = gate.future;

      bloc.add(const RemoteSessionCloseRequested());
      await pumpEventQueue();

      expect(bloc.state, isA<RemoteSessionEnding>());
      final ending = bloc.state as RemoteSessionEnding;
      expect(ending.remoteSessionId, remoteSessionId);
      expect(ending.isConfirming, isTrue);
      expect(bloc.state.hasLiveSession, isFalse);
      expect(bloc.state.session, isNull);
      expect(repository.closedIds, [remoteSessionId]);

      gate.complete();
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(
        (bloc.state as RemoteSessionIdle).notice,
        kRemoteSessionFinishedNotice,
      );
      // REST is still the source of truth: the close is followed by a read.
      expect(repository.currentCount, 2);
      expect(pendingCloses.ids, isEmpty);
      await bloc.close();
    });

    test('the decision is written down before the POST leaves', () async {
      final bloc = await activeBloc();
      Set<String>? storedWhenSent;
      repository.onClose = (_) => storedWhenSent = {...pendingCloses.ids};

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(storedWhenSent, {remoteSessionId});
      // Confirmed: nothing is left behind.
      expect(pendingCloses.ids, isEmpty);
      expect(pendingCloses.removed, [remoteSessionId]);
      await bloc.close();
    });

    test(
      'only the exact session is ever sent, and only once per press',
      () async {
        final bloc = await activeBloc();
        final gate = Completer<void>();
        repository.closeGate = gate.future;

        bloc.add(const RemoteSessionCloseRequested());
        await pumpEventQueue();
        bloc.add(const RemoteSessionCloseRequested());
        await pumpEventQueue();

        expect(repository.closedIds, [remoteSessionId]);
        gate.complete();
        await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
        await bloc.close();
      },
    );

    test('a timeout never brings the session back, and is retried', () async {
      final bloc = await activeBloc(bloc: quickBloc());
      final states = record(bloc);
      repository.closeFailure = const NetworkFailure();

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere(
        (state) => state is RemoteSessionEnding && state.isUnconfirmed,
      );

      // The first attempt and both retries, then the console stops asking.
      expect(repository.closedIds, hasLength(3));
      expect(states.any((state) => state.hasLiveSession), isFalse);
      expect(states.whereType<RemoteSessionEnding>(), isNotEmpty);
      expect(bloc.state.failure, isNull);
      expect(pendingCloses.ids, {remoteSessionId});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(repository.closedIds, hasLength(3));
      await bloc.close();
    });

    test('a 500 is retried and the retry confirms the close', () async {
      final bloc = await activeBloc(bloc: quickBloc());
      final states = record(bloc);
      repository.closeFailures.add(const ServerFailure());

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(repository.closedIds, hasLength(2));
      expect(states.any((state) => state.hasLiveSession), isFalse);
      expect(
        (bloc.state as RemoteSessionIdle).notice,
        kRemoteSessionFinishedNotice,
      );
      expect(pendingCloses.ids, isEmpty);
      await bloc.close();
    });

    test('a close whose answer was lost is confirmed by reading it', () async {
      final bloc = await activeBloc(bloc: quickBloc());
      // The POST reaches the backend and commits; the answer never arrives.
      repository
        ..commitCloseDespiteFailure = true
        ..closeFailures.add(const NetworkFailure());

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      // The retry got `409`, and only `CLOSED` from GET /remote-sessions/:id
      // was taken as "it is over".
      expect(repository.closedIds, hasLength(2));
      expect(repository.loadedIds, [remoteSessionId]);
      expect(
        (bloc.state as RemoteSessionIdle).notice,
        kRemoteSessionFinishedNotice,
      );
      await bloc.close();
    });

    test(
      'a 409 while the session is still live is refused, not retried',
      () async {
        final bloc = await activeBloc(bloc: quickBloc());
        repository.closeFailure = const ConflictFailure(kCloseConflictMessage);

        bloc.add(const RemoteSessionCloseRequested());
        await bloc.stream.firstWhere(
          (state) => state is RemoteSessionEnding && state.isUnconfirmed,
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(repository.closedIds, hasLength(1));
        expect(repository.loadedIds, [remoteSessionId]);
        expect(bloc.state.hasLiveSession, isFalse);
        expect((bloc.state as RemoteSessionEnding).canRetryClose, isTrue);

        // The technician may still ask: one request per press.
        repository.closeFailure = null;
        bloc.add(const RemoteSessionCloseRetryRequested());
        await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
        expect(repository.closedIds, hasLength(2));
        await bloc.close();
      },
    );

    test('a 409 for a session already closed elsewhere confirms it', () async {
      final bloc = await activeBloc();
      // The tablet closed it first: the backend reads it as CLOSED by id.
      repository
        ..current = null
        ..sessionsById[remoteSessionId] = buildRemoteSession(
          status: RemoteSessionStatus.closed,
        );

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(
        (bloc.state as RemoteSessionIdle).notice,
        kRemoteSessionFinishedNotice,
      );
      expect(bloc.state.failure, isNull);
      await bloc.close();
    });

    test('a 404 leaves nothing to close', () async {
      final bloc = await activeBloc();
      repository.closeFailure = const NotFoundFailure();

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(pendingCloses.ids, isEmpty);
      await bloc.close();
    });

    test('a 401 reaches the console and is not retried', () async {
      final bloc = await activeBloc(bloc: quickBloc());
      repository.closeFailure = const AuthFailure();

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state.lastFailure != null);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(bloc.state, isA<RemoteSessionEnding>());
      expect(bloc.state.lastFailure, isA<AuthFailure>());
      expect(repository.closedIds, hasLength(1));
      // Still finalized, and still written down for the next sign in.
      expect(pendingCloses.ids, {remoteSessionId});
      await bloc.close();
    });

    test('an old GET that still answers ACTIVE never restores it', () async {
      final bloc = await activeBloc();
      // A read leaves before FINALIZAR and comes back after it, still ACTIVE.
      final readGate = Completer<void>();
      repository.currentGate = readGate.future;
      bloc.add(const RemoteSessionRefreshRequested());
      await pumpEventQueue();
      final closeGate = Completer<void>();
      repository.closeGate = closeGate.future;

      bloc.add(const RemoteSessionCloseRequested());
      await pumpEventQueue();
      repository.currentGate = null;
      readGate.complete();
      await pumpEventQueue();

      expect(bloc.state, isA<RemoteSessionEnding>());
      expect(bloc.state.hasLiveSession, isFalse);

      closeGate.complete();
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
      await bloc.close();
    });

    test('a failed close then a read without it is reconciled', () async {
      final bloc = await activeBloc(bloc: quickBloc());
      repository.closeFailure = const NetworkFailure();
      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere(
        (state) => state is RemoteSessionEnding && state.isUnconfirmed,
      );

      // Whoever closed it — the backend after its grace period, most likely —
      // GET /remote-sessions/current no longer lists it.
      repository.current = null;
      bloc.add(const RemoteSessionRefreshRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(
        (bloc.state as RemoteSessionIdle).notice,
        kRemoteSessionFinishedNotice,
      );
      expect(pendingCloses.ids, isEmpty);
      await bloc.close();
    });

    test('remote-session:closed during FINALIZAR confirms it once', () async {
      final bloc = await activeBloc(bloc: quickBloc());
      final gate = Completer<void>();
      repository
        ..closeGate = gate.future
        ..closeFailure = const NetworkFailure();

      bloc.add(const RemoteSessionCloseRequested());
      await pumpEventQueue();
      repository.current = null;
      bloc.add(
        const RemoteSessionClosedReported(remoteSessionId, endedBy: 'DEVICE'),
      );
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      // The POST in flight fails afterwards: nothing is retried for it.
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(repository.closedIds, hasLength(1));
      expect(bloc.state, isA<RemoteSessionIdle>());
      expect(pendingCloses.ids, isEmpty);
      await bloc.close();
    });

    test('an F5 after FINALIZAR keeps it finalized and closes it', () async {
      final first = await activeBloc(bloc: quickBloc());
      repository.closeFailure = const NetworkFailure();
      first.add(const RemoteSessionCloseRequested());
      await first.stream.firstWhere(
        (state) => state is RemoteSessionEnding && state.isUnconfirmed,
      );
      await first.close();

      // The page reloads: a new BLoC, the same browser storage, and a backend
      // that still holds the session as ACTIVE.
      expect(repository.current, active);
      repository.closeFailure = null;
      final reloaded = buildBloc();
      final states = record(reloaded);
      reloaded.add(const RemoteSessionStarted());
      await reloaded.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(states.any((state) => state.hasLiveSession), isFalse);
      expect(states.whereType<RemoteSessionEnding>(), isNotEmpty);
      expect(repository.closedIds.last, remoteSessionId);
      expect(pendingCloses.ids, isEmpty);
      await reloaded.close();
    });

    test('signing in again never brings it back', () async {
      final bloc = await activeBloc(bloc: quickBloc());
      repository.closeFailure = const NetworkFailure();
      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere(
        (state) => state is RemoteSessionEnding && state.isUnconfirmed,
      );
      final states = record(bloc);

      bloc
        ..add(const RemoteSessionCleared())
        ..add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionEnding);

      expect(states.any((state) => state.hasLiveSession), isFalse);
      repository.closeFailure = null;
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
      expect(repository.current, isNull);
      await bloc.close();
    });

    test(
      'an activation answered after FINALIZAR never reactivates it',
      () async {
        repository.current = buildRemoteSession();
        final bloc = buildBloc()..add(const RemoteSessionStarted());
        await bloc.stream.firstWhere(
          (state) => state is RemoteSessionConnecting,
        );
        final activation = Completer<void>();
        final close = Completer<void>();
        repository
          ..activateGate = activation.future
          ..closeGate = close.future;
        final states = record(bloc);

        bloc.add(const RemoteSessionActivationRequested(remoteSessionId));
        await pumpEventQueue();
        bloc.add(const RemoteSessionCloseRequested());
        await pumpEventQueue();
        // The activation commits and its GET answers ACTIVE.
        activation.complete();
        await pumpEventQueue();

        expect(bloc.state, isA<RemoteSessionEnding>());
        final afterClose = states.skipWhile(
          (state) => state is! RemoteSessionEnding,
        );
        expect(afterClose.any((state) => state.hasLiveSession), isFalse);
        close.complete();
        await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
        await bloc.close();
      },
    );

    test('no new assistance starts while the close is pending', () async {
      final bloc = await activeBloc();
      final gate = Completer<void>();
      repository.closeGate = gate.future;
      bloc.add(const RemoteSessionCloseRequested());
      await pumpEventQueue();

      bloc.add(const RemoteSessionCreateRequested(requestId));
      await pumpEventQueue();

      expect(repository.createdSupportRequestIds, isEmpty);
      gate.complete();
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
      await bloc.close();
    });

    test('a confirmed close lets a new assistance start normally', () async {
      final bloc = await activeBloc();
      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
      await pumpEventQueue();

      const newSessionId = '5a6b7c8d-1111-4222-8333-944455556666';
      repository.createResponse = buildRemoteSession(
        id: newSessionId,
        supportRequestId: 'another-request',
      );
      bloc.add(const RemoteSessionCreateRequested('another-request'));
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      expect(bloc.state.session!.id, newSessionId);
      expect(repository.closedIds, [remoteSessionId]);
      await bloc.close();
    });

    test('the notice can be dismissed', () async {
      final bloc = await activeBloc();
      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere(
        (state) => state is RemoteSessionIdle && state.notice != null,
      );

      bloc.add(const RemoteSessionNoticeDismissed());
      await bloc.stream.firstWhere(
        (state) => state is RemoteSessionIdle && state.notice == null,
      );
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
      expect(bloc.state.failure!.message, kRemoteSessionRefreshFailedNotice);
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

  group('a closed session stays closed', () {
    final active = buildRemoteSession(
      status: RemoteSessionStatus.active,
      connectedAt: DateTime.utc(2026, 3, 11, 9, 35, 12),
    );

    Future<RemoteSessionBloc> activeBloc() async {
      repository.current = active;
      final bloc = buildBloc()..add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionActive);
      return bloc;
    }

    test('a confirmed close followed by a failed GET stays closed', () async {
      final bloc = await activeBloc();
      repository.currentFailure = const NetworkFailure();

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
      await pumpEventQueue();

      expect(repository.closedIds, [remoteSessionId]);
      // The GET after the close was made, and failed ...
      expect(repository.currentCount, 2);
      // ... and does not bring back the session the backend just closed.
      expect(bloc.state, isA<RemoteSessionIdle>());
      expect(bloc.state.hasLiveSession, isFalse);
      // The close stands: nothing to retry, nothing to alarm the user with.
      expect(bloc.state.failure, isNull);
      await bloc.close();
    });

    test('a confirmed close followed by a 401 still reports the 401', () async {
      final bloc = await activeBloc();
      repository.currentFailure = const AuthFailure();

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state.lastFailure != null);

      expect(bloc.state, isA<RemoteSessionIdle>());
      expect(bloc.state.lastFailure, isA<AuthFailure>());
      await bloc.close();
    });

    test('a confirmed close ends the session before the GET answers', () async {
      final bloc = await activeBloc();
      final gate = Completer<void>();
      repository.currentGate = gate.future;

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      expect(bloc.state.hasLiveSession, isFalse);
      gate.complete();
      await pumpEventQueue();
      expect(bloc.state, isA<RemoteSessionIdle>());
      await bloc.close();
    });

    test('a later read that still shows it never restores it', () async {
      final bloc = await activeBloc();
      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
      await pumpEventQueue();

      // A backend replica, a cache, a bug: whatever answers with the closed
      // session as live is wrong, because a closed session never reopens.
      repository.current = active;
      bloc.add(const RemoteSessionRefreshRequested());
      await pumpEventQueue();

      expect(bloc.state, isA<RemoteSessionIdle>());
      await bloc.close();
    });

    test('remote-session:closed ends it at once, before REST', () async {
      final bloc = await activeBloc();
      final gate = Completer<void>();
      repository.currentGate = gate.future;

      bloc.add(
        const RemoteSessionClosedReported(remoteSessionId, endedBy: 'SYSTEM'),
      );
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);

      // REST is still read, but the assistance did not wait for it.
      expect(repository.currentCount, 2);
      gate.complete();
      await pumpEventQueue();
      expect(bloc.state, isA<RemoteSessionIdle>());
      await bloc.close();
    });

    for (final endedBy in [
      'TECHNICIAN',
      'DEVICE',
      'SYSTEM',
      'SOMETHING',
      null,
    ]) {
      test('remote-session:closed endedBy=$endedBy means the same', () async {
        final bloc = await activeBloc();
        repository.current = null;

        bloc.add(
          RemoteSessionClosedReported(remoteSessionId, endedBy: endedBy),
        );
        await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
        await pumpEventQueue();

        expect(bloc.state.hasLiveSession, isFalse);
        expect(bloc.state.failure, isNull);
        await bloc.close();
      });
    }

    test('remote-session:closed and a failing GET: still closed', () async {
      final bloc = await activeBloc();
      repository.currentFailure = const NetworkFailure();

      bloc.add(const RemoteSessionClosedReported(remoteSessionId));
      await pumpEventQueue();

      expect(bloc.state, isA<RemoteSessionIdle>());
      expect(bloc.state.hasLiveSession, isFalse);
      await bloc.close();
    });

    test('remote-session:closed for another id leaves the session', () async {
      final bloc = await activeBloc();

      bloc.add(const RemoteSessionClosedReported('another-session'));
      await pumpEventQueue();

      expect(bloc.state, isA<RemoteSessionActive>());
      expect(bloc.state.session!.id, remoteSessionId);
      // It still triggered a read: REST decides.
      expect(repository.currentCount, 2);
      await bloc.close();
    });

    test('an old GET answering ACTIVE after the close is dropped', () async {
      final bloc = await activeBloc();
      final gate = Completer<void>();
      repository.currentGate = gate.future;

      // A GET leaves while the backend still has the session ACTIVE ...
      bloc.add(const RemoteSessionRefreshRequested());
      await pumpEventQueue();
      expect(repository.currentCount, 2);
      // ... the backend closes it and says so ...
      repository.current = null;
      bloc.add(const RemoteSessionClosedReported(remoteSessionId));
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
      // ... and the old GET comes back with what it read: ACTIVE.
      gate.complete();
      await pumpEventQueue();

      expect(bloc.state, isA<RemoteSessionIdle>());
      // Its answer was dropped, and the read was made again.
      expect(repository.currentCount, 3);
      await bloc.close();
    });

    test(
      'a close that failed after remote-session:closed stays closed',
      () async {
        final bloc = await activeBloc();
        final gate = Completer<void>();
        repository
          ..closeGate = gate.future
          ..closeFailure = const NetworkFailure();

        bloc.add(const RemoteSessionCloseRequested());
        await bloc.stream.firstWhere((state) => state.isBusy);
        bloc.add(const RemoteSessionClosedReported(remoteSessionId));
        await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
        gate.complete();
        await pumpEventQueue();

        // A failure of a close that is no longer needed restores nothing.
        expect(bloc.state, isA<RemoteSessionIdle>());
        await bloc.close();
      },
    );

    test('a new session after a legitimate close is shown', () async {
      final bloc = await activeBloc();
      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
      await pumpEventQueue();

      repository.createResponse = buildRemoteSession(
        id: 'second-session',
        supportRequestId: 'second-request',
      );
      bloc.add(const RemoteSessionCreateRequested('second-request'));
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);

      expect(bloc.state.session!.id, 'second-session');
      await bloc.close();
    });
  });

  group('concurrent reads', () {
    test(
      'a refresh during a GET is not lost, and costs one more GET',
      () async {
        repository.current = buildRemoteSession();
        final bloc = buildBloc()..add(const RemoteSessionStarted());
        await bloc.stream.firstWhere(
          (state) => state is RemoteSessionConnecting,
        );
        final gate = Completer<void>();
        repository.currentGate = gate.future;

        bloc.add(const RemoteSessionRefreshRequested());
        await pumpEventQueue();
        expect(repository.currentCount, 2);
        // The tablet closes it while the GET travels; three triggers arrive.
        repository.current = null;
        bloc
          ..add(const RemoteSessionRefreshRequested())
          ..add(const RemoteSessionRefreshRequested())
          ..add(const RemoteSessionRefreshRequested());
        await pumpEventQueue();
        // Never two GETs at the same time.
        expect(repository.currentCount, 2);

        repository.currentGate = null;
        gate.complete();
        await pumpEventQueue();

        // One follow-up for the whole burst, and its answer is the one shown.
        expect(repository.currentCount, 3);
        expect(bloc.state, isA<RemoteSessionIdle>());
        await bloc.close();
      },
    );

    test(
      'a 401 arriving on a superseded read still reaches the console',
      () async {
        repository.current = buildRemoteSession();
        final bloc = buildBloc()..add(const RemoteSessionStarted());
        await bloc.stream.firstWhere(
          (state) => state is RemoteSessionConnecting,
        );
        final gate = Completer<void>();
        repository
          ..currentGate = gate.future
          ..currentFailure = const AuthFailure();

        bloc.add(const RemoteSessionRefreshRequested());
        await pumpEventQueue();
        bloc.add(const RemoteSessionRefreshRequested());
        await pumpEventQueue();
        gate.complete();
        await bloc.stream.firstWhere((state) => state.lastFailure != null);

        expect(bloc.state.lastFailure, isA<AuthFailure>());
        expect(repository.currentCount, 2);
        await bloc.close();
      },
    );

    test('a read answered after signing out is not applied', () async {
      repository.current = buildRemoteSession();
      final bloc = buildBloc()..add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);
      final gate = Completer<void>();
      repository.currentGate = gate.future;

      bloc.add(const RemoteSessionRefreshRequested());
      await pumpEventQueue();
      bloc.add(const RemoteSessionCleared());
      await bloc.stream.firstWhere((state) => state is RemoteSessionInitial);
      gate.complete();
      await pumpEventQueue();

      expect(bloc.state, isA<RemoteSessionInitial>());
      await bloc.close();
    });

    test('a read during a close in flight keeps the session ended', () async {
      repository.current = buildRemoteSession(
        status: RemoteSessionStatus.active,
      );
      final bloc = buildBloc()..add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionActive);
      final gate = Completer<void>();
      repository.closeGate = gate.future;

      bloc.add(const RemoteSessionCloseRequested());
      await bloc.stream.firstWhere((state) => state.isBusy);
      bloc.add(const RemoteSessionRefreshRequested());
      await pumpEventQueue();

      // The read answered ACTIVE, and that does not undo FINALIZAR.
      expect(repository.currentCount, 2);
      expect(bloc.state, isA<RemoteSessionEnding>());
      expect((bloc.state as RemoteSessionEnding).isConfirming, isTrue);

      gate.complete();
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
      await bloc.close();
    });

    test('a read during a create in flight keeps the start visible', () async {
      repository.current = null;
      final bloc = buildBloc()..add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionIdle);
      final gate = Completer<void>();
      repository.createGate = gate.future;

      bloc.add(const RemoteSessionCreateRequested(requestId));
      await bloc.stream.firstWhere(
        (state) => state is RemoteSessionIdle && state.isStarting,
      );
      bloc.add(const RemoteSessionRefreshRequested());
      await pumpEventQueue();

      expect((bloc.state as RemoteSessionIdle).isStarting, isTrue);
      bloc.add(const RemoteSessionCreateRequested(requestId));
      await pumpEventQueue();
      expect(repository.createdSupportRequestIds, [requestId]);

      gate.complete();
      await bloc.stream.firstWhere((state) => state is RemoteSessionConnecting);
      await bloc.close();
    });
  });

  group('verification', () {
    test(
      'a failed read leaves the session unverified until one succeeds',
      () async {
        repository.current = buildRemoteSession(
          status: RemoteSessionStatus.active,
        );
        final bloc = buildBloc()..add(const RemoteSessionStarted());
        await bloc.stream.firstWhere((state) => state is RemoteSessionActive);
        expect(bloc.state.isVerified, isTrue);

        repository.currentFailure = const NetworkFailure();
        bloc.add(const RemoteSessionRefreshRequested());
        await bloc.stream.firstWhere((state) => state.failure != null);
        // Kept on screen, not confirmed.
        expect(bloc.state, isA<RemoteSessionActive>());
        expect(bloc.state.isVerified, isFalse);

        // Hiding the banner confirms nothing.
        bloc.add(const RemoteSessionNoticeDismissed());
        await bloc.stream.firstWhere((state) => state.failure == null);
        expect(bloc.state.isVerified, isFalse);

        repository
          ..currentFailure = null
          ..currentFailureAfterFirstRead = null;
        bloc.add(const RemoteSessionRefreshRequested());
        await bloc.stream.firstWhere((state) => state.isVerified);
        expect(bloc.state, isA<RemoteSessionActive>());
        await bloc.close();
      },
    );

    test(
      'an authority check is answered only by a read started after it',
      () async {
        repository.current = buildRemoteSession(
          status: RemoteSessionStatus.active,
        );
        final bloc = buildBloc()..add(const RemoteSessionStarted());
        await bloc.stream.firstWhere((state) => state is RemoteSessionActive);
        expect(bloc.state.answeredAuthorityCheck, 0);
        final gate = Completer<void>();
        repository.currentGate = gate.future;

        // A read leaves first; the check is asked for while it travels.
        bloc.add(const RemoteSessionRefreshRequested());
        await pumpEventQueue();
        bloc.add(const RemoteSessionAuthorityCheckRequested(7));
        await pumpEventQueue();
        expect(bloc.state.answeredAuthorityCheck, 0);

        repository.currentGate = null;
        gate.complete();
        await bloc.stream.firstWhere(
          (state) => state.answeredAuthorityCheck == 7,
        );

        // The first read could not answer it: a second one did.
        expect(repository.currentCount, 3);
        expect(bloc.state, isA<RemoteSessionActive>());
        await bloc.close();
      },
    );

    test('a failed read does not answer an authority check', () async {
      repository.current = buildRemoteSession(
        status: RemoteSessionStatus.active,
      );
      final bloc = buildBloc()..add(const RemoteSessionStarted());
      await bloc.stream.firstWhere((state) => state is RemoteSessionActive);
      repository.currentFailure = const NetworkFailure();

      bloc.add(const RemoteSessionAuthorityCheckRequested(3));
      await bloc.stream.firstWhere((state) => state.failure != null);

      expect(bloc.state.answeredAuthorityCheck, 0);
      expect(bloc.state.isVerified, isFalse);
      await bloc.close();
    });
  });
}
