import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/login/login_cubit.dart';
import '../bloc/user_session/user_session_bloc.dart';
import '../widgets/auth_scaffold.dart';

/// Technician/admin login form.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  // The password lives only in this controller for as long as the field is on
  // screen. It is never persisted, never put into a BLoC state and never logged.
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;

    context.read<LoginCubit>().submit(
      email: _emailController.text,
      password: _passwordController.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    final validator = context.read<LoginCubit>().validator;
    final sessionState = context.watch<UserSessionBloc>().state;
    final notice = sessionState is UserSessionUnauthenticated
        ? sessionState.notice
        : null;

    return BlocBuilder<LoginCubit, LoginState>(
      builder: (context, state) {
        final isBusy =
            state.status == LoginStatus.submitting ||
            state.status == LoginStatus.success;

        return AuthScaffold(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const AppWordmark(),
                const SizedBox(height: 32),
                if (notice != null) ...[
                  AuthMessage(message: notice),
                  const SizedBox(height: 16),
                ],
                if (state.errorMessage != null) ...[
                  AuthMessage(message: state.errorMessage!),
                  const SizedBox(height: 16),
                ],
                TextFormField(
                  key: const Key('login_email_field'),
                  controller: _emailController,
                  enabled: !isBusy,
                  autofocus: true,
                  autocorrect: false,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.alternate_email),
                  ),
                  validator: validator.validateEmail,
                  onChanged: (_) => context.read<LoginCubit>().errorDismissed(),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('login_password_field'),
                  controller: _passwordController,
                  enabled: !isBusy,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    labelText: 'Contraseña',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: _obscurePassword ? 'Mostrar' : 'Ocultar',
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: validator.validatePassword,
                  onChanged: (_) => context.read<LoginCubit>().errorDismissed(),
                  onFieldSubmitted: (_) {
                    if (!isBusy) _submit();
                  },
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    key: const Key('login_submit_button'),
                    onPressed: isBusy ? null : _submit,
                    child: state.status == LoginStatus.submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('INICIAR SESIÓN'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
