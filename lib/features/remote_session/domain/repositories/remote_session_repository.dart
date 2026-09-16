import '../../../../core/error/result.dart';
import '../entities/remote_session.dart';

/// Remote sessions boundary of the domain layer, technician side.
///
/// Implementations own the REST calls and obtain the User JWT themselves.
/// Every route is ownership scoped by the backend: the session must belong to
/// the authenticated technician, and holding `admin` changes nothing.
abstract interface class RemoteSessionRepository {
  /// `POST /remote-sessions` — starts the assistance for an `ACCEPTED`
  /// support request.
  ///
  /// `supportRequestId` is the only accepted field: the device comes from the
  /// request and the technician from the token.
  Future<Result<RemoteSession>> create({required String supportRequestId});

  /// `GET /remote-sessions/current` — the live session of the authenticated
  /// technician, or `null`.
  ///
  /// Having no live session is not an error: the backend answers `200` with
  /// `remoteSession: null`. This is the source of truth used to recover after a
  /// page reload or a missed realtime event.
  Future<Result<RemoteSession?>> loadCurrent();

  /// `POST /remote-sessions/:id/activate` — the technician end reached the
  /// device, so the assistance really started.
  ///
  /// The backend performs `CONNECTING -> ACTIVE` and stamps `connectedAt` with
  /// its own clock. The call is idempotent: an already `ACTIVE` session answers
  /// `200` with that same session.
  Future<Result<RemoteSession>> activate({required String id});

  /// `POST /remote-sessions/:id/close` — ends the assistance.
  ///
  /// The backend closes the session and completes its support request in the
  /// same transaction.
  Future<Result<RemoteSession>> close({required String id});
}
