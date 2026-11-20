import 'package:equatable/equatable.dart';

import '../../../../core/error/failure.dart';
import 'remote_session.dart';

/// What the backend said — or did not manage to say — about closing one
/// remote session from this console.
///
/// `POST /remote-sessions/:id/close` is idempotent: a `200` describing that
/// session as `CLOSED` is the answer, whoever closed it first. The other
/// answers — a `404`, a `409`, a failure, a `200` that does not describe it —
/// need to be told apart, and the answer is only trusted when the backend
/// itself gave it.
sealed class RemoteSessionCloseOutcome extends Equatable {
  const RemoteSessionCloseOutcome();

  @override
  List<Object?> get props => const [];
}

/// The backend holds no live session by that id for this technician any more.
///
/// Either the close answered `200` with that session `CLOSED` — closed now, by
/// an earlier attempt of this console whose answer was lost, by the tablet or
/// by the backend — or `GET /remote-sessions/:id` answers it `CLOSED`, or the
/// session is not this technician's at all (`404`). In every case there is
/// nothing left for this console to close.
final class RemoteSessionCloseConfirmed extends RemoteSessionCloseOutcome {
  const RemoteSessionCloseConfirmed({this.session});

  /// The closed session as the backend answered it, with the **original**
  /// `endedBy` and `endedAt` — which may be the tablet's (`DEVICE`) or the
  /// backend's (`SYSTEM`). `null` after a `404`: nothing of this technician's
  /// was there to describe.
  final RemoteSession? session;

  @override
  List<Object?> get props => [session];
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

/// Nobody can say: the request did not arrive, its answer did not, the
/// backend failed (`5xx`, timeout, no network, an unreadable answer), the
/// User JWT was rejected ([AuthFailure]), or the answer did not describe the
/// session asked for.
///
/// The close may or may not have been committed. Anything but an
/// [AuthFailure] is worth asking again, later: the close is idempotent, so a
/// repetition can only confirm it.
final class RemoteSessionCloseUnconfirmed extends RemoteSessionCloseOutcome {
  const RemoteSessionCloseUnconfirmed(this.failure);

  final Failure failure;

  @override
  List<Object?> get props => [failure];
}
