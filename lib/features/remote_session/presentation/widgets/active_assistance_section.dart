import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/presentation/widgets/console_feedback.dart';
import '../../../../core/presentation/widgets/console_section.dart';
import '../../../../core/presentation/widgets/presence_indicator.dart';
import '../../../technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import '../../../technician_realtime/presentation/bloc/technician_realtime/technician_realtime_bloc.dart';
import '../../../webrtc/domain/entities/webrtc_connection_state.dart';
import '../../../webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';
import '../../domain/entities/remote_session.dart';
import '../bloc/remote_session/remote_session_bloc.dart';

/// "ASISTENCIA REMOTA" block of the console.
///
/// It is shown only when the backend says there is a live session, and it takes
/// the top of the page: an assistance in progress is the most important thing
/// on screen.
///
/// The realtime channel is described in plain words. Namespaces, rooms,
/// handshakes and acknowledgements are implementation details the technician
/// has no use for.
class ActiveAssistanceSection extends StatelessWidget {
  const ActiveAssistanceSection({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RemoteSessionBloc, RemoteSessionState>(
      builder: (context, state) => switch (state) {
        RemoteSessionLive() => _LiveAssistance(
          key: const Key('active_assistance_section'),
          state: state,
        ),
        // Nothing is open, but something went wrong while finding that out.
        RemoteSessionFailure(:final failure) => _AssistanceProblem(
          message: failure.message,
        ),
        RemoteSessionIdle(:final failure) when failure != null =>
          _AssistanceProblem(message: failure.message),
        // No live session: the dashboard looks the way it normally does.
        _ => const SizedBox.shrink(),
      },
    );
  }
}

class _LiveAssistance extends StatelessWidget {
  const _LiveAssistance({required this.state, super.key});

  final RemoteSessionLive state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bloc = context.read<RemoteSessionBloc>();
    final RemoteSession session = state.session;
    final device = session.device;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: ConsoleSection(
        title: 'ASISTENCIA REMOTA',
        subtitle: session.status.label,
        trailing: device == null
            ? null
            : PresenceIndicator(isOnline: device.isOnline, compact: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.failure != null) ...[
              ConsoleBanner(
                key: const Key('remote_session_error_banner'),
                message: state.failure!.message,
                isError: true,
                onDismiss: () =>
                    bloc.add(const RemoteSessionNoticeDismissed()),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('remote_session_retry_button'),
                  onPressed: () =>
                      bloc.add(const RemoteSessionRefreshRequested()),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('REINTENTAR'),
                ),
              ),
              const SizedBox(height: 6),
            ],
            Text(
              session.deviceLabel,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (session.devicePublicId != null)
              Text(
                session.devicePublicId!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (session.isConnecting) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    'Estado: ${session.status.description}',
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const _AssistanceChannelStatus(),
            const SizedBox(height: 6),
            const _RemoteConnectionStatus(),
            const SizedBox(height: 18),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('close_remote_session_button'),
                // Disabled while the close is in flight: the backend answers
                // `409` to a second one, and the user should not have to see
                // that.
                onPressed: state.isClosing
                    ? null
                    : () => bloc.add(const RemoteSessionCloseRequested()),
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                icon: state.isClosing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.stop_circle_outlined),
                label: const Text('FINALIZAR ASISTENCIA'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line telling the technician whether the assistance channel is ready.
///
/// It merges two different facts — the connection and the join — into the only
/// thing the user cares about: can this assistance work right now.
class _AssistanceChannelStatus extends StatelessWidget {
  const _AssistanceChannelStatus();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocBuilder<SignalingJoinBloc, SignalingJoinState>(
      builder: (context, joinState) {
        final isReady = joinState is SignalingJoined;
        final hasProblem = joinState is SignalingUnavailable;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              isReady
                  ? Icons.link
                  : hasProblem
                  ? Icons.link_off
                  : Icons.more_horiz,
              size: 18,
              color: hasProblem
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                key: const Key('assistance_channel_status'),
                isReady
                    ? 'Canal de asistencia establecido.'
                    : hasProblem
                    ? 'El canal de asistencia no está disponible.'
                    : 'Preparando el canal de asistencia...',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: hasProblem
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (hasProblem)
              TextButton(
                key: const Key('signaling_retry_button'),
                onPressed: () => _retry(context, joinState),
                child: const Text('REINTENTAR'),
              ),
          ],
        );
      },
    );
  }

