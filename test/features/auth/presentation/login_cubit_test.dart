import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/auth/domain/entities/user_session.dart';
import 'package:remote_control_web/features/auth/domain/usecases/log_in.dart';
import 'package:remote_control_web/features/auth/presentation/bloc/login/login_cubit.dart';

import '../../../support/auth_test_doubles.dart';

void main() {
  late FakeAuthRemoteDataSource remote;
  late InMemoryUserTokenStorage storage;
  late List<UserSession> established;

  LoginCubit buildCubit() {
    final repository = AuthRepositoryImpl(
      remoteDataSource: remote,
      tokenStorage: storage,
    );
    return LoginCubit(
      logIn: LogIn(repository: repository),
      onSessionEstablished: established.add,
    );
  }

  setUp(() {
    remote = FakeAuthRemoteDataSource();
    storage = InMemoryUserTokenStorage();
    established = [];
  });

  test('starts in the initial state', () {
    expect(buildCubit().state.status, LoginStatus.initial);
  });

  test('submitting → success hands the session over exactly once', () async {
    remote.loginResponse = adminSession;
    final cubit = buildCubit();

    final emitted = expectLater(
      cubit.stream.map((s) => s.status),
      emitsInOrder([LoginStatus.submitting, LoginStatus.success]),
    );

    await cubit.submit(email: 'admin@google.com', password: 'Abc12345');
    await emitted;

    expect(established.single.user.email, 'admin@google.com');
    expect(storage.token, 'admin-jwt');
  });

  test('a wrong password stays on the form with a safe message', () async {
    remote.loginError = unauthorized;
    final cubit = buildCubit();

    await cubit.submit(email: 'admin@google.com', password: 'Wrong12345');

    expect(cubit.state.status, LoginStatus.failure);
    expect(cubit.state.errorMessage, 'Email o contraseña incorrectos.');
    expect(established, isEmpty);
    expect(storage.token, isNull);
  });

  test('a user without admin/tecnico is refused and the token removed', () async {
    remote.loginResponse = plainUserSession;
    final cubit = buildCubit();

    await cubit.submit(email: 'usuario@example.com', password: 'Abc12345');

    expect(cubit.state.status, LoginStatus.failure);
    expect(cubit.state.errorMessage, kTechnicianConsoleAccessDeniedMessage);
    expect(established, isEmpty);
    expect(storage.token, isNull);
  });

  test('a network failure shows a connection message', () async {
    remote.loginError = networkDown;
    final cubit = buildCubit();

    await cubit.submit(email: 'admin@google.com', password: 'Abc12345');

    expect(cubit.state.status, LoginStatus.failure);
    expect(cubit.state.errorMessage, contains('No se pudo conectar'));
  });

  test('local validation never reaches the backend', () async {
    final cubit = buildCubit();

    await cubit.submit(email: 'nope', password: 'Abc12345');

    expect(cubit.state.status, LoginStatus.failure);
    expect(remote.loginCalls, isEmpty);
  });

  test('editing the form clears the previous error', () async {
    remote.loginError = unauthorized;
    final cubit = buildCubit();

    await cubit.submit(email: 'admin@google.com', password: 'Wrong12345');
    cubit.errorDismissed();

    expect(cubit.state.status, LoginStatus.initial);
    expect(cubit.state.errorMessage, isNull);
  });

  test('a second submit while one is in flight is ignored', () async {
    remote.loginResponse = adminSession;
    final cubit = buildCubit();

    final first = cubit.submit(email: 'admin@google.com', password: 'Abc12345');
    final second = cubit.submit(email: 'admin@google.com', password: 'Abc12345');
    await Future.wait([first, second]);

    expect(remote.loginCalls, hasLength(1));
  });
}
