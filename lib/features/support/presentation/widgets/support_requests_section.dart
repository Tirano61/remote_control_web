import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/presentation/format/elapsed_label.dart';
import '../../../../core/presentation/widgets/console_feedback.dart';
import '../../../../core/presentation/widgets/console_section.dart';
import '../../domain/entities/support_request.dart';
import '../bloc/support_requests/support_requests_bloc.dart';
import 'support_request_card.dart';

/// "SOLICITUDES DE ASISTENCIA" block of the technician console.
///
/// Shows the `WAITING` queue first, then the requests already taken by the
/// signed-in technician, and keeps the closed ones in a collapsed history.
class SupportRequestsSection extends StatelessWidget {
  const SupportRequestsSection({
    required this.technicianId,
    required this.now,
    super.key,
  });

  /// Identity of the signed-in user, taken from the authenticated backend
  /// response. Used only to decide what to display, never as authorisation.
  final String technicianId;

  /// Clock used for the "solicitada hace ..." labels.
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SupportRequestsBloc, SupportRequestsState>(
      builder: (context, state) {
        final bloc = context.read<SupportRequestsBloc>();

        return ConsoleSection(
          title: 'SOLICITUDES DE ASISTENCIA',
          subtitle: switch (state) {
            SupportRequestsLoaded(:final waiting) => waiting.isEmpty
                ? 'Sin solicitudes en espera'
                : '${waiting.length} en espera',
            _ => null,
          },
          trailing: _RefreshButton(
            isBusy:
                state is SupportRequestsLoading ||
                (state is SupportRequestsLoaded && state.isRefreshing),
            onPressed: () => bloc.add(const SupportRequestsRefreshRequested()),
          ),
          child: switch (state) {
            SupportRequestsInitial() ||
            SupportRequestsLoading() => const _SectionProgress(),
            SupportRequestsFailure(:final failure) => ConsoleErrorState(
              message:
                  'No se pudieron cargar las solicitudes. ${failure.message}',
              onRetry: () => bloc.add(const SupportRequestsRefreshRequested()),
            ),
            SupportRequestsLoaded() => _Queue(
              state: state,
              technicianId: technicianId,
              now: now,
            ),
          },
        );
      },
    );
  }
}

class _Queue extends StatelessWidget {
  const _Queue({
    required this.state,
    required this.technicianId,
    required this.now,
  });

  final SupportRequestsLoaded state;
  final String technicianId;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<SupportRequestsBloc>();
    final waiting = state.waiting;
    final mine = state.assignedTo(technicianId);
    final others = state.requests
        .where(
          (request) =>
              request.isActive &&
              !request.isWaiting &&
              !request.isAssignedTo(technicianId),
        )
        .toList(growable: false);
    final history = state.history;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.failure != null) ...[
          ConsoleBanner(
            key: const Key('support_error_banner'),
            message: state.failure!.message,
            isError: true,
            onDismiss: () => bloc.add(const SupportRequestsNoticeDismissed()),
          ),
          const SizedBox(height: 12),
        ],
        if (state.notice != null) ...[
          ConsoleBanner(
            key: const Key('support_notice_banner'),
            message: state.notice!,
            isError: false,
            onDismiss: () => bloc.add(const SupportRequestsNoticeDismissed()),
          ),
          const SizedBox(height: 12),
        ],
        if (waiting.isEmpty)
          const ConsoleEmptyState(
            message: 'No hay solicitudes esperando un técnico.',
            icon: Icons.headset_mic_outlined,
          )
        else
          for (final request in waiting)
            SupportRequestCard(
              request: request,
              now: now,
              onAssign: () =>
                  bloc.add(SupportRequestAssignRequested(request.id)),
              isAssigning: state.isAssigningRequest(request.id),
              isAssignBlocked:
                  state.isAssigning && !state.isAssigningRequest(request.id),
            ),
        if (mine.isNotEmpty) ...[
          const SizedBox(height: 8),
          _GroupTitle(title: 'ASIGNADAS A TI', count: mine.length),
          for (final request in mine)
            SupportRequestCard(request: request, now: now, isMine: true),
        ],
        if (others.isNotEmpty) ...[
          const SizedBox(height: 8),
          _GroupTitle(
            title: 'EN CURSO CON OTROS TÉCNICOS',
            count: others.length,
          ),
          for (final request in others)
            SupportRequestCard(request: request, now: now),
        ],
        if (history.isNotEmpty) ...[
          const SizedBox(height: 8),
          _History(requests: history, now: now),
        ],
      ],
    );
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle({required this.title, required this.count});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Text(
        '$title ($count)',
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

/// Terminal requests, kept out of the working queue but still reachable.
class _History extends StatelessWidget {
  const _History({required this.requests, required this.now});

  final List<SupportRequest> requests;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const Key('support_history_tile'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          'HISTORIAL (${requests.length})',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0.6,
          ),
        ),
        children: [
          for (final request in requests)
            ListTile(
              key: ValueKey('history_${request.id}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(request.deviceLabel),
              subtitle: Text(
                '${request.status.description} · '
                '${elapsedLabel(request.createdAt, now)}',
              ),
              trailing: Text(
                request.status.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.isBusy, required this.onPressed});

  final bool isBusy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    key: const Key('support_refresh_button'),
    onPressed: isBusy ? null : onPressed,
    icon: isBusy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.refresh, size: 18),
    label: const Text('ACTUALIZAR'),
  );
}

class _SectionProgress extends StatelessWidget {
  const _SectionProgress();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 28),
    child: Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
  );
}
