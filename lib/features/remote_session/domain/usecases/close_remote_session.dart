import '../../../../core/error/failure.dart';
import '../../../../core/error/result.dart';
import '../entities/remote_session.dart';
import '../entities/remote_session_close_outcome.dart';
import '../repositories/remote_session_repository.dart';

/// Asks the backend to end one remote session and finds out whether it did.
///
/// `POST /remote-sessions/:id/close` names the exact session, so a retry can
/// never close a newer assistance by mistake. It is idempotent: the first
/// close and any repetition on a session already `CLOSED` answer `200` with
/// the session as it was closed — the original `endedBy` and `endedAt`, which
/// may be the tablet's or the backend's (`SYSTEM`) when they closed it first.
/// A `200` is therefore the confirmation, whoever closed the session, and no
/// follow-up read is made.
///
/// A `200` only confirms when it describes **the session asked for** as
/// closed: same id, `CLOSED`, `endedAt` set. Anything else is not the
/// documented answer, and the session is read by id instead
/// (`GET /remote-sessions/:id`, closed ones included).
///
/// A `409` now means the session is still live and its support request cannot
/// be completed. It is still checked by id before being taken as a refusal: a
/// backend predating the idempotent close answered `409` to a session already
/// closed, and that read is what tells the two apart.
///
/// Nothing is decided from a human readable message: only status codes, as
/// the [Failure] categories carry them, and the session itself.
class CloseRemoteSession {
  const CloseRemoteSession({required RemoteSessionRepository repository})
    : _repository = repository;

  final RemoteSessionRepository _repository;

  Future<RemoteSessionCloseOutcome> call({
    required String remoteSessionId,
  }) async {
    final result = await _repository.close(id: remoteSessionId);
    switch (result) {
      case Success<RemoteSession>(:final value):
        if (isClosedSession(value, remoteSessionId)) {
          return RemoteSessionCloseConfirmed(session: value);
        }
        // A 200 about another session, or one that is not closed: not the
        // documented answer, so it confirms nothing by itself.
        return _reconcile(
          remoteSessionId,
          whenLive: const RemoteSessionCloseUnconfirmed(UnexpectedFailure()),
        );
      case Failed<RemoteSession>(:final failure):
        return switch (failure) {
          // Does not exist, or is not this technician's: nothing to close.
          NotFoundFailure() => const RemoteSessionCloseConfirmed(),
          ConflictFailure() => _reconcile(
            remoteSessionId,
            whenLive: RemoteSessionCloseRefused(failure),
          ),
          ForbiddenFailure() ||
          ValidationFailure() => RemoteSessionCloseRefused(failure),
          // No network, a timeout, a 5xx, an unreadable answer, a rejected
          // token: the close may have been committed or not.
          _ => RemoteSessionCloseUnconfirmed(failure),
        };
    }
  }

  /// Whether [session] is the answer that confirms the close of
  /// [remoteSessionId]: that exact session, `CLOSED`, with its `endedAt`.
  ///
  /// `endedBy` is not required to be `TECHNICIAN`: a close that arrives after
  /// the tablet's or the backend's keeps their `endedBy`, and is just as
  /// confirmed.
  static bool isClosedSession(RemoteSession session, String remoteSessionId) =>
      session.id == remoteSessionId &&
      session.isClosed &&
      session.endedAt != null;

  /// Reads the session by id and lets it say whether it is over.
  ///
  /// [whenLive] is what a session that is still live means here.
  Future<RemoteSessionCloseOutcome> _reconcile(
    String remoteSessionId, {
    required RemoteSessionCloseOutcome whenLive,
  }) async {
    final result = await _repository.load(id: remoteSessionId);
    switch (result) {
      case Success<RemoteSession>(:final value):
        if (isClosedSession(value, remoteSessionId)) {
          return RemoteSessionCloseConfirmed(session: value);
        }
        if (value.id == remoteSessionId && value.isLive) return whenLive;
        // Another session, or a status this console does not know.
        return const RemoteSessionCloseUnconfirmed(UnexpectedFailure());
      case Failed<RemoteSession>(:final failure):
        if (failure is NotFoundFailure) {
          return const RemoteSessionCloseConfirmed();
        }
        return RemoteSessionCloseUnconfirmed(failure);
    }
  }
}
