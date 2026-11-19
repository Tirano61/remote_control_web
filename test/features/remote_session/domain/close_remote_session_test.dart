import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_close_outcome.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/close_remote_session.dart';

import '../../../support/remote_session_test_doubles.dart';

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

  test('200 is a confirmed close, and nothing else is asked', () async {
    expect(await close(), const RemoteSessionCloseConfirmed());
    expect(repository.closedIds, [remoteSessionId]);
    expect(repository.loadedIds, isEmpty);
  });

  test('404 leaves nothing to close: not this technician\'s', () async {
    repository.closeFailure = const NotFoundFailure();

    expect(await close(), const RemoteSessionCloseConfirmed());
  });

  test('409 is never decided by itself: CLOSED by id confirms it', () async {
    repository
      ..closeFailure = const ConflictFailure()
      ..current = null
      ..sessionsById[remoteSessionId] = buildRemoteSession(
        status: RemoteSessionStatus.closed,
      );

    expect(await close(), const RemoteSessionCloseConfirmed());
    expect(repository.loadedIds, [remoteSessionId]);
  });

  test('409 with the session still live is a refusal', () async {
    repository.closeFailure = const ConflictFailure();

    final outcome = await close();

    expect(outcome, isA<RemoteSessionCloseRefused>());
    expect(
      (outcome as RemoteSessionCloseRefused).failure,
      isA<ConflictFailure>(),
    );
  });

  test('409 and a read that cannot be made: nobody can say', () async {
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

  test('409 then 404 by id: nothing of this technician is left', () async {
    repository
      ..closeFailure = const ConflictFailure()
      ..current = null;

    expect(await close(), const RemoteSessionCloseConfirmed());
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

  test('a retry after a lost answer meets the 409 and is confirmed', () async {
    // The first POST commits; its answer never arrives.
    repository
      ..commitCloseDespiteFailure = true
      ..closeFailures.add(const NetworkFailure());

    expect(await close(), isA<RemoteSessionCloseUnconfirmed>());
    expect(await close(), const RemoteSessionCloseConfirmed());
    expect(repository.closedIds, [remoteSessionId, remoteSessionId]);
    expect(repository.loadedIds, [remoteSessionId]);
  });
}
