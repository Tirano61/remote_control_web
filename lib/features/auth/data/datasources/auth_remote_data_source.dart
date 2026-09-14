import '../../../../core/network/api_client.dart';
import '../../domain/entities/user_session.dart';
import '../models/user_session_dto.dart';

/// REST access to the authentication endpoints documented in
/// `docs/backend/ENDPOINTS.md`.
///
/// Paths, methods and payloads are defined here and nowhere else.
abstract interface class AuthRemoteDataSource {
  /// `POST /auth/login` — public endpoint, answers 200 on success.
  Future<UserSession> logIn({required String email, required String password});

  /// `GET /auth/check-status` — User JWT, any role. Returns a renewed token.
  Future<UserSession> checkStatus({required String token});
}

class AuthRemoteDataSourceImpl implements AuthRemoteDataSource {
  const AuthRemoteDataSourceImpl({required ApiClient apiClient})
    : _apiClient = apiClient;

  static const String loginPath = '/auth/login';
  static const String checkStatusPath = '/auth/check-status';

  final ApiClient _apiClient;

  @override
  Future<UserSession> logIn({
    required String email,
    required String password,
  }) async {
    // Only `email` and `password` are sent: the backend runs a ValidationPipe
    // with forbidNonWhitelisted, so any extra property fails the request.
    final response = await _apiClient.post(
      loginPath,
      body: {'email': email, 'password': password},
    );
    return UserSessionDto.fromJson(response.data);
  }

  @override
  Future<UserSession> checkStatus({required String token}) async {
    final response = await _apiClient.get(
      checkStatusPath,
      bearerToken: token,
    );
    return UserSessionDto.fromJson(response.data);
  }
}
