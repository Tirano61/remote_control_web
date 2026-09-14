import 'package:remote_control_web/core/network/api_exception.dart';
import 'package:remote_control_web/features/auth/data/datasources/auth_remote_data_source.dart';
import 'package:remote_control_web/features/auth/domain/entities/authenticated_user.dart';
import 'package:remote_control_web/features/auth/domain/entities/user_role.dart';
import 'package:remote_control_web/features/auth/domain/entities/user_session.dart';
import 'package:remote_control_web/features/auth/domain/storage/user_token_storage.dart';

/// In-memory [UserTokenStorage], standing in for browser storage.
class InMemoryUserTokenStorage implements UserTokenStorage {
  InMemoryUserTokenStorage([this.token]);

  String? token;
  int saveCount = 0;
  int clearCount = 0;

  @override
  Future<String?> read() async => token;

  @override
  Future<void> save(String value) async {
    token = value;
    saveCount++;
  }

  @override
  Future<void> clear() async {
    token = null;
    clearCount++;
  }
}

/// Scripted [AuthRemoteDataSource].
///
/// Each endpoint is given either a session to return or an exception to throw,
/// and records what it was called with.
class FakeAuthRemoteDataSource implements AuthRemoteDataSource {
  UserSession? loginResponse;
  Object? loginError;

  UserSession? checkStatusResponse;
  Object? checkStatusError;

  /// Replaces [checkStatusResponse] / [checkStatusError] after the first call,
  /// which is how the retry-after-network-error scenario is scripted.
  UserSession? checkStatusResponseAfterFirstCall;

  final List<({String email, String password})> loginCalls = [];
  final List<String> checkStatusTokens = [];

  @override
  Future<UserSession> logIn({
    required String email,
    required String password,
  }) async {
    loginCalls.add((email: email, password: password));
    final error = loginError;
    if (error != null) throw error;
    return loginResponse!;
  }

  @override
  Future<UserSession> checkStatus({required String token}) async {
    checkStatusTokens.add(token);
    final error = checkStatusError;
    if (error != null) {
      if (checkStatusResponseAfterFirstCall != null) {
        checkStatusError = null;
        checkStatusResponse = checkStatusResponseAfterFirstCall;
      }
      throw error;
    }
    return checkStatusResponse!;
  }
}

const ApiException unauthorized = HttpApiException(401);
const ApiException serverError = HttpApiException(500);
const ApiException networkDown = NetworkApiException();

AuthenticatedUser buildUser({
  String id = '550e8400-e29b-41d4-a716-446655440000',
  String email = 'admin@google.com',
  String fullName = 'Administrador',
  bool isActive = true,
  List<UserRole> roles = const [UserRole.admin],
}) => AuthenticatedUser(
  id: id,
  email: email,
  fullName: fullName,
  isActive: isActive,
  roles: roles,
);

UserSession buildSession({
  AuthenticatedUser? user,
  String token = 'header.payload.signature',
}) => UserSession(user: user ?? buildUser(), token: token);

final UserSession adminSession = buildSession(token: 'admin-jwt');

final UserSession technicianSession = buildSession(
  user: buildUser(
    id: '11111111-2222-3333-4444-555555555555',
    email: 'tecnico@example.com',
    fullName: 'Ana Torres',
    roles: const [UserRole.tecnico],
  ),
  token: 'tecnico-jwt',
);

final UserSession plainUserSession = buildSession(
  user: buildUser(
    id: '99999999-8888-7777-6666-555555555555',
    email: 'usuario@example.com',
    fullName: 'Usuario Sin Permisos',
    roles: const [UserRole.user],
  ),
  token: 'user-jwt',
);
