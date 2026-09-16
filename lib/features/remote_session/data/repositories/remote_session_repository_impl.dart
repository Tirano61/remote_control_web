import '../../../../core/auth/user_token_provider.dart';
import '../../../../core/error/api_failure_mapper.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/error/result.dart';
import '../../../../core/network/api_exception.dart';
import '../../domain/entities/remote_session.dart';
import '../../domain/repositories/remote_session_repository.dart';
import '../datasources/remote_sessions_remote_data_source.dart';

/// Shown when `POST /remote-sessions` is refused with a `409` and no live
/// session could be recovered afterwards.
///
/// The backend answers the same status code for every reason — the request was
/// not accepted, the device is offline, the device already has a session, the
/// request already produced one — and the message string is not part of the
/// contract, so the console states the consequence instead of guessing.
const String kCreateConflictMessage =
    'No se pudo iniciar la asistencia. Puede que el dispositivo esté '
    'desconectado o que la solicitud ya no sea válida.';

/// Shown when `POST /remote-sessions/:id/activate` is refused with a `409`.
///
/// It means the session stopped being activable — it was closed concurrently,
/// most often by the tablet — so the console reconciles with REST and only
/// shows this if something is still there afterwards.
const String kActivateConflictMessage =
    'La asistencia ya no podía activarse.';

/// Shown when the activation could not be sent at all.
///
/// The peer connection is untouched by this: WebRTC is peer to peer and does
/// not care that one REST call failed.
const String kActivateFailedMessage =
    'No se pudo confirmar el inicio de la asistencia.';

/// Shown when `POST /remote-sessions/:id/close` is refused with a `409`.
const String kCloseConflictMessage =
    'La asistencia ya no estaba activa.';

/// Implements the technician side of remote sessions on top of the REST data
/// source.
///
/// The User JWT is read through [UserTokenProvider] and never leaves this
/// layer.
class RemoteSessionRepositoryImpl implements RemoteSessionRepository {
  const RemoteSessionRepositoryImpl({
    required RemoteSessionsRemoteDataSource remoteDataSource,
    required UserTokenProvider tokenProvider,
  }) : _remoteDataSource = remoteDataSource,
       _tokenProvider = tokenProvider;

  final RemoteSessionsRemoteDataSource _remoteDataSource;
  final UserTokenProvider _tokenProvider;

  @override
  Future<Result<RemoteSession>> create({required String supportRequestId}) =>
      _authenticated(
        (token) => _remoteDataSource.create(
          supportRequestId: supportRequestId,
          token: token,
        ),
        overrides: (statusCode) => switch (statusCode) {
          403 => const ForbiddenFailure(
            'No tienes permisos para iniciar una asistencia remota.',
          ),
          // Either the request does not exist, or it is assigned to another
          // technician. The backend does not distinguish the two on purpose.
          404 => const NotFoundFailure(
            'La solicitud ya no existe o no está asignada a ti.',
          ),
          409 => const ConflictFailure(kCreateConflictMessage),
          _ => null,
        },
      );

  @override
  Future<Result<RemoteSession?>> loadCurrent() => _authenticated(
    (token) => _remoteDataSource.fetchCurrent(token: token),
    overrides: (statusCode) => switch (statusCode) {
      403 => const ForbiddenFailure(
        'No tienes permisos para consultar la asistencia remota.',
      ),
      _ => null,
    },
  );

  @override
  Future<Result<RemoteSession>> activate({required String id}) =>
      _authenticated(
        (token) => _remoteDataSource.activate(id: id, token: token),
        overrides: (statusCode) => switch (statusCode) {
          403 => const ForbiddenFailure(
            'No tienes permisos para activar esta asistencia.',
          ),
          404 => const NotFoundFailure('La asistencia ya no existe.'),
          409 => const ConflictFailure(kActivateConflictMessage),
          _ => null,
        },
      );

  @override
  Future<Result<RemoteSession>> close({required String id}) => _authenticated(
    (token) => _remoteDataSource.close(id: id, token: token),
    overrides: (statusCode) => switch (statusCode) {
      403 => const ForbiddenFailure(
        'No tienes permisos para finalizar esta asistencia.',
      ),
      404 => const NotFoundFailure('La asistencia ya no existe.'),
      409 => const ConflictFailure(kCloseConflictMessage),
      _ => null,
    },
  );

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
