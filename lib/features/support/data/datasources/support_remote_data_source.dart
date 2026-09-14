import '../../../../core/network/api_client.dart';
import '../../domain/entities/support_request.dart';
import '../../domain/entities/support_request_status.dart';
import '../models/support_request_dto.dart';

/// REST access to the technician facing support request endpoints documented
/// in `docs/backend/ENDPOINTS.md` under "Support requests — Web".
///
/// Every route of this group requires a User JWT with role `admin` or
/// `tecnico`. The device facing routes of the same prefix are never called
/// from here: they need a Device JWT, which this application must never hold.
abstract interface class SupportRemoteDataSource {
  /// `GET /support-requests` — the queue, oldest first.
  ///
  /// The only documented query parameter is `status`; it is sent only when a
  /// filter was asked for.
  Future<List<SupportRequest>> fetchRequests({
    required String token,
    SupportRequestStatus? status,
  });

  /// `GET /support-requests/:id`.
  Future<SupportRequest> fetchRequest({
    required String id,
    required String token,
  });

  /// `POST /support-requests/:id/assign` — empty body.
  ///
  /// `technicianId` is not accepted by the backend: the technician is the
  /// authenticated user.
  Future<SupportRequest> assign({required String id, required String token});
}

class SupportRemoteDataSourceImpl implements SupportRemoteDataSource {
  const SupportRemoteDataSourceImpl({required ApiClient apiClient})
    : _apiClient = apiClient;

  static const String supportRequestsPath = '/support-requests';

  /// Name of the documented query parameter of `GET /support-requests`.
  static const String statusQueryParameter = 'status';

  static String requestPath(String id) => '$supportRequestsPath/$id';

  static String assignPath(String id) => '${requestPath(id)}/assign';

  final ApiClient _apiClient;

  @override
  Future<List<SupportRequest>> fetchRequests({
    required String token,
    SupportRequestStatus? status,
  }) async {
    final response = await _apiClient.getList(
      supportRequestsPath,
      bearerToken: token,
      queryParameters: status == null
          ? null
          : {statusQueryParameter: status.wireValue},
    );
    return SupportRequestDto.listFromJson(response.data);
  }

  @override
  Future<SupportRequest> fetchRequest({
    required String id,
    required String token,
  }) async {
    final response = await _apiClient.get(requestPath(id), bearerToken: token);
    return SupportRequestDto.fromJson(response.data);
  }

  @override
  Future<SupportRequest> assign({
    required String id,
    required String token,
  }) async {
    // `body` stays null on purpose: the contract documents an empty body and
    // the backend runs forbidNonWhitelisted, so any property would be a 400.
    final response = await _apiClient.post(
      assignPath(id),
      bearerToken: token,
    );
    return SupportRequestDto.fromJson(response.data);
  }
}
