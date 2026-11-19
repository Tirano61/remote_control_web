import '../../../../core/error/failure.dart';
import '../../../../core/error/result.dart';
import '../entities/remote_session.dart';
import '../entities/remote_session_close_outcome.dart';
import '../repositories/remote_session_repository.dart';

/// Asks the backend to end one remote session and finds out whether it did.
///
/// `POST /remote-sessions/:id/close` names the exact session, so a retry can
/// never close a newer assistance by mistake. It is not idempotent: a session
/// already closed answers `409`, which is exactly what a retry after a lost
/// answer receives. A `409` therefore never decides anything by itself — the
/// session is read by id (`GET /remote-sessions/:id`, closed ones included),
/// and only `CLOSED` there is taken as "it is over".
///
/// Nothing is decided from a human readable message: only status codes, as
/// the [Failure] categories carry them, and the session status.
class CloseRemoteSession {
  const CloseRemoteSession({required RemoteSessionRepository repository})
    : _repository = repository;

  final RemoteSessionRepository _repository;

  Future<RemoteSessionCloseOutcome> call({
    required String remoteSessionId,
  }) async {
    final result = await _repository.close(id: remoteSessionId);
    switch (result) {
      case Success<RemoteSession>():
        return const RemoteSessionCloseConfirmed();
      case Failed<RemoteSession>(:final failure):
        return switch (failure) {
          // Does not exist, or is not this technician's: nothing to close.
          NotFoundFailure() => const RemoteSessionCloseConfirmed(),
          ConflictFailure() => _confirmAfterConflict(remoteSessionId, failure),
          ForbiddenFailure() ||
          ValidationFailure() => RemoteSessionCloseRefused(failure),
          // No network, a timeout, a 5xx, an unreadable answer, a rejected
          // token: the close may have been committed or not.
          _ => RemoteSessionCloseUnconfirmed(failure),
        };
    }
  }

  /// A `409` is "already closed" or "could not be completed": the session
  /// itself says which.
  Future<RemoteSessionCloseOutcome> _confirmAfterConflict(
    String remoteSessionId,
    Failure conflict,
  ) async {
    final result = await _repository.load(id: remoteSessionId);
    switch (result) {
      case Success<RemoteSession>(:final value):
        if (value.isLive) return RemoteSessionCloseRefused(conflict);
        return const RemoteSessionCloseConfirmed();
      case Failed<RemoteSession>(:final failure):
        if (failure is NotFoundFailure) {
          return const RemoteSessionCloseConfirmed();
        }
        return RemoteSessionCloseUnconfirmed(failure);
    }
  }
}
