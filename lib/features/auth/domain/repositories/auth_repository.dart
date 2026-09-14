import '../../../../core/error/result.dart';
import '../entities/user_session.dart';

/// Authentication boundary of the domain layer.
///
/// Implementations own both the REST calls and the persistence of the User JWT,
/// so BLoCs never touch the token storage directly.
abstract interface class AuthRepository {
  /// `POST /auth/login`. On success the User JWT is persisted.
  Future<Result<UserSession>> logIn({
    required String email,
    required String password,
  });

  /// Reads the persisted User JWT, if any.
  ///
  /// Returns `null` when no session was stored.
  Future<String?> readStoredToken();

  /// `GET /auth/check-status` with the persisted User JWT.
  ///
  /// On success the renewed token returned by the backend replaces the stored
  /// one. On 401 the stored token is cleared. On a network failure the stored
  /// token is kept, so the user can retry.
  ///
  /// Returns a [Failed] with [AuthFailure] when nothing is stored.
  Future<Result<UserSession>> checkStatus();

  /// Drops the local session. There is no server side JWT invalidation in the
  /// current backend contract, so this is purely local.
  Future<void> logOut();
}
