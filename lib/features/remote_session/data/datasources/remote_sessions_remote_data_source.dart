import '../../../../core/network/api_client.dart';
import '../../domain/entities/remote_session.dart';
import '../models/remote_session_dto.dart';

/// REST access to the technician facing remote session endpoints documented in
/// `docs/backend/ENDPOINTS.md` under "Remote sessions — Web".
///
/// Every route of this group requires a User JWT with role `admin` or
/// `tecnico` and is ownership scoped by the backend. The `/device/...` routes
/// of the same domain are never called from here: they need a Device JWT,
/// which this application must never hold.
abstract interface class RemoteSessionsRemoteDataSource {
  /// `POST /remote-sessions` with `{ "supportRequestId": ... }`.
  Future<RemoteSession> create({
    required String supportRequestId,
    required String token,
  });

  /// `GET /remote-sessions/current`.
  ///
  /// Returns `null` when the documented envelope carries `remoteSession: null`.
  Future<RemoteSession?> fetchCurrent({required String token});

  /// `POST /remote-sessions/:id/activate` — empty body.
  ///
  /// Moves the session from `CONNECTING` to `ACTIVE` and lets the backend set
  /// `connectedAt`. Nothing identifying the technician, the device or the
  /// moment is sent: all three are the backend's to decide.
  Future<RemoteSession> activate({required String id, required String token});

  /// `POST /remote-sessions/:id/close` — empty body.
  Future<RemoteSession> close({required String id, required String token});
}

class RemoteSessionsRemoteDataSourceImpl
    implements RemoteSessionsRemoteDataSource {
  const RemoteSessionsRemoteDataSourceImpl({required ApiClient apiClient})
    : _apiClient = apiClient;

  static const String remoteSessionsPath = '/remote-sessions';

  /// The literal segment `current` is routed before `:id` by the backend, so it
  /// is never parsed as a session UUID.
  static const String currentPath = '$remoteSessionsPath/current';

  /// The only field `POST /remote-sessions` accepts. Sending `deviceId` or
  /// `technicianId` is a `400`, not an ignored property.
  static const String supportRequestIdField = 'supportRequestId';

  static String activatePath(String id) =>
      '$remoteSessionsPath/$id/activate';

  static String closePath(String id) => '$remoteSessionsPath/$id/close';

  final ApiClient _apiClient;

  @override
  Future<RemoteSession> create({
    required String supportRequestId,
    required String token,
  }) async {
    final response = await _apiClient.post(
      remoteSessionsPath,
      body: {supportRequestIdField: supportRequestId},
      bearerToken: token,
    );
    return RemoteSessionDto.fromJson(response.data);
  }

  @override
  Future<RemoteSession?> fetchCurrent({required String token}) async {
    final response = await _apiClient.get(currentPath, bearerToken: token);
    return RemoteSessionDto.currentFromJson(response.data);
  }

  @override
  Future<RemoteSession> activate({
    required String id,
    required String token,
  }) async {
    // Empty body, exactly like close: `status`, `connectedAt`, `technicianId`,
    // `userId` and `deviceId` are never sent — the backend owns the transition
    // and derives the identity from the User JWT.
    final response = await _apiClient.post(
      activatePath(id),
      bearerToken: token,
    );
    return RemoteSessionDto.fromJson(response.data);
  }

  @override
  Future<RemoteSession> close({
    required String id,
    required String token,
  }) async {
    // `body` stays null on purpose: the contract documents an empty body and
    // the backend runs forbidNonWhitelisted, so any property would be a 400.
    final response = await _apiClient.post(closePath(id), bearerToken: token);
    return RemoteSessionDto.fromJson(response.data);
  }
}
