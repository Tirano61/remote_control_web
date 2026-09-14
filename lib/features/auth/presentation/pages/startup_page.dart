import 'package:flutter/material.dart';

import '../widgets/auth_scaffold.dart';

/// Shown while the persisted User JWT is being validated at startup.
class StartupPage extends StatelessWidget {
  const StartupPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const AuthScaffold(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppWordmark(),
          SizedBox(height: 32),
          SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          SizedBox(height: 16),
          Text('Restaurando sesión...'),
        ],
      ),
    );
  }
}
