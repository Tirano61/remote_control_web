import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/composition_root.dart';
import '../bloc/login/login_cubit.dart';
import '../bloc/user_session/user_session_bloc.dart';
import 'connection_error_page.dart';
import 'dashboard_page.dart';
import 'login_page.dart';
import 'startup_page.dart';

/// Single navigation point of the application.
///
/// The visible screen is a pure function of [UserSessionBloc]'s state, so no
/// router is needed yet.
class AuthGate extends StatelessWidget {
  const AuthGate({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UserSessionBloc, UserSessionState>(
      builder: (context, state) => switch (state) {
        UserSessionCheckingStoredSession() => const StartupPage(),
        UserSessionAuthenticating() => ConnectionErrorPage(
          message: 'Comprobando la sesión...',
          isRetrying: true,
        ),
        UserSessionConnectionError(:final message) => ConnectionErrorPage(
          message: message,
        ),
        UserSessionUnauthenticated() => BlocProvider<LoginCubit>(
          create: (_) => dependencies.createLoginCubit(
            onSessionEstablished: (session) => context
                .read<UserSessionBloc>()
                .add(UserSessionSignedIn(session)),
          ),
          child: const LoginPage(),
        ),
        UserSessionAuthenticated(:final user) => DashboardPage(user: user),
      },
    );
  }
}
