import '../../../../core/error/result.dart';
import '../entities/remote_session.dart';
import '../repositories/remote_session_repository.dart';

/// Ends the assistance from the console.
///
/// The response already carries the closed session, but the console still
/// re-reads `GET /remote-sessions/current` afterwards: REST is the source of
/// truth and the local object is never promoted to `CLOSED` on its own.
class CloseRemoteSession {
  const CloseRemoteSession({required RemoteSessionRepository repository})
    : _repository = repository;

  final RemoteSessionRepository _repository;

  Future<Result<RemoteSession>> call({required String remoteSessionId}) =>
      _repository.close(id: remoteSessionId);
}
