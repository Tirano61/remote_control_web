import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../bloc/remote_session/remote_session_bloc.dart';

/// "INICIAR ASISTENCIA" for a support request the tablet already accepted.
///
/// It takes the support request id and nothing else, so the support feature
/// never has to know that remote sessions exist: the console passes this widget
/// down to the request card.
///
/// The button disappears while an assistance is open. The backend allows one
/// live session per technician and answers `409` to a second one, so offering
/// it for another request would only produce an error the user cannot fix.
class StartAssistanceButton extends StatelessWidget {
  const StartAssistanceButton({required this.supportRequestId, super.key});

  final String supportRequestId;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RemoteSessionBloc, RemoteSessionState>(
      builder: (context, state) {
        if (state.hasLiveSession) return const SizedBox.shrink();

        final isStarting =
            state is RemoteSessionIdle && state.isStartingFor(supportRequestId);
        // Until `GET /remote-sessions/current` has answered, the console does
        // not know whether this technician already has an assistance open.
        final isUnknown =
            state is RemoteSessionInitial || state is RemoteSessionLoading;

        return Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              key: ValueKey('start_assistance_button_$supportRequestId'),
              onPressed: state.isBusy || isUnknown
                  ? null
                  : () => context.read<RemoteSessionBloc>().add(
                      RemoteSessionCreateRequested(supportRequestId),
                    ),
              icon: isStarting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_circle_outline),
              label: const Text('INICIAR ASISTENCIA'),
            ),
          ),
        );
      },
    );
  }
}
