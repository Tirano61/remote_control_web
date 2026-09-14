import 'package:flutter/material.dart';

import '../../../../core/presentation/format/elapsed_label.dart';
import '../../../../core/presentation/widgets/presence_indicator.dart';
import '../../domain/entities/support_request.dart';
import '../../domain/entities/support_request_status.dart';

/// One support request of the queue.
///
/// The action is shown only for a request that could legally be taken. It is a
/// UI hint: the backend performs the real conditional transition and answers
/// `409` when the state moved on.
class SupportRequestCard extends StatelessWidget {
  const SupportRequestCard({
    required this.request,
    required this.now,
    this.isMine = false,
    this.onAssign,
    this.isAssigning = false,
    this.isAssignBlocked = false,
    this.extraAction,
    super.key,
  });

  final SupportRequest request;
  final DateTime now;

  /// Whether the request is assigned to the signed-in technician.
  final bool isMine;

  /// `null` when the request cannot be taken from this console.
  final VoidCallback? onAssign;

  /// This request's `assign` call is in flight.
  final bool isAssigning;

  /// Another request is being assigned right now.
  final bool isAssignBlocked;

  /// Action contributed by the console for this request, if any.
  ///
  /// It is a plain widget so that this feature stays unaware of what the action
  /// does: today it is "INICIAR ASISTENCIA", which belongs to the remote
  /// session feature and must not be imported from here.
  final Widget? extraAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final device = request.device;
    final isOnline = device?.isOnline;
    final canAssign =
        onAssign != null && !isAssigning && !isAssignBlocked && (isOnline ?? true);

    return Container(
      key: ValueKey('support_request_${request.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.deviceLabel,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      device?.publicId ?? request.deviceId,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (device?.model != null)
                      Text(
                        device!.model!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _StatusChip(status: request.status),
                  if (isOnline != null) ...[
                    const SizedBox(height: 8),
                    PresenceIndicator(isOnline: isOnline, compact: true),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Solicitada ${elapsedLabel(request.createdAt, now)} '
            '(${shortTimestamp(request.createdAt)})',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text('Estado: ${request.status.description}'),
          if (request.technician != null && !request.isWaiting)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                isMine
                    ? 'Asignada a ti'
                    : 'Asignada a ${request.technician!.name}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          if (isOnline == false && request.isWaiting)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'El dispositivo está desconectado: no puede tomarse hasta que '
                'vuelva a estar online.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          if (onAssign != null) ...[
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: ValueKey('assign_button_${request.id}'),
                onPressed: canAssign ? onAssign : null,
                icon: isAssigning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.support_agent),
                label: const Text('TOMAR SOLICITUD'),
              ),
            ),
          ],
          ?extraAction,
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final SupportRequestStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (status.wireValue) {
      'WAITING' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      'ASSIGNED' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      'ACCEPTED' => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      'REJECTED' => (scheme.errorContainer, scheme.onErrorContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        status.label,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: foreground),
      ),
    );
  }
}
