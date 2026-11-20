import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_close_outcome.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_ended_by.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/close_remote_session.dart';

import '../../../support/remote_session_test_doubles.dart';

const String otherRemoteSessionId = '9a7c2f10-4b3e-4d21-8f6a-1c2d3e4f5a6b';

void main() {
  late FakeRemoteSessionRepository repository;
  late CloseRemoteSession closeRemoteSession;

  setUp(() {
    repository = FakeRemoteSessionRepository()
      ..current = buildRemoteSession(status: RemoteSessionStatus.active);
    closeRemoteSession = CloseRemoteSession(repository: repository);
  });

  Future<RemoteSessionCloseOutcome> close() =>
      closeRemoteSession(remoteSessionId: remoteSessionId);

  RemoteSessionCloseConfirmed confirmed(RemoteSessionCloseOutcome outcome) {
    expect(outcome, isA<RemoteSessionCloseConfirmed>());
    return outcome as RemoteSessionCloseConfirmed;
  }

  group('200 — idempotent close', () {
    test('the first close confirms it, and nothing else is asked', () async {
      final outcome = confirmed(await close());

      expect(outcome.session?.id, remoteSessionId);
      expect(outcome.session?.endedBy, RemoteSessionEndedBy.technician);
      expect(repository.closedIds, [remoteSessionId]);
      expect(repository.loadedIds, isEmpty);
    });

    test('a repetition answers 200 with the original close', () async {
      final first = confirmed(await close());
      final second = confirmed(await close());

      expect(second.session, first.session);
      expect(second.session?.endedAt, FakeRemoteSessionRepository.closeEndedAt);
      // One transition, no follow-up read for either.
      expect(repository.closeTransitions, 1);
      expect(repository.loadedIds, isEmpty);
    });

    test('the tablet closed first: 200 keeps endedBy DEVICE', () async {
      repository.closedElsewhere(RemoteSessionEndedBy.device);

      final outcome = confirmed(await close());

      expect(outcome.session?.endedBy, RemoteSessionEndedBy.device);
      expect(outcome.session?.endedAt, DateTime.utc(2026, 3, 11, 9, 38, 5));
      expect(repository.closeTransitions, 0);
      expect(repository.loadedIds, isEmpty);
    });

    test('the backend closed first: 200 keeps endedBy SYSTEM', () async {
      repository.closedElsewhere(RemoteSessionEndedBy.system);

      final outcome = confirmed(await close());

      expect(outcome.session?.endedBy, RemoteSessionEndedBy.system);
      expect(repository.loadedIds, isEmpty);
    });

    test('a retry after a lost answer meets the 200 and confirms', () async {
      // The first POST commits; its answer never arrives.
      repository
        ..commitCloseDespiteFailure = true
        ..closeFailures.add(const NetworkFailure());

      expect(await close(), isA<RemoteSessionCloseUnconfirmed>());
      final outcome = confirmed(await close());

      expect(outcome.session?.endedBy, RemoteSessionEndedBy.technician);
      expect(repository.closedIds, [remoteSessionId, remoteSessionId]);
      expect(repository.closeTransitions, 1);
      // The 200 is the confirmation: no GET /remote-sessions/:id.
      expect(repository.loadedIds, isEmpty);
    });
  });

  group('200 that does not describe the session asked for', () {
    test('another session closed is not taken, it is read by id', () async {
      repository.closeResponse = buildRemoteSession(
        id: otherRemoteSessionId,
        status: RemoteSessionStatus.closed,
        endedAt: DateTime.utc(2026, 3, 11, 9, 40),
        endedBy: RemoteSessionEndedBy.technician,
      );

      final outcome = await close();

      // The exact session is still live: nothing is confirmed.
      expect(outcome, isA<RemoteSessionCloseUnconfirmed>());
      expect(repository.loadedIds, [remoteSessionId]);
    });

    test('a 200 still live is not a confirmation either', () async {
      repository.closeResponse = buildRemoteSession(
        status: RemoteSessionStatus.active,
      );

      expect(await close(), isA<RemoteSessionCloseUnconfirmed>());
    });

    test('a 200 without endedAt is checked by id', () async {
      repository
        ..closeResponse = buildRemoteSession(status: RemoteSessionStatus.closed)
        ..closedElsewhere(RemoteSessionEndedBy.device);

      final outcome = confirmed(await close());

      expect(outcome.session?.endedBy, RemoteSessionEndedBy.device);
      expect(repository.loadedIds, [remoteSessionId]);
    });

    test('a read by id answering another session confirms nothing', () async {
      repository
        ..closeResponse = buildRemoteSession(
          id: otherRemoteSessionId,
          status: RemoteSessionStatus.closed,
          endedAt: DateTime.utc(2026, 3, 11, 9, 40),
        )
        ..current = buildRemoteSession(
          id: otherRemoteSessionId,
          status: RemoteSessionStatus.active,
        )
        ..sessionsById[remoteSessionId] = buildRemoteSession(
          id: otherRemoteSessionId,
          status: RemoteSessionStatus.closed,
          endedAt: DateTime.utc(2026, 3, 11, 9, 40),
        );

      expect(await close(), isA<RemoteSessionCloseUnconfirmed>());
    });
  });

  group('404', () {
    test('a session that does not exist leaves nothing to close', () async {
      repository.closeFailure = const NotFoundFailure();

      final outcome = confirmed(await close());

      expect(outcome.session, isNull);
      expect(repository.loadedIds, isEmpty);
    });

    test('another technician\'s session answers the same 404', () async {
      // The backend does not tell "missing" from "not yours", live or CLOSED.
      repository
        ..closeFailure = const NotFoundFailure()
        ..current = null;

      expect(await close(), const RemoteSessionCloseConfirmed());
    });
  });

  group('409 — still live, cannot complete', () {
    test('with the session live by id it is a refusal', () async {
      repository.closeFailure = const ConflictFailure();

      final outcome = await close();

      expect(outcome, isA<RemoteSessionCloseRefused>());
      expect(
        (outcome as RemoteSessionCloseRefused).failure,
        isA<ConflictFailure>(),
      );
      expect(repository.loadedIds, [remoteSessionId]);
    });

    test('a backend predating the idempotent close: CLOSED by id '
        'still confirms it', () async {
      repository
        ..closeFailure = const ConflictFailure()
        ..closedElsewhere(RemoteSessionEndedBy.device);

      final outcome = confirmed(await close());

      expect(outcome.session?.endedBy, RemoteSessionEndedBy.device);
    });

    test('and a read that cannot be made: nobody can say', () async {
      repository
        ..closeFailure = const ConflictFailure()
        ..loadFailure = const NetworkFailure();

      final outcome = await close();

      expect(outcome, isA<RemoteSessionCloseUnconfirmed>());
      expect(
        (outcome as RemoteSessionCloseUnconfirmed).failure,
        isA<NetworkFailure>(),
      );
    });

    test('then 404 by id: nothing of this technician is left', () async {
      repository
        ..closeFailure = const ConflictFailure()
        ..current = null;

      expect(await close(), const RemoteSessionCloseConfirmed());
    });
  });

  test('a lost answer, a timeout or a 5xx are unconfirmed', () async {
    for (final failure in const <Failure>[
      NetworkFailure(),
      ServerFailure(),
      UnexpectedFailure(),
    ]) {
      repository.closeFailure = failure;

      final outcome = await close();

      expect(outcome, RemoteSessionCloseUnconfirmed(failure));
    }
    expect(repository.loadedIds, isEmpty);
  });

  test('a rejected token is unconfirmed and says so', () async {
    repository.closeFailure = const AuthFailure();

    expect(await close(), const RemoteSessionCloseUnconfirmed(AuthFailure()));
  });

  test('403 and 400 are refusals', () async {
    for (final failure in const <Failure>[
      ForbiddenFailure(),
      ValidationFailure(),
    ]) {
      repository.closeFailure = failure;

      expect(await close(), RemoteSessionCloseRefused(failure));
    }
  });
}
