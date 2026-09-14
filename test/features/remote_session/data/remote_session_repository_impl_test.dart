import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/core/error/result.dart';
import 'package:remote_control_web/core/network/api_exception.dart';
import 'package:remote_control_web/features/remote_session/data/repositories/remote_session_repository_impl.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';

import '../../../support/console_test_doubles.dart';
import '../../../support/remote_session_test_doubles.dart';

void main() {
  late FakeRemoteSessionsRemoteDataSource remote;
  late InMemoryUserTokenProvider tokenProvider;
  late RemoteSessionRepositoryImpl repository;

  setUp(() {
    remote = FakeRemoteSessionsRemoteDataSource();
    tokenProvider = InMemoryUserTokenProvider();
    repository = RemoteSessionRepositoryImpl(
      remoteDataSource: remote,
      tokenProvider: tokenProvider,
    );
  });

  group('authentication', () {
    test('every call carries the stored User JWT', () async {
      remote.current = buildRemoteSession();

      await repository.loadCurrent();
      await repository.create(supportRequestId: requestId);
      await repository.close(id: remoteSessionId);

      expect(remote.currentTokens, ['user-jwt']);
      expect(remote.createCalls.single.token, 'user-jwt');
      expect(remote.closeCalls.single.token, 'user-jwt');
    });

    test('no stored token is treated exactly like a rejected one', () async {
      tokenProvider.token = null;

      expect(await repository.loadCurrent(), isA<Failed<RemoteSession?>>());
      expect(
        (await repository.loadCurrent() as Failed<RemoteSession?>).failure,
        isA<AuthFailure>(),
      );
      // Nothing reached the network.
      expect(remote.currentTokens, isEmpty);
    });
  });

  group('loadCurrent', () {
    test('a live session is returned as it came', () async {
      remote.current = buildRemoteSession();

      final result = await repository.loadCurrent();

      expect(result, isA<Success<RemoteSession?>>());
      final session = (result as Success<RemoteSession?>).value!;
      expect(session.status, RemoteSessionStatus.connecting);
      expect(session.isLive, isTrue);
    });

    test('no live session is a success carrying null', () async {
      remote.current = null;

      final result = await repository.loadCurrent();

      expect(result, isA<Success<RemoteSession?>>());
      expect((result as Success<RemoteSession?>).value, isNull);
    });

    test('401 becomes an AuthFailure', () async {
      remote.currentError = const HttpApiException(401);

      final result = await repository.loadCurrent();

      expect((result as Failed<RemoteSession?>).failure, isA<AuthFailure>());
    });

    test('403 becomes a ForbiddenFailure with a readable message', () async {
      remote.currentError = const HttpApiException(403);

      final result = await repository.loadCurrent();

      final failure = (result as Failed<RemoteSession?>).failure;
      expect(failure, isA<ForbiddenFailure>());
      expect(failure.message, contains('permisos'));
    });

    test('an unreachable backend becomes a NetworkFailure', () async {
      remote.currentError = const NetworkApiException();

      final result = await repository.loadCurrent();

      expect((result as Failed<RemoteSession?>).failure, isA<NetworkFailure>());
    });
  });

  group('create', () {
    test('passes the support request id through', () async {
      await repository.create(supportRequestId: requestId);

      expect(remote.createCalls.single.supportRequestId, requestId);
    });

    test('409 becomes a ConflictFailure the console can reconcile', () async {
      remote.createError = const HttpApiException(409);

      final result = await repository.create(supportRequestId: requestId);

      final failure = (result as Failed<RemoteSession>).failure;
      expect(failure, isA<ConflictFailure>());
      expect(failure.message, kCreateConflictMessage);
    });

    test('404 says the request is gone or not ours', () async {
      remote.createError = const HttpApiException(404);

      final result = await repository.create(supportRequestId: requestId);

      expect((result as Failed<RemoteSession>).failure, isA<NotFoundFailure>());
    });

    test('400 becomes a ValidationFailure', () async {
      remote.createError = const HttpApiException(400);

      final result = await repository.create(supportRequestId: 'not-a-uuid');

      expect(
        (result as Failed<RemoteSession>).failure,
        isA<ValidationFailure>(),
      );
    });

    test('no backend message string ever reaches the user', () async {
      remote.createError = const HttpApiException(409);

      final result = await repository.create(supportRequestId: requestId);

      final message = (result as Failed<RemoteSession>).failure.message;
      expect(message, isNot(contains('409')));
      expect(message, isNot(contains('Exception')));
    });
  });

  group('close', () {
    test('closes by id', () async {
      await repository.close(id: remoteSessionId);

      expect(remote.closeCalls.single.id, remoteSessionId);
    });

    test('409 becomes a ConflictFailure', () async {
      remote.closeError = const HttpApiException(409);

      final result = await repository.close(id: remoteSessionId);

      final failure = (result as Failed<RemoteSession>).failure;
      expect(failure, isA<ConflictFailure>());
      expect(failure.message, kCloseConflictMessage);
    });

    test('404 becomes a NotFoundFailure', () async {
      remote.closeError = const HttpApiException(404);

      final result = await repository.close(id: remoteSessionId);

      expect((result as Failed<RemoteSession>).failure, isA<NotFoundFailure>());
    });

    test('5xx becomes a ServerFailure', () async {
      remote.closeError = const HttpApiException(500);

      final result = await repository.close(id: remoteSessionId);

      expect((result as Failed<RemoteSession>).failure, isA<ServerFailure>());
    });
  });
}
