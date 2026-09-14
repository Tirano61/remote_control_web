import 'package:equatable/equatable.dart';

import 'user_role.dart';

/// The authenticated human user, as returned by `POST /auth/login` and
/// `GET /auth/check-status`.
///
/// Only fields that actually exist in the backend contract are modelled.
/// `createdAt` / `updatedAt` are nullable because the login response does not
/// include them while check-status does.
///
/// The password is never part of this entity, and neither is the JWT: the token
/// belongs to [UserSession].
class AuthenticatedUser extends Equatable {
  const AuthenticatedUser({
    required this.id,
    required this.email,
    required this.fullName,
    required this.isActive,
    required this.roles,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String email;
  final String fullName;
  final bool isActive;
  final List<UserRole> roles;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Local policy for this application: only `admin` and `tecnico` may open
  /// the technician console. This hides UI, it is not security; the backend
  /// still protects every endpoint.
  bool get canAccessTechnicianConsole =>
      isActive && roles.grantsTechnicianConsoleAccess;

  bool get isAdmin => roles.has(UserRole.admin);

  bool get isTechnician => roles.has(UserRole.tecnico);

  String get rolesLabel => roles.displayLabel;

  @override
  List<Object?> get props => [
    id,
    email,
    fullName,
    isActive,
    roles,
    createdAt,
    updatedAt,
  ];

  @override
  String toString() =>
      'AuthenticatedUser(id: $id, email: $email, roles: $rolesLabel)';
}
