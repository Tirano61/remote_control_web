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
/// Raised by the retry button, after a refused command or relay, and after a
/// `remote-session:active` notice. A request that arrives while a read is in
/// flight is never lost: that read is treated as stale and one more follows it.
final class RemoteSessionRefreshRequested extends RemoteSessionEvent {
  const RemoteSessionRefreshRequested();
}

/// The console needs to know whether the backend still holds its session
/// *now*: the `/technicians` socket came back, or the peer connection failed.
///
/// It is a refresh with a receipt. [checkId] is a number the console chose; the
/// state reports, in [RemoteSessionState.answeredAuthorityCheck], the highest
/// check a successful read that *started after it was asked for* has answered.
/// Until then the console treats the session as unconfirmed, whatever the state
/// on screen still says.
final class RemoteSessionAuthorityCheckRequested extends RemoteSessionEvent {
  const RemoteSessionAuthorityCheckRequested(this.checkId);

  final int checkId;

  @override
  List<Object?> get props => [checkId];
}

/// `remote-session:closed` arrived for [remoteSessionId].
///
/// The backend emits it only after the close committed, and a closed session
/// never reopens. So a session with this id is over for good: if it is the one
/// on screen it ends here, without waiting for REST, and no read — one already
/// in flight included — may bring it back. REST is still read afterwards, for
/// whatever else it has to say.
///
/// [endedBy] is kept raw and only logged: every value means the same thing.
final class RemoteSessionClosedReported extends RemoteSessionEvent {
  const RemoteSessionClosedReported(this.remoteSessionId, {this.endedBy});

  final String remoteSessionId;
  final String? endedBy;

  @override
  List<Object?> get props => [remoteSessionId, endedBy];
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
///
/// The decision is final for this console the moment it is taken: the
/// session stops being live here at once, before the backend is even asked,
/// and no answer — a failed close included — gives it back.
final class RemoteSessionCloseRequested extends RemoteSessionEvent {
  const RemoteSessionCloseRequested();
}

/// Ask the backend once more to close the session this console finalized.
///
/// Raised by REINTENTAR on an unconfirmed close, and by the console when the
/// socket comes back — a network that returned is worth a new attempt. It
/// starts a fresh, bounded schedule; it does nothing while a close is in
/// flight, and nothing at all once the close was confirmed.
final class RemoteSessionCloseRetryRequested extends RemoteSessionEvent {
  const RemoteSessionCloseRetryRequested();
}

/// The planned close attempt for [remoteSessionId] is due.
final class _RemoteSessionCloseRetryDue extends RemoteSessionEvent {
  const _RemoteSessionCloseRetryDue(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The user dismissed the error banner of the assistance view, or the notice
/// that an assistance was finalized.
final class RemoteSessionNoticeDismissed extends RemoteSessionEvent {
  const RemoteSessionNoticeDismissed();
}

/// The user session ended: forget everything held in memory.
///
/// Sessions this console finalized are the exception: they stay finalized —
/// in memory and in the pending close store — so that signing in again never
/// brings one back as a controllable assistance.
final class RemoteSessionCleared extends RemoteSessionEvent {
  const RemoteSessionCleared();
}
