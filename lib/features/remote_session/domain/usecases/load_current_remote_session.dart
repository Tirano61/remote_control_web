import '../../../../core/error/result.dart';
import '../entities/remote_session.dart';
import '../repositories/remote_session_repository.dart';

/// Reads the live remote session of the authenticated technician.
///
/// This is how the console recovers its state: after a page reload, after a
/// `remote-session:closed` notice, after a create conflict and after a close.
/// No session id is kept in browser storage — the backend is asked instead.
class LoadCurrentRemoteSession {
  const LoadCurrentRemoteSession({required RemoteSessionRepository repository})
    : _repository = repository;

  final RemoteSessionRepository _repository;

  /// `null` means "this technician has no live session", which is a normal
  /// answer and never an error.
  Future<Result<RemoteSession?>> call() => _repository.loadCurrent();
}
