import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/user_session/user_session_bloc.dart';
import '../widgets/auth_scaffold.dart';

/// Shown when a persisted token exists but the backend could not be reached.
///
/// The token is deliberately kept: a network failure says nothing about its
/// validity.
class ConnectionErrorPage extends StatelessWidget {
  const ConnectionErrorPage({
    required this.message,
    this.isRetrying = false,
    super.key,
  });

  final String message;
  final bool isRetrying;

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppWordmark(),
          const SizedBox(height: 32),
          AuthMessage(message: message),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: isRetrying
                  ? null
                  : () => context.read<UserSessionBloc>().add(
                      const UserSessionRetryRequested(),
                    ),
              icon: isRetrying
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: const Text('REINTENTAR'),
            ),
          ),
        ],
      ),
    );
  }
}
