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

/// The user pressed "Cerrar sesión".
final class UserSessionSignOutRequested extends UserSessionEvent {
  const UserSessionSignOutRequested();
}
