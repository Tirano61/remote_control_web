import '../../../../core/network/api_client.dart';
import '../../domain/entities/device.dart';
import '../models/device_dto.dart';

/// REST access to the device endpoints documented in
/// `docs/backend/ENDPOINTS.md` under "Devices administration — Web".
///
/// Paths, methods and payloads are defined here and nowhere else. Every route
/// of this group requires a User JWT with role `admin` or `tecnico`.
abstract interface class DevicesRemoteDataSource {
  /// `GET /devices` — no body, no query parameters. Answers a JSON array.
  Future<List<Device>> fetchDevices({required String token});

  /// `GET /devices/:id` — `id` is the device UUID.
  Future<Device> fetchDevice({required String id, required String token});
}

class DevicesRemoteDataSourceImpl implements DevicesRemoteDataSource {
  const DevicesRemoteDataSourceImpl({required ApiClient apiClient})
    : _apiClient = apiClient;

  static const String devicesPath = '/devices';

  static String devicePath(String id) => '$devicesPath/$id';

  final ApiClient _apiClient;

  @override
  Future<List<Device>> fetchDevices({required String token}) async {
    final response = await _apiClient.getList(devicesPath, bearerToken: token);
    return DeviceDto.listFromJson(response.data);
  }

  @override
  Future<Device> fetchDevice({
    required String id,
    required String token,
  }) async {
    final response = await _apiClient.get(devicePath(id), bearerToken: token);
    return DeviceDto.fromJson(response.data);
  }
}
