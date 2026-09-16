part of 'remote_session_bloc.dart';

sealed class RemoteSessionEvent extends Equatable {
  const RemoteSessionEvent();

  @override
  List<Object?> get props => const [];
}

/// The console opened with an authenticated session.
///
/// It always asks the backend, whatever is in memory: `GET /remote-sessions/
/// current` is the only source of truth for "do I have an assistance open".
final class RemoteSessionStarted extends RemoteSessionEvent {
  const RemoteSessionStarted();
}

/// Re-read `GET /remote-sessions/current`.
///
/// Raised after a close, after a `remote-session:closed` notice and by the
/// retry button when the state could not be refreshed.
final class RemoteSessionRefreshRequested extends RemoteSessionEvent {
  const RemoteSessionRefreshRequested();
}

/// The technician pressed "INICIAR ASISTENCIA" on an accepted request.
final class RemoteSessionCreateRequested extends RemoteSessionEvent {
  const RemoteSessionCreateRequested(this.supportRequestId);

  final String supportRequestId;

  @override
  List<Object?> get props => [supportRequestId];
}

/// Everything needed for the assistance to really be running became true at
/// the same time: the session is `CONNECTING`, the peer connection is
/// `connected` and the `control` data channel is `open`.
///
/// It is raised by the console coordinator, never by a button: there is no
/// manual "activate". It names the session it was decided for, so an
/// activation can never be applied to a different one.
final class RemoteSessionActivationRequested extends RemoteSessionEvent {
  const RemoteSessionActivationRequested(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The technician pressed "FINALIZAR ASISTENCIA".
final class RemoteSessionCloseRequested extends RemoteSessionEvent {
  const RemoteSessionCloseRequested();
}

/// The user dismissed the error banner of the assistance view.
final class RemoteSessionNoticeDismissed extends RemoteSessionEvent {
  const RemoteSessionNoticeDismissed();
}

/// The user session ended: forget everything held in memory.
///
/// Nothing is persisted, so there is nothing else to clean up.
final class RemoteSessionCleared extends RemoteSessionEvent {
  const RemoteSessionCleared();
}
