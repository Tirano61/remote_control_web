import '../../../../core/error/failure.dart';
import '../../../../core/error/result.dart';
import '../entities/user_session.dart';
import '../repositories/auth_repository.dart';
import 'log_in.dart' show kTechnicianConsoleAccessDeniedMessage;

/// Outcome of a startup session restore.
sealed class SessionRestoreOutcome {
  const SessionRestoreOutcome();
}

/// No User JWT was persisted: the user has to log in.
final class NoStoredSession extends SessionRestoreOutcome {
  const NoStoredSession();

  @override
  String toString() => 'NoStoredSession';
}

/// The persisted token was validated by `GET /auth/check-status`.
final class RestoredSession extends SessionRestoreOutcome {
  const RestoredSession(this.session);

  final UserSession session;

  @override
  String toString() => 'RestoredSession(user: ${session.user.email})';
}

/// Validates a persisted User JWT against the backend at startup.
///
/// The locally cached data is never trusted on its own: `isActive`, `roles` and
/// the user identity always come from `GET /auth/check-status`.
class RestoreSession {
  const RestoreSession({required AuthRepository repository})
    : _repository = repository;

  final AuthRepository _repository;

  Future<Result<SessionRestoreOutcome>> call() async {
    final token = await _repository.readStoredToken();
    if (token == null || token.isEmpty) {
      return const Success(NoStoredSession());
    }

    final result = await _repository.checkStatus();
    return switch (result) {
      // The repository already cleared the token on 401 and kept it on a
      // network failure.
      Failed<UserSession>(:final failure) => Failed(failure),
      Success<UserSession>(:final value) => await _enforceConsoleAccess(value),
    };
  }

  Future<Result<SessionRestoreOutcome>> _enforceConsoleAccess(
    UserSession session,
  ) async {
    if (session.user.canAccessTechnicianConsole) {
      return Success(RestoredSession(session));
    }
    await _repository.logOut();
    return const Failed(
      ForbiddenFailure(kTechnicianConsoleAccessDeniedMessage),
    );
  }
}
