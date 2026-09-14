import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/core/error/result.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/auth/domain/entities/user_session.dart';
import 'package:remote_control_web/features/auth/domain/usecases/log_in.dart';
import 'package:remote_control_web/features/auth/domain/usecases/log_out.dart';
import 'package:remote_control_web/features/auth/domain/usecases/restore_session.dart';

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

  group('LogIn', () {
    test('authenticates an admin and keeps the token', () async {
      remote.loginResponse = adminSession;

      final result = await LogIn(repository: repository)(
        email: 'admin@google.com',
        password: 'Abc12345',
      );

      expect(result, isA<Success<UserSession>>());
      expect((result as Success<UserSession>).value.user.isAdmin, isTrue);
      expect(storage.token, 'admin-jwt');
    });

    test('authenticates a tecnico', () async {
      remote.loginResponse = technicianSession;

      final result = await LogIn(repository: repository)(
        email: 'tecnico@example.com',
        password: 'Abc12345',
      );

      expect(result, isA<Success<UserSession>>());
      expect((result as Success<UserSession>).value.user.isTechnician, isTrue);
      expect(storage.token, 'tecnico-jwt');
    });

    test(
      'refuses a user without admin/tecnico and removes the stored token',
      () async {
        remote.loginResponse = plainUserSession;

        final result = await LogIn(repository: repository)(
          email: 'usuario@example.com',
          password: 'Abc12345',
        );

        final failure = (result as Failed<UserSession>).failure;
        expect(failure, isA<ForbiddenFailure>());
        expect(failure.message, kTechnicianConsoleAccessDeniedMessage);
        expect(storage.token, isNull);
        expect(storage.clearCount, 1);
      },
    );

    test('rejects an invalid email locally, without calling the backend', () async {
      final result = await LogIn(repository: repository)(
        email: 'not-an-email',
        password: 'Abc12345',
      );

      expect((result as Failed<UserSession>).failure, isA<ValidationFailure>());
      expect(remote.loginCalls, isEmpty);
    });

    test('rejects an empty password locally', () async {
      final result = await LogIn(repository: repository)(
        email: 'admin@google.com',
        password: '',
      );

      expect((result as Failed<UserSession>).failure, isA<ValidationFailure>());
      expect(remote.loginCalls, isEmpty);
    });

    test('trims the email before sending it', () async {
      remote.loginResponse = adminSession;

      await LogIn(repository: repository)(
        email: '  admin@google.com  ',
        password: 'Abc12345',
      );

      expect(remote.loginCalls.single.email, 'admin@google.com');
    });
  });

  group('RestoreSession', () {
    test('reports no stored session when storage is empty', () async {
      final result = await RestoreSession(repository: repository)();

      expect((result as Success).value, isA<NoStoredSession>());
      expect(remote.checkStatusTokens, isEmpty);
    });

    test('restores a session from a valid stored token', () async {
      storage.token = 'stored-jwt';
      remote.checkStatusResponse = adminSession;

      final result = await RestoreSession(repository: repository)();

      final outcome = (result as Success).value;
      expect(outcome, isA<RestoredSession>());
      expect((outcome as RestoredSession).session.user.email, 'admin@google.com');
    });

    test('fails with AuthFailure and clears storage on an expired token', () async {
      storage.token = 'expired-jwt';
      remote.checkStatusError = unauthorized;

      final result = await RestoreSession(repository: repository)();

      expect(
        (result as Failed<SessionRestoreOutcome>).failure,
        isA<AuthFailure>(),
      );
      expect(storage.token, isNull);
    });

    test('fails with NetworkFailure and keeps the token', () async {
      storage.token = 'valid-jwt';
      remote.checkStatusError = networkDown;

      final result = await RestoreSession(repository: repository)();

      expect(
        (result as Failed<SessionRestoreOutcome>).failure,
        isA<NetworkFailure>(),
      );
      expect(storage.token, 'valid-jwt');
    });

    test('refuses a restored session without admin/tecnico', () async {
      storage.token = 'user-jwt';
      remote.checkStatusResponse = plainUserSession;

      final result = await RestoreSession(repository: repository)();

      expect(
        (result as Failed<SessionRestoreOutcome>).failure,
        isA<ForbiddenFailure>(),
      );
      expect(storage.token, isNull);
    });
  });

  test('LogOut clears the persisted token', () async {
    storage.token = 'admin-jwt';

    await LogOut(repository: repository)();

    expect(storage.token, isNull);
  });
}
