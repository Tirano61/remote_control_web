import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/app/composition_root.dart';
import 'package:remote_control_web/app/remote_control_app.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/auth/domain/usecases/log_in.dart';
import 'package:remote_control_web/features/auth/presentation/pages/connection_error_page.dart';
import 'package:remote_control_web/features/auth/presentation/pages/dashboard_page.dart';
import 'package:remote_control_web/features/auth/presentation/pages/login_page.dart';
import 'package:remote_control_web/features/auth/presentation/pages/startup_page.dart';

import '../../../support/auth_test_doubles.dart';

void main() {
  late FakeAuthRemoteDataSource remote;
  late InMemoryUserTokenStorage storage;

  setUp(() {
    remote = FakeAuthRemoteDataSource();
    storage = InMemoryUserTokenStorage();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    final dependencies = AppDependencies(
      config: const AppConfig(backendBaseUrl: 'http://localhost:3000'),
      authRepository: AuthRepositoryImpl(
        remoteDataSource: remote,
        tokenStorage: storage,
      ),
    );
    await tester.pumpWidget(RemoteControlApp(dependencies: dependencies));
  }

  Future<void> fillAndSubmitLogin(
    WidgetTester tester, {
    required String email,
    required String password,
  }) async {
    await tester.enterText(find.byKey(const Key('login_email_field')), email);
    await tester.enterText(
      find.byKey(const Key('login_password_field')),
      password,
    );
    await tester.tap(find.byKey(const Key('login_submit_button')));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the startup screen before the session is resolved', (
    tester,
  ) async {
    // The first frame is rendered before the stored-token lookup resolves.
    await pumpApp(tester);

    expect(find.byType(StartupPage), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.byType(StartupPage), findsNothing);
  });

  testWidgets('startup without a stored token lands on the login page', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('REMOTE CONTROL'), findsOneWidget);
    expect(find.text('INICIAR SESIÓN'), findsOneWidget);
    expect(remote.checkStatusTokens, isEmpty);
  });

  testWidgets('a successful admin login opens the dashboard', (tester) async {
    remote.loginResponse = adminSession;
    await pumpApp(tester);
    await tester.pumpAndSettle();

    await fillAndSubmitLogin(
      tester,
      email: 'admin@google.com',
      password: 'Abc12345',
    );

    expect(find.byType(DashboardPage), findsOneWidget);
    expect(find.text('Administrador'), findsWidgets);
    expect(find.text('admin@google.com'), findsOneWidget);
    expect(find.text('Sesión iniciada'), findsOneWidget);
    expect(storage.token, 'admin-jwt');
  });

  testWidgets('a successful tecnico login opens the dashboard', (tester) async {
    remote.loginResponse = technicianSession;
    await pumpApp(tester);
    await tester.pumpAndSettle();

    await fillAndSubmitLogin(
      tester,
      email: 'tecnico@example.com',
      password: 'Abc12345',
    );

    expect(find.byType(DashboardPage), findsOneWidget);
    expect(find.text('Ana Torres'), findsOneWidget);
    expect(find.text('Técnico'), findsOneWidget);
    expect(storage.token, 'tecnico-jwt');
  });

  testWidgets('a wrong password keeps the user on the login page', (
    tester,
  ) async {
    remote.loginError = unauthorized;
    await pumpApp(tester);
    await tester.pumpAndSettle();

    await fillAndSubmitLogin(
      tester,
      email: 'admin@google.com',
      password: 'Wrong12345',
    );

    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(DashboardPage), findsNothing);
    expect(find.text('Email o contraseña incorrectos.'), findsOneWidget);
    expect(storage.token, isNull);
  });

  testWidgets('a user without admin/tecnico cannot enter the console', (
    tester,
  ) async {
    remote.loginResponse = plainUserSession;
    await pumpApp(tester);
    await tester.pumpAndSettle();

    await fillAndSubmitLogin(
      tester,
      email: 'usuario@example.com',
      password: 'Abc12345',
    );

    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text(kTechnicianConsoleAccessDeniedMessage), findsOneWidget);
    expect(storage.token, isNull);
  });

  testWidgets('a persisted valid token restores the session on startup', (
    tester,
  ) async {
    storage.token = 'stored-jwt';
    remote.checkStatusResponse = adminSession;

    await pumpApp(tester);
    await tester.pumpAndSettle();

    expect(find.byType(DashboardPage), findsOneWidget);
    expect(remote.checkStatusTokens.single, 'stored-jwt');
    // check-status returns a renewed token, which replaces the stored one.
    expect(storage.token, 'admin-jwt');
  });

  testWidgets('an expired token is discarded and the login page is shown', (
    tester,
  ) async {
    storage.token = 'expired-jwt';
    remote.checkStatusError = unauthorized;

    await pumpApp(tester);
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
    expect(storage.token, isNull);
  });

  testWidgets('a network failure at startup keeps the token and offers retry', (
    tester,
  ) async {
    storage.token = 'valid-jwt';
    remote.checkStatusError = networkDown;

    await pumpApp(tester);
    await tester.pumpAndSettle();

    expect(find.byType(ConnectionErrorPage), findsOneWidget);
    expect(find.text('No se pudo conectar con el servidor.'), findsOneWidget);
    expect(find.text('REINTENTAR'), findsOneWidget);
    expect(storage.token, 'valid-jwt');
  });

  testWidgets('retrying after a network failure restores the session', (
    tester,
  ) async {
    storage.token = 'valid-jwt';
    remote.checkStatusError = networkDown;
    remote.checkStatusResponseAfterFirstCall = adminSession;

    await pumpApp(tester);
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionErrorPage), findsOneWidget);

    await tester.tap(find.text('REINTENTAR'));
    await tester.pumpAndSettle();

    expect(find.byType(DashboardPage), findsOneWidget);
    expect(remote.checkStatusTokens, hasLength(2));
  });

  testWidgets('logout clears the token and returns to the login page', (
    tester,
  ) async {
    storage.token = 'stored-jwt';
    remote.checkStatusResponse = adminSession;

    await pumpApp(tester);
    await tester.pumpAndSettle();
    expect(find.byType(DashboardPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('logout_button')));
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsOneWidget);
    expect(storage.token, isNull);
  });

  testWidgets('the login form validates locally before any request', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('login_submit_button')));
    await tester.pumpAndSettle();

    expect(find.text('Introduce tu email.'), findsOneWidget);
    expect(find.text('Introduce tu contraseña.'), findsOneWidget);
    expect(remote.loginCalls, isEmpty);
  });
}
