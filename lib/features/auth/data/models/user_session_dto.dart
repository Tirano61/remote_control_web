import '../../../../core/network/api_exception.dart';
import '../../domain/entities/authenticated_user.dart';
import '../../domain/entities/user_role.dart';
import '../../domain/entities/user_session.dart';

/// Maps the auth responses of `remote_control_backend` into domain entities.
///
/// Both `POST /auth/login` and `GET /auth/check-status` answer with the user
/// fields plus a `token`. Login omits `created_at` / `updated_at`;
/// check-status includes them. The two shapes are not assumed to be identical.
class UserSessionDto {
  const UserSessionDto._();

  /// Throws [MalformedResponseApiException] when a required field is missing
  /// or has an unexpected type.
  static UserSession fromJson(Map<String, dynamic> json) {
    final token = json['token'];
    if (token is! String || token.isEmpty) {
      throw const MalformedResponseApiException();
    }

    return UserSession(user: userFromJson(json), token: token);
  }

  static AuthenticatedUser userFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final email = json['email'];
    final fullName = json['fullName'];
    final isActive = json['isActive'];
    final roles = json['roles'];

    if (id is! String ||
        email is! String ||
        fullName is! String ||
        isActive is! bool ||
        roles is! List) {
      throw const MalformedResponseApiException();
    }

    return AuthenticatedUser(
      id: id,
      email: email,
      fullName: fullName,
      isActive: isActive,
      roles: roles
          .whereType<String>()
          .map(UserRole.fromWire)
          .toList(growable: false),
      createdAt: _parseDate(json['created_at']),
      updatedAt: _parseDate(json['updated_at']),
    );
  }

  static DateTime? _parseDate(dynamic value) =>
      value is String ? DateTime.tryParse(value) : null;
}
