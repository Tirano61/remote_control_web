import 'package:equatable/equatable.dart';

import 'authenticated_user.dart';

/// An authenticated session: the user plus the User JWT that proves it.
///
/// The token is intentionally excluded from [toString]. It must never be
/// rendered in the UI nor written to logs.
class UserSession extends Equatable {
  const UserSession({required this.user, required this.token});

  final AuthenticatedUser user;

  /// User JWT. Never a Device JWT.
  final String token;

  @override
  List<Object?> get props => [user, token];

  /// Equatable would otherwise print every prop (including the token) in debug
  /// builds, so the representation is written by hand and redacted.
  @override
  String toString() => 'UserSession(user: $user, token: <redacted>)';
}
