import '../../../../core/auth/user_token_provider.dart';
import '../../../../core/error/api_failure_mapper.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/error/result.dart';
import '../../../../core/network/api_exception.dart';
import '../../domain/entities/support_request.dart';
import '../../domain/entities/support_request_status.dart';
import '../../domain/repositories/support_request_repository.dart';
import '../datasources/support_remote_data_source.dart';

/// Message shown when `POST /assign` is refused with a `409`.
///
/// The backend answers the same status code for the three possible reasons —
/// the request is no longer `WAITING`, the device went offline, or another
/// technician took it first — and the message string is not part of the
/// contract, so the console states the consequence and reloads.
const String kAssignConflictMessage =
    'La solicitud ya no está disponible. Puede que otro técnico la haya '
    'tomado o que el dispositivo esté desconectado.';

/// Implements the technician side of support requests on top of the REST data
/// source.
///
/// The User JWT is read through [UserTokenProvider] and never leaves this
/// layer.
class SupportRequestRepositoryImpl implements SupportRequestRepository {
  const SupportRequestRepositoryImpl({
    required SupportRemoteDataSource remoteDataSource,
    required UserTokenProvider tokenProvider,
  }) : _remoteDataSource = remoteDataSource,
       _tokenProvider = tokenProvider;

  final SupportRemoteDataSource _remoteDataSource;
  final UserTokenProvider _tokenProvider;

  @override
  Future<Result<List<SupportRequest>>> loadRequests({
    SupportRequestStatus? status,
  }) => _authenticated(
    (token) => _remoteDataSource.fetchRequests(token: token, status: status),
    overrides: _queryOverrides,
  );

  @override
  Future<Result<SupportRequest>> loadRequest({required String id}) =>
      _authenticated(
        (token) => _remoteDataSource.fetchRequest(id: id, token: token),
        overrides: _queryOverrides,
      );

  @override
  Future<Result<SupportRequest>> assign({required String id}) => _authenticated(
    (token) => _remoteDataSource.assign(id: id, token: token),
    overrides: (statusCode) => switch (statusCode) {
      403 => const ForbiddenFailure(
        'No tienes permisos para tomar solicitudes de asistencia.',
      ),
      404 => const NotFoundFailure('La solicitud ya no existe.'),
      409 => const ConflictFailure(kAssignConflictMessage),
      _ => null,
    },
  );

  Failure? _queryOverrides(int statusCode) => switch (statusCode) {
    403 => const ForbiddenFailure(
      'No tienes permisos para ver las solicitudes de asistencia.',
    ),
    404 => const NotFoundFailure('La solicitud no existe.'),
    _ => null,
  };

  /// Runs [request] with the current User JWT.
  ///
  /// No token at all is treated exactly like a rejected one: the console has to
  /// go back to the login page.
  Future<Result<T>> _authenticated<T>(
    Future<T> Function(String token) request, {
    Failure? Function(int statusCode)? overrides,
  }) async {
    final token = await _tokenProvider.currentToken();
    if (token == null || token.isEmpty) return const Failed(AuthFailure());

    try {
      return Success(await request(token));
    } on ApiException catch (exception) {
      return Failed(failureFromApiException(exception, overrides: overrides));
    }
  }
}
