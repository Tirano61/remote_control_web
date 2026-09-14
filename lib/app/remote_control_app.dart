import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../features/auth/presentation/bloc/user_session/user_session_bloc.dart';
import '../features/auth/presentation/pages/auth_gate.dart';
import 'composition_root.dart';

/// Application root.
///
/// Navigation is driven entirely by [UserSessionBloc]: startup check, login,
/// connection error and authenticated console.
class RemoteControlApp extends StatelessWidget {
  const RemoteControlApp({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  Widget build(BuildContext context) {
    return BlocProvider<UserSessionBloc>(
      create: (_) => dependencies.createUserSessionBloc(),
      child: MaterialApp(
        title: 'Remote Control — Panel técnico',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: AuthGate(dependencies: dependencies),
      ),
    );
  }

  ThemeData _theme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF1B6FF3),
      brightness: brightness,
    ),
  );
}
