part of 'user_session_bloc.dart';

sealed class UserSessionState extends Equatable {
  const UserSessionState();

  @override
  List<Object?> get props => const [];
}

/// Startup: a persisted token is being looked up and validated.
final class UserSessionCheckingStoredSession extends UserSessionState {
  const UserSessionCheckingStoredSession();
}

/// A stored session is being re-validated after a connection error.
final class UserSessionAuthenticating extends UserSessionState {
  const UserSessionAuthenticating();
}

/// No usable session. The login page is shown.
///
/// [notice] carries an explanation when the session was refused for a reason
/// the user should see, e.g. a role that may not use this console.
final class UserSessionUnauthenticated extends UserSessionState {
  const UserSessionUnauthenticated({this.notice});

  final String? notice;

  @override
  List<Object?> get props => [notice];
}

/// The backend validated the session and the user may use the console.
final class UserSessionAuthenticated extends UserSessionState {
  const UserSessionAuthenticated(this.session);

  final UserSession session;

  AuthenticatedUser get user => session.user;

  @override
  List<Object?> get props => [session];

  @override
  String toString() => 'UserSessionAuthenticated(user: ${session.user.email})';
}

/// The stored token could not be validated because the backend was not
/// reachable. The token is kept and the user may retry.
final class UserSessionConnectionError extends UserSessionState {
  const UserSessionConnectionError({
    this.message = 'No se pudo conectar con el servidor.',
  });

  final String message;

  @override
  List<Object?> get props => [message];
}
