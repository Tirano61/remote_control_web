import '../../../../core/error/api_failure_mapper.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/error/result.dart';
import '../../../../core/network/api_exception.dart';
import '../../domain/entities/user_session.dart';
import '../../domain/repositories/auth_repository.dart';
import '../../domain/storage/user_token_storage.dart';
import '../datasources/auth_remote_data_source.dart';

/// Implements the authentication boundary on top of the REST data source and
/// the token storage.
///
/// This is the only place that knows both, which keeps token persistence out of
/// BLoCs and widgets.
class AuthRepositoryImpl implements AuthRepository {
  const AuthRepositoryImpl({
    required AuthRemoteDataSource remoteDataSource,
    required UserTokenStorage tokenStorage,
  }) : _remoteDataSource = remoteDataSource,
       _tokenStorage = tokenStorage;

  final AuthRemoteDataSource _remoteDataSource;
  final UserTokenStorage _tokenStorage;

  @override
  Future<Result<UserSession>> logIn({
    required String email,
    required String password,
  }) async {
    try {
      final session = await _remoteDataSource.logIn(
        email: email,
        password: password,
      );
      await _tokenStorage.save(session.token);
      return Success(session);
    } on ApiException catch (exception) {
      return Failed(_mapLoginException(exception));
    }
  }

  @override
  Future<String?> readStoredToken() => _tokenStorage.read();

  @override
  Future<Result<UserSession>> checkStatus() async {
    final token = await _tokenStorage.read();
    if (token == null || token.isEmpty) {
      return const Failed(AuthFailure());
    }

    try {
      final session = await _remoteDataSource.checkStatus(token: token);
      // check-status answers with a freshly signed token; the stored one is
      // replaced so the 2h lifetime restarts on every app start.
      await _tokenStorage.save(session.token);
      return Success(session);
    } on ApiException catch (exception) {
      final failure = _mapCheckStatusException(exception);
      // A rejected token is useless: drop it. A network failure says nothing
      // about the token, so it is kept and the user can retry.
      if (failure is AuthFailure) {
        await _tokenStorage.clear();
      }
      return Failed(failure);
    }
  }

  @override
  Future<void> logOut() => _tokenStorage.clear();

  Failure _mapLoginException(ApiException exception) => switch (exception) {
    NetworkApiException() => const NetworkFailure(),
    MalformedResponseApiException() => const UnexpectedFailure(
      'La respuesta del servidor no pudo interpretarse.',
    ),
    HttpApiException(:final statusCode) => switch (statusCode) {
      400 => const ValidationFailure('Email o contraseña no válidos.'),
      401 => const AuthFailure('Email o contraseña incorrectos.'),
      403 => const ForbiddenFailure(),
      404 => const NotFoundFailure(),
      409 => const ConflictFailure(),
      _ => const ServerFailure(),
    },
  };

  // check-status needs no special wording: the shared status code mapping is
  // exactly the "Common errors" table of the contract.
  Failure _mapCheckStatusException(ApiException exception) =>
      failureFromApiException(exception);
}
