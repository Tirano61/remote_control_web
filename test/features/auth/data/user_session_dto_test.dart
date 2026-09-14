import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/network/api_exception.dart';
import 'package:remote_control_web/features/auth/data/models/user_session_dto.dart';
import 'package:remote_control_web/features/auth/domain/entities/user_role.dart';

void main() {
  Map<String, dynamic> validJson({
    List<dynamic> roles = const ['tecnico'],
    Object? token = '<user jwt>',
  }) => {
    'id': '550e8400-e29b-41d4-a716-446655440000',
    'email': 'tecnico@example.com',
    'fullName': 'Ana Torres',
    'isActive': true,
    'roles': roles,
    'token': ?token,
  };

  test('maps several roles', () {
    final session = UserSessionDto.fromJson(
      validJson(roles: const ['admin', 'tecnico']),
    );

    expect(session.user.roles, [UserRole.admin, UserRole.tecnico]);
    expect(session.user.canAccessTechnicianConsole, isTrue);
  });

  test('keeps a role the client does not know yet', () {
    final session = UserSessionDto.fromJson(
      validJson(roles: const ['supervisor']),
    );

    expect(session.user.roles.single.wireValue, 'supervisor');
    expect(session.user.roles.single.isKnown, isFalse);
    expect(session.user.canAccessTechnicianConsole, isFalse);
  });

  test('ignores non string entries inside roles', () {
    final session = UserSessionDto.fromJson(
      validJson(roles: const ['tecnico', 42]),
    );

    expect(session.user.roles, [UserRole.tecnico]);
  });

  test('rejects a response without a token', () {
    expect(
      () => UserSessionDto.fromJson(validJson(token: null)),
      throwsA(isA<MalformedResponseApiException>()),
    );
  });

  test('rejects a response with an unexpected field type', () {
    final json = validJson()..['isActive'] = 'true';

    expect(
      () => UserSessionDto.fromJson(json),
      throwsA(isA<MalformedResponseApiException>()),
    );
  });

  test('rejects a response missing the user identity', () {
    final json = validJson()..remove('id');

    expect(
      () => UserSessionDto.fromJson(json),
      throwsA(isA<MalformedResponseApiException>()),
    );
  });

  test('leaves the timestamps null when they are absent', () {
    final session = UserSessionDto.fromJson(validJson());

    expect(session.user.createdAt, isNull);
    expect(session.user.updatedAt, isNull);
  });
}
