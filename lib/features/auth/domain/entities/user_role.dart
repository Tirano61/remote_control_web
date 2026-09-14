import 'package:equatable/equatable.dart';

/// A backend role, typed.
///
/// The backend `ValidRoles` enum currently contains `admin`, `tecnico`,
/// `sales` and `user`. Unknown values are preserved instead of being dropped,
/// so a role added later on the backend never crashes the web client and never
/// silently grants access.
///
/// Client side role checks are for navigation and UI only. The backend remains
/// authoritative for authorisation.
class UserRole extends Equatable {
  const UserRole._(this.wireValue);

  /// Parses a role as sent by the backend. Unrecognised values become an
  /// "unknown" role that grants nothing.
  factory UserRole.fromWire(String raw) {
    final normalized = raw.trim().toLowerCase();
    for (final role in known) {
      if (role.wireValue == normalized) return role;
    }
    return UserRole._(normalized);
  }

  static const UserRole admin = UserRole._('admin');
  static const UserRole tecnico = UserRole._('tecnico');
  static const UserRole sales = UserRole._('sales');
  static const UserRole user = UserRole._('user');

  /// Roles documented in `docs/backend/ENDPOINTS.md`.
  static const List<UserRole> known = [admin, tecnico, sales, user];

  /// Roles that may use the technician console.
  static const List<UserRole> technicianConsoleRoles = [admin, tecnico];

  /// The exact string used by the backend.
  final String wireValue;

  bool get isKnown => known.contains(this);

  /// Whether this role, on its own, allows using this application.
  bool get grantsTechnicianConsoleAccess =>
      technicianConsoleRoles.contains(this);

  String get displayName => switch (wireValue) {
    'admin' => 'Administrador',
    'tecnico' => 'Técnico',
    'sales' => 'Ventas',
    'user' => 'Usuario',
    _ => wireValue.isEmpty ? 'Rol desconocido' : wireValue,
  };

  @override
  List<Object?> get props => [wireValue];

  @override
  String toString() => 'UserRole($wireValue)';
}

/// Role helpers shared by domain and presentation, so that raw strings such as
/// `roles.contains('admin')` never spread through the application.
extension UserRoleListX on List<UserRole> {
  bool get grantsTechnicianConsoleAccess =>
      any((role) => role.grantsTechnicianConsoleAccess);

  bool has(UserRole role) => contains(role);

  String get displayLabel =>
      isEmpty ? 'Sin roles' : map((role) => role.displayName).join(', ');
}
