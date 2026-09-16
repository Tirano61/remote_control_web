import '../../../../core/error/result.dart';
import '../entities/remote_session.dart';
import '../repositories/remote_session_repository.dart';

/// Confirms to the backend that the assistance really started.
///
/// It is never a user action: the console asks for it by itself, and only once
/// the technician end is genuinely able to work — the peer connection is
/// `connected` and the `control` data channel is `open`. Signaling readiness,
/// a delivered offer or a half connected ICE session are not enough, because
/// none of them means the two ends can exchange anything.
///
/// The response already carries the `ACTIVE` session, but the caller still
/// re-reads `GET /remote-sessions/current` afterwards: REST is the source of
/// truth and `CONNECTING -> ACTIVE` is never performed locally.
class ActivateRemoteSession {
  const ActivateRemoteSession({required RemoteSessionRepository repository})
    : _repository = repository;

  final RemoteSessionRepository _repository;

  Future<Result<RemoteSession>> call({required String remoteSessionId}) =>
      _repository.activate(id: remoteSessionId);
}
