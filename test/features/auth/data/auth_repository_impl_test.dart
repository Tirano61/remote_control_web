import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/core/error/result.dart';
import 'package:remote_control_web/core/network/api_exception.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/auth/domain/entities/user_session.dart';

import '../../../support/auth_test_doubles.dart';

void main() {
  late FakeAuthRemoteDataSource remote;
  late InMemoryUserTokenStorage storage;
  late AuthRepositoryImpl repository;

  setUp(() {
    remote = FakeAuthRemoteDataSource();
    storage = InMemoryUserTokenStorage();
    repository = AuthRepositoryImpl(
      remoteDataSource: remote,
      tokenStorage: storage,
    );
  });

  group('logIn', () {
    test('persists the User JWT on success', () async {
      remote.loginResponse = adminSession;

      final result = await repository.logIn(
        email: 'admin@google.com',
        password: 'Abc12345',
      );

      expect(result, isA<Success<UserSession>>());
      expect(storage.token, 'admin-jwt');
      expect(remote.loginCalls.single.email, 'admin@google.com');
    });

    test('maps 401 to AuthFailure and persists nothing', () async {
      remote.loginError = unauthorized;

      final result = await repository.logIn(
        email: 'admin@google.com',
        password: 'Wrong12345',
      );

      expect(result, isA<Failed<UserSession>>());
      expect((result as Failed<UserSession>).failure, isA<AuthFailure>());
      expect(storage.token, isNull);
      expect(storage.saveCount, 0);
    });

    test('maps 400 to ValidationFailure', () async {
      remote.loginError = const HttpApiException(400);

      final result = await repository.logIn(email: 'a@b.com', password: 'x');

      expect(
        (result as Failed<UserSession>).failure,
        isA<ValidationFailure>(),
      );
    });

    test('maps a transport error to NetworkFailure', () async {
      remote.loginError = networkDown;

      final result = await repository.logIn(
        email: 'a@b.com',
        password: 'Abc12345',
      );

      expect((result as Failed<UserSession>).failure, isA<NetworkFailure>());
    });

    test('maps 5xx to ServerFailure', () async {
      remote.loginError = serverError;

      final result = await repository.logIn(
        email: 'a@b.com',
        password: 'Abc12345',
      );

      expect((result as Failed<UserSession>).failure, isA<ServerFailure>());
    });
  });

  group('checkStatus', () {
    test('fails without calling the backend when nothing is stored', () async {
      final result = await repository.checkStatus();

      expect((result as Failed<UserSession>).failure, isA<AuthFailure>());
      expect(remote.checkStatusTokens, isEmpty);
    });

    test('sends the stored token and stores the renewed one', () async {
      storage.token = 'stored-jwt';
      remote.checkStatusResponse = buildSession(token: 'renewed-jwt');

      final result = await repository.checkStatus();

      expect(result, isA<Success<UserSession>>());
      expect(remote.checkStatusTokens.single, 'stored-jwt');
      expect(storage.token, 'renewed-jwt');
    });

    test('clears the stored token on 401', () async {
      storage.token = 'expired-jwt';
      remote.checkStatusError = unauthorized;

      final result = await repository.checkStatus();

      expect((result as Failed<UserSession>).failure, isA<AuthFailure>());
      expect(storage.token, isNull);
      expect(storage.clearCount, 1);
    });

    test('keeps the stored token on a network failure', () async {
      storage.token = 'valid-jwt';
      remote.checkStatusError = networkDown;

      final result = await repository.checkStatus();

      expect((result as Failed<UserSession>).failure, isA<NetworkFailure>());
      expect(storage.token, 'valid-jwt');
      expect(storage.clearCount, 0);
    });

    test('keeps the stored token on a 5xx', () async {
      storage.token = 'valid-jwt';
      remote.checkStatusError = serverError;

      final result = await repository.checkStatus();

      expect((result as Failed<UserSession>).failure, isA<ServerFailure>());
      expect(storage.token, 'valid-jwt');
      expect(storage.clearCount, 0);
    });
  });

  test('logOut clears the stored token and calls no endpoint', () async {
    storage.token = 'admin-jwt';

    await repository.logOut();

    expect(storage.token, isNull);
    expect(remote.loginCalls, isEmpty);
    expect(remote.checkStatusTokens, isEmpty);
  });
}