  /// A refused join is never retried automatically, so the only way back is an
  /// explicit request from the user.
  void _retry(BuildContext context, SignalingUnavailable state) {
    final connectionId = context
        .read<TechnicianRealtimeBloc>()
        .state
        .connectionId;
    if (connectionId == null) return;
    context.read<SignalingJoinBloc>().add(
      SignalingJoinRequested(
        remoteSessionId: state.remoteSessionId,
        connectionId: connectionId,
        force: true,
      ),
    );
  }
}

/// One line telling the technician whether the browser reached the tablet.
///
/// It reports the WebRTC negotiation, which is a different fact from both the
/// `RemoteSession` status above it and the signaling channel next to it: the
/// session stays `CONNECTING` — the backend has no other transition today —
/// while the peer connection may already be established.
///
/// Nothing of the negotiation itself is shown: no SDP, no candidate, no state
/// machine. The technician needs to know whether it works, not how.
class _RemoteConnectionStatus extends StatelessWidget {
  const _RemoteConnectionStatus();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocBuilder<WebRtcSessionBloc, WebRtcSessionState>(
      builder: (context, state) {
        // Nothing to say yet: no assistance, or the tablet has not entered the
        // room. The line above is the one that talks about that.
        if (state is WebRtcIdle || state is WebRtcClosed) {
          return const SizedBox.shrink();
        }

        final isEstablished = state.isConnected && state.isControlChannelOpen;
        final hasFailed = state is WebRtcFailed;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isEstablished
                      ? Icons.cast_connected
                      : hasFailed
                      ? Icons.error_outline
                      : Icons.sync,
                  size: 18,
                  color: hasFailed
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    key: const Key('webrtc_status'),
                    isEstablished
                        ? 'Conexión remota establecida'
                        : hasFailed
                        ? 'No se pudo establecer la conexión remota.'
                        : 'Conectando con el dispositivo...',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: hasFailed
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            // Debug builds only, and deliberately shallow: the two facts a
            // developer needs while bringing WebRTC up, and nothing that could
            // leak an SDP, a candidate or a token.
            if (kDebugMode) ...[
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Text(
                  key: const Key('webrtc_debug_status'),
                  'WebRTC: ${_peerLabel(state)} · '
                  'Canal de control: ${_channelLabel(state.controlChannelState)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  static String _peerLabel(WebRtcSessionState state) => switch (state) {
    WebRtcPreparing() => 'preparando',
    WebRtcOffering() => 'ofreciendo',
    WebRtcConnecting() => 'conectando',
    WebRtcConnected() => 'conectado',
    WebRtcInterrupted() => 'interrumpido',
    WebRtcFailed() => 'fallido',
    WebRtcClosed() => 'cerrado',
    WebRtcIdle() => 'inactivo',
  };

  static String _channelLabel(WebRtcDataChannelState state) => switch (state) {
    WebRtcDataChannelState.connecting => 'abriendo',
    WebRtcDataChannelState.open => 'abierto',
    WebRtcDataChannelState.closing => 'cerrando',
    WebRtcDataChannelState.closed => 'cerrado',
  };
}

/// Compact error shown when the state of the assistance could not be read or a
/// start was refused. It never hides the rest of the console.
class _AssistanceProblem extends StatelessWidget {
  const _AssistanceProblem({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<RemoteSessionBloc>();

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConsoleBanner(
            key: const Key('remote_session_error_banner'),
            message: message,
            isError: true,
            onDismiss: () => bloc.add(const RemoteSessionNoticeDismissed()),
          ),
          TextButton.icon(
            key: const Key('remote_session_retry_button'),
            onPressed: () => bloc.add(const RemoteSessionRefreshRequested()),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('REINTENTAR'),
          ),
        ],
      ),
    );
  }
}
