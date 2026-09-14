import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/auth/domain/usecases/log_in.dart';
import 'package:remote_control_web/features/auth/domain/usecases/log_out.dart';
import 'package:remote_control_web/features/auth/domain/usecases/restore_session.dart';
import 'package:remote_control_web/features/auth/presentation/bloc/user_session/user_session_bloc.dart';

import '../../../support/auth_test_doubles.dart';

void main() {
  late FakeAuthRemoteDataSource remote;
  late InMemoryUserTokenStorage storage;

  UserSessionBloc buildBloc() {
    final repository = AuthRepositoryImpl(
      remoteDataSource: remote,
      tokenStorage: storage,
    );
    return UserSessionBloc(
      restoreSession: RestoreSession(repository: repository),
      logOut: LogOut(repository: repository),
    );
  }

  setUp(() {
    remote = FakeAuthRemoteDataSource();
    storage = InMemoryUserTokenStorage();
  });

  test('startup without a stored token goes to unauthenticated', () async {
    final bloc = buildBloc();

    expect(bloc.state, isA<UserSessionCheckingStoredSession>());

    bloc.add(const UserSessionStarted());
    await expectLater(
      bloc.stream,
      emitsInOrder([
        isA<UserSessionCheckingStoredSession>(),
        isA<UserSessionUnauthenticated>(),
      ]),
    );
    expect(remote.checkStatusTokens, isEmpty);
    await bloc.close();
  });

  test('startup with a valid stored token authenticates', () async {
    storage.token = 'stored-jwt';
    remote.checkStatusResponse = adminSession;
    final bloc = buildBloc();

    bloc.add(const UserSessionStarted());
    await expectLater(
      bloc.stream,
      emitsInOrder([
        isA<UserSessionCheckingStoredSession>(),
        isA<UserSessionAuthenticated>(),
      ]),
    );
    expect(remote.checkStatusTokens.single, 'stored-jwt');
    expect(storage.token, 'admin-jwt');
    await bloc.close();
  });

  test('an expired token clears storage and returns to login', () async {
    storage.token = 'expired-jwt';
    remote.checkStatusError = unauthorized;
    final bloc = buildBloc();

    bloc.add(const UserSessionStarted());
    await expectLater(
      bloc.stream,
      emitsInOrder([
        isA<UserSessionCheckingStoredSession>(),
        isA<UserSessionUnauthenticated>(),
      ]),
    );
    expect(storage.token, isNull);
    await bloc.close();
  });

  test('a network failure keeps the token and offers a retry', () async {
    storage.token = 'valid-jwt';
    remote.checkStatusError = networkDown;
    final bloc = buildBloc();

    bloc.add(const UserSessionStarted());
    await expectLater(
      bloc.stream,
      emitsInOrder([
        isA<UserSessionCheckingStoredSession>(),
        isA<UserSessionConnectionError>(),
      ]),
    );
    expect(storage.token, 'valid-jwt');
    await bloc.close();
  });

  test('a 5xx during check-status also keeps the token', () async {
    storage.token = 'valid-jwt';
    remote.checkStatusError = serverError;
    final bloc = buildBloc();

    bloc.add(const UserSessionStarted());
    await expectLater(
      bloc.stream,
      emitsInOrder([
        isA<UserSessionCheckingStoredSession>(),
        isA<UserSessionConnectionError>(),
      ]),
    );
    expect(storage.token, 'valid-jwt');
    await bloc.close();
  });

  test('retry after a network failure authenticates', () async {
    storage.token = 'valid-jwt';
    remote.checkStatusError = networkDown;
    remote.checkStatusResponseAfterFirstCall = adminSession;
    final bloc = buildBloc();

    bloc.add(const UserSessionStarted());
    await expectLater(
      bloc.stream,
      emitsInOrder([
        isA<UserSessionCheckingStoredSession>(),
        isA<UserSessionConnectionError>(),
      ]),
    );

    bloc.add(const UserSessionRetryRequested());
    await expectLater(
      bloc.stream,
      emitsInOrder([
        isA<UserSessionAuthenticating>(),
        isA<UserSessionAuthenticated>(),
      ]),
    );
    expect(remote.checkStatusTokens, hasLength(2));
    await bloc.close();
  });

  test('a restored user without admin/tecnico is sent back to login', () async {
    storage.token = 'user-jwt';
    remote.checkStatusResponse = plainUserSession;
    final bloc = buildBloc();

    bloc.add(const UserSessionStarted());
    await expectLater(
      bloc.stream,
      emitsInOrder([
        isA<UserSessionCheckingStoredSession>(),
        isA<UserSessionUnauthenticated>().having(
          (s) => s.notice,
          'notice',
          kTechnicianConsoleAccessDeniedMessage,
        ),
      ]),
    );
    expect(storage.token, isNull);
    await bloc.close();
  });

  test('signing in from the login form authenticates', () async {
    final bloc = buildBloc();

    bloc.add(UserSessionSignedIn(adminSession));
    await expectLater(
      bloc.stream,
      emits(
        isA<UserSessionAuthenticated>().having(
          (s) => s.user.email,
          'email',
          'admin@google.com',
        ),
      ),
    );
    await bloc.close();
  });

  test('logout clears the token and returns to login', () async {
    storage.token = 'admin-jwt';
    final bloc = buildBloc();

    bloc.add(UserSessionSignedIn(adminSession));
    await expectLater(bloc.stream, emits(isA<UserSessionAuthenticated>()));

    bloc.add(const UserSessionSignOutRequested());
    await expectLater(bloc.stream, emits(isA<UserSessionUnauthenticated>()));

    expect(storage.token, isNull);
    expect(storage.clearCount, 1);
    await bloc.close();
  });
}
