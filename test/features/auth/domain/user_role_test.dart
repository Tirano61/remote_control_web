import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/auth/domain/entities/authenticated_user.dart';
import 'package:remote_control_web/features/auth/domain/entities/user_role.dart';

void main() {
  group('UserRole', () {
    test('parses the roles documented in ENDPOINTS.md', () {
      expect(UserRole.fromWire('admin'), UserRole.admin);
      expect(UserRole.fromWire('tecnico'), UserRole.tecnico);
      expect(UserRole.fromWire('sales'), UserRole.sales);
      expect(UserRole.fromWire('user'), UserRole.user);
    });

    test('keeps an unknown role instead of failing, and grants nothing', () {
      final role = UserRole.fromWire('supervisor');

      expect(role.isKnown, isFalse);
      expect(role.wireValue, 'supervisor');
      expect(role.grantsTechnicianConsoleAccess, isFalse);
    });

    test('only admin and tecnico open the technician console', () {
      expect(UserRole.admin.grantsTechnicianConsoleAccess, isTrue);
      expect(UserRole.tecnico.grantsTechnicianConsoleAccess, isTrue);
      expect(UserRole.sales.grantsTechnicianConsoleAccess, isFalse);
      expect(UserRole.user.grantsTechnicianConsoleAccess, isFalse);
    });
  });

  group('AuthenticatedUser console access', () {
    AuthenticatedUser userWith({
      required List<UserRole> roles,
      bool isActive = true,
    }) => AuthenticatedUser(
      id: 'id',
      email: 'a@b.com',
      fullName: 'A B',
      isActive: isActive,
      roles: roles,
    );

    test('is granted to admin and tecnico', () {
      expect(
        userWith(roles: const [UserRole.admin]).canAccessTechnicianConsole,
        isTrue,
      );
      expect(
        userWith(roles: const [UserRole.tecnico]).canAccessTechnicianConsole,
        isTrue,
      );
      expect(
        userWith(
          roles: const [UserRole.user, UserRole.tecnico],
        ).canAccessTechnicianConsole,
        isTrue,
      );
    });

    test('is denied to every other role combination', () {
      expect(
        userWith(roles: const [UserRole.user]).canAccessTechnicianConsole,
        isFalse,
      );
      expect(
        userWith(roles: const [UserRole.sales]).canAccessTechnicianConsole,
        isFalse,
      );
      expect(userWith(roles: const []).canAccessTechnicianConsole, isFalse);
      expect(
        userWith(
          roles: [UserRole.fromWire('supervisor')],
        ).canAccessTechnicianConsole,
        isFalse,
      );
    });

    test('is denied to an inactive user', () {
      expect(
        userWith(
          roles: const [UserRole.admin],
          isActive: false,
        ).canAccessTechnicianConsole,
        isFalse,
      );
    });
  });
}
