import 'package:equatable/equatable.dart';

import '../../../../core/error/failure.dart';

/// What the backend said — or did not manage to say — about closing one
/// remote session from this console.
///
/// It exists because `POST /remote-sessions/:id/close` alone cannot answer
/// "is it over?": it is not idempotent (a second close is a `409`), and a
/// `409` covers both "already closed" and "its support request could not be
/// completed". The answer is only trusted when the backend itself gave it.
sealed class RemoteSessionCloseOutcome extends Equatable {
  const RemoteSessionCloseOutcome();

  @override
  List<Object?> get props => const [];
}

/// The backend holds no live session by that id for this technician any more.
///
/// Either the close went through (`200`), or it had already happened — by
/// this console with its answer lost, by the tablet, or by the backend — as a
/// `GET /remote-sessions/:id` answering `CLOSED` confirms, or the session is
/// not this technician's at all (`404`). In every case there is nothing left
/// for this console to close.
final class RemoteSessionCloseConfirmed extends RemoteSessionCloseOutcome {
  const RemoteSessionCloseConfirmed();
}

/// The backend answered, and the session is still live: it refused to close
/// it (`403`, `400`, or a `409` with the session still `CONNECTING`/`ACTIVE`).
///
/// Asking again on its own would get the same answer, so nothing retries it
/// automatically; the technician may still ask.
final class RemoteSessionCloseRefused extends RemoteSessionCloseOutcome {
  const RemoteSessionCloseRefused(this.failure);

  final Failure failure;

  @override
  List<Object?> get props => [failure];
}

/// Nobody can say: the request did not arrive, its answer did not, or the
/// backend failed (`5xx`, timeout, no network, an unreadable answer), or the
/// User JWT was rejected ([AuthFailure]).
///
/// The close may or may not have been committed. Anything but an
/// [AuthFailure] is worth asking again, later.
final class RemoteSessionCloseUnconfirmed extends RemoteSessionCloseOutcome {
  const RemoteSessionCloseUnconfirmed(this.failure);

  final Failure failure;

  @override
  List<Object?> get props => [failure];
}
