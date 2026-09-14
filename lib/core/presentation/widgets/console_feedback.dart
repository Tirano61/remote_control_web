import 'package:flutter/material.dart';

/// Failure placeholder with a retry action.
///
/// Only the user safe `Failure.message` reaches this widget; transport details
/// never do. A failed load never ends the session: the stored User JWT is only
/// dropped on a 401.
class ConsoleErrorState extends StatelessWidget {
  const ConsoleErrorState({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.error_outline,
                color: scheme.onErrorContainer,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('REINTENTAR'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline banner for an operation result: success notice or user safe error.
class ConsoleBanner extends StatelessWidget {
  const ConsoleBanner({
    required this.message,
    required this.isError,
    this.onDismiss,
    super.key,
  });

  final String message;
  final bool isError;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = isError
        ? scheme.errorContainer
        : scheme.secondaryContainer;
    final foreground = isError
        ? scheme.onErrorContainer
        : scheme.onSecondaryContainer;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.info_outline,
            size: 20,
            color: foreground,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: TextStyle(color: foreground))),
          if (onDismiss != null)
            IconButton(
              onPressed: onDismiss,
              icon: Icon(Icons.close, size: 18, color: foreground),
              tooltip: 'Descartar',
            ),
        ],
      ),
    );
  }
}
