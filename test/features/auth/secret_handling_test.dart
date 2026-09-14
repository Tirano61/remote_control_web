import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/core/error/result.dart';
import 'package:remote_control_web/core/network/api_exception.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/auth/domain/entities/user_session.dart';
import 'package:remote_control_web/features/auth/domain/usecases/log_in.dart';
import 'package:remote_control_web/features/auth/domain/usecases/log_out.dart';
import 'package:remote_control_web/features/auth/domain/usecases/restore_session.dart';
import 'package:remote_control_web/features/auth/presentation/bloc/login/login_cubit.dart';
import 'package:remote_control_web/features/auth/presentation/bloc/user_session/user_session_bloc.dart';

import '../../support/auth_test_doubles.dart';

const String secretToken = 'eyJhbGciOiJIUzI1NiJ9.SUPER-SECRET-JWT.signature';
const String secretPassword = 'SuperSecret123';

void main() {
  final session = buildSession(token: secretToken);

  group('toString never leaks the User JWT', () {
    test('UserSession', () {
      expect(session.toString(), isNot(contains(secretToken)));
      expect(session.toString(), contains('redacted'));
    });

    test('AuthenticatedUser', () {
      expect(session.user.toString(), isNot(contains(secretToken)));
    });

    test('Result wrappers', () {
      expect(Success(session).toString(), isNot(contains(secretToken)));
      expect(
        const Failed<UserSession>(AuthFailure()).toString(),
        isNot(contains(secretToken)),
      );
    });

    test('UserSessionBloc events and states', () {
      expect(
        UserSessionSignedIn(session).toString(),
        isNot(contains(secretToken)),
      );
      expect(
        UserSessionAuthenticated(session).toString(),
        isNot(contains(secretToken)),
      );
    });

    test('LoginState carries neither the password nor the token', () {
      const state = LoginState(status: LoginStatus.submitting);

      expect(state.toString(), isNot(contains(secretPassword)));
      expect(state.toString(), isNot(contains(secretToken)));
      expect(state.props, isNot(contains(secretPassword)));
    });

    test('transport errors expose only the status code', () {
      expect(const HttpApiException(401).toString(), contains('401'));
      expect(
        const HttpApiException(401).toString(),
        isNot(contains(secretToken)),
      );
      expect(const NetworkApiException().toString(), 'NetworkApiException');
    });
  });

  test('a full auth flow prints neither the password nor the JWT', () async {
    final remote = FakeAuthRemoteDataSource()
      ..loginResponse = session
      ..checkStatusResponse = session;
    final storage = InMemoryUserTokenStorage();
    final repository = AuthRepositoryImpl(
      remoteDataSource: remote,
      tokenStorage: storage,
    );

    final printed = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
    };

    await runZoned(
      () async {
        final cubit = LoginCubit(
          logIn: LogIn(repository: repository),
          onSessionEstablished: (_) {},
        );
        await cubit.submit(
          email: 'admin@google.com',
          password: secretPassword,
        );
        await cubit.close();

        final bloc = UserSessionBloc(
          restoreSession: RestoreSession(repository: repository),
          logOut: LogOut(repository: repository),
        );
        bloc.add(const UserSessionStarted());
        await bloc.stream.firstWhere((s) => s is UserSessionAuthenticated);
        bloc.add(const UserSessionSignOutRequested());
        await bloc.stream.firstWhere((s) => s is UserSessionUnauthenticated);
        await bloc.close();
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );

    debugPrint = originalDebugPrint;

    final output = printed.join('\n');
    expect(output, isNot(contains(secretPassword)));
    expect(output, isNot(contains(secretToken)));
    expect(output, isNot(contains('Authorization')));
  });

  test('only the token is persisted, never the password', () async {
    final remote = FakeAuthRemoteDataSource()..loginResponse = session;
    final storage = InMemoryUserTokenStorage();
    final repository = AuthRepositoryImpl(
      remoteDataSource: remote,
      tokenStorage: storage,
    );

    await LogIn(repository: repository)(
      email: 'admin@google.com',
      password: secretPassword,
    );

    expect(storage.token, secretToken);
    expect(storage.token, isNot(contains(secretPassword)));
  });
}
