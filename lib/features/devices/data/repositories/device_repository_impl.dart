import '../../../../core/auth/user_token_provider.dart';
import '../../../../core/error/api_failure_mapper.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/error/result.dart';
import '../../../../core/network/api_exception.dart';
import '../../domain/entities/device.dart';
import '../../domain/repositories/device_repository.dart';
import '../datasources/devices_remote_data_source.dart';

/// Implements the devices boundary on top of the REST data source.
///
/// This is the only place in the feature that knows the User JWT exists: it
/// reads it through [UserTokenProvider] and hands it to the data source.
class DeviceRepositoryImpl implements DeviceRepository {
  const DeviceRepositoryImpl({
    required DevicesRemoteDataSource remoteDataSource,
    required UserTokenProvider tokenProvider,
  }) : _remoteDataSource = remoteDataSource,
       _tokenProvider = tokenProvider;

  final DevicesRemoteDataSource _remoteDataSource;
  final UserTokenProvider _tokenProvider;

  @override
  Future<Result<List<Device>>> loadDevices() =>
      _authenticated((token) => _remoteDataSource.fetchDevices(token: token));

  @override
  Future<Result<Device>> loadDevice({required String id}) => _authenticated(
    (token) => _remoteDataSource.fetchDevice(id: id, token: token),
  );

  /// Runs [request] with the current User JWT.
  ///
  /// No token at all is treated exactly like a rejected one: the session is not
  /// usable and the console has to go back to the login page.
  Future<Result<T>> _authenticated<T>(
    Future<T> Function(String token) request,
  ) async {
    final token = await _tokenProvider.currentToken();
    if (token == null || token.isEmpty) return const Failed(AuthFailure());

    try {
      return Success(await request(token));
    } on ApiException catch (exception) {
      return Failed(
        failureFromApiException(
          exception,
          overrides: (statusCode) => switch (statusCode) {
            403 => const ForbiddenFailure(
              'No tienes permisos para consultar los dispositivos.',
            ),
            404 => const NotFoundFailure('El dispositivo no existe.'),
            _ => null,
          },
        ),
      );
    }
  }
}
