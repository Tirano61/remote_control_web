part of 'user_session_bloc.dart';

sealed class UserSessionEvent extends Equatable {
  const UserSessionEvent();

  @override
  List<Object?> get props => const [];
}

/// Application start: look for a persisted User JWT and validate it.
final class UserSessionStarted extends UserSessionEvent {
  const UserSessionStarted();
}

/// The user pressed "Reintentar" after a connection error.
final class UserSessionRetryRequested extends UserSessionEvent {
  const UserSessionRetryRequested();
}

/// The login form produced a valid session.
final class UserSessionSignedIn extends UserSessionEvent {
  const UserSessionSignedIn(this.session);

  final UserSession session;

  @override
  List<Object?> get props => [session];

  @override
  String toString() => 'UserSessionSignedIn(user: ${session.user.email})';
}

/// An authenticated request was rejected with a `401`.
///
/// There is no refresh token in the backend contract, so the only possible
/// recovery is a new login: the stored User JWT is dropped and the console goes
/// back to the login page. A `403` must never raise this event — being
/// authenticated without permission for one action leaves the session valid.
final class UserSessionInvalidated extends UserSessionEvent {
  const UserSessionInvalidated({this.notice = kSessionExpiredNotice});

  final String notice;

  @override
  List<Object?> get props => [notice];
}

/// The user pressed "Cerrar sesión".
final class UserSessionSignOutRequested extends UserSessionEvent {
  const UserSessionSignOutRequested();
}
