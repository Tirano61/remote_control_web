import '../../../../core/error/result.dart';
import '../entities/remote_session.dart';
import '../repositories/remote_session_repository.dart';

/// Starts the assistance for a support request the device already accepted.
///
/// Nothing identifying the technician or the device is sent: the backend
/// derives both from the token and from the support request. A technician may
/// hold only one live session, so a second call answers `409` and the caller
/// must reconcile with `GET /remote-sessions/current`.
class CreateRemoteSession {
  const CreateRemoteSession({required RemoteSessionRepository repository})
    : _repository = repository;

  final RemoteSessionRepository _repository;

  Future<Result<RemoteSession>> call({required String supportRequestId}) =>
      _repository.create(supportRequestId: supportRequestId);
}
