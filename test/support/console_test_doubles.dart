import 'package:remote_control_web/core/auth/user_token_provider.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/core/error/result.dart';
import 'package:remote_control_web/features/devices/data/datasources/devices_remote_data_source.dart';
import 'package:remote_control_web/features/devices/domain/entities/device.dart';
import 'package:remote_control_web/features/devices/domain/repositories/device_repository.dart';
import 'package:remote_control_web/features/support/data/datasources/support_remote_data_source.dart';
import 'package:remote_control_web/features/support/domain/entities/support_device.dart';
import 'package:remote_control_web/features/support/domain/entities/support_request.dart';
import 'package:remote_control_web/features/support/domain/entities/support_request_status.dart';
import 'package:remote_control_web/features/support/domain/entities/support_technician.dart';
import 'package:remote_control_web/features/support/domain/repositories/support_request_repository.dart';

/// In-memory [UserTokenProvider], standing in for the persisted User JWT.
class InMemoryUserTokenProvider implements UserTokenProvider {
  InMemoryUserTokenProvider([this.token = 'user-jwt']);

  String? token;
  int readCount = 0;

  @override
  Future<String?> currentToken() async {
    readCount++;
    return token;
  }
}

/// Scripted [DevicesRemoteDataSource].
class FakeDevicesRemoteDataSource implements DevicesRemoteDataSource {
  List<Device> devices = const [];
  Object? error;

  final List<String> fetchDevicesTokens = [];
  final List<String> fetchDeviceIds = [];

  @override
  Future<List<Device>> fetchDevices({required String token}) async {
    fetchDevicesTokens.add(token);
    final failure = error;
    if (failure != null) throw failure;
    return devices;
  }

  @override
  Future<Device> fetchDevice({
    required String id,
    required String token,
  }) async {
    fetchDeviceIds.add(id);
    final failure = error;
    if (failure != null) throw failure;
    return devices.firstWhere((device) => device.id == id);
  }
}

/// Scripted [SupportRemoteDataSource].
class FakeSupportRemoteDataSource implements SupportRemoteDataSource {
  List<SupportRequest> requests = const [];
  SupportRequest? assignResponse;
  Object? fetchError;
  Object? assignError;

  final List<({String token, SupportRequestStatus? status})> fetchCalls = [];
  final List<String> assignedIds = [];

  @override
  Future<List<SupportRequest>> fetchRequests({
    required String token,
    SupportRequestStatus? status,
  }) async {
    fetchCalls.add((token: token, status: status));
    final failure = fetchError;
    if (failure != null) throw failure;
    if (status == null) return requests;
    return requests
        .where((request) => request.status == status)
        .toList(growable: false);
  }

  @override
  Future<SupportRequest> fetchRequest({
    required String id,
    required String token,
  }) async {
    final failure = fetchError;
    if (failure != null) throw failure;
    return requests.firstWhere((request) => request.id == id);
  }

  @override
  Future<SupportRequest> assign({
    required String id,
    required String token,
  }) async {
    assignedIds.add(id);
    final failure = assignError;
    if (failure != null) throw failure;
    return assignResponse ??
        requests
            .firstWhere((request) => request.id == id)
            .copyWith(status: SupportRequestStatus.assigned);
  }
}

/// Scripted [DeviceRepository], for tests that do not exercise the data layer.
class FakeDeviceRepository implements DeviceRepository {
  List<Device> devices = const [];
  Failure? failure;

  /// Applied instead of [failure] from the second load onwards, which is how
  /// the "retry succeeds" scenarios are scripted.
  Failure? failureAfterFirstLoad;
  bool _loaded = false;

  int loadCount = 0;

  @override
  Future<Result<List<Device>>> loadDevices() async {
    loadCount++;
    final current = _loaded ? failureAfterFirstLoad ?? failure : failure;
    _loaded = true;
    if (current != null) return Failed(current);
    return Success(devices);
  }

  @override
  Future<Result<Device>> loadDevice({required String id}) async {
    final current = failure;
    if (current != null) return Failed(current);
    return Success(devices.firstWhere((device) => device.id == id));
  }
}

/// Scripted [SupportRequestRepository].
class FakeSupportRequestRepository implements SupportRequestRepository {
  List<SupportRequest> requests = const [];
  Failure? loadFailure;
  Failure? assignFailure;

  /// Queue returned from the second load onwards, used to simulate what the
  /// backend answers after the tablet accepted or rejected.
  List<SupportRequest>? requestsAfterFirstLoad;
  bool _loaded = false;

  /// Completer-free way of keeping an `assign` call in flight: when set, the
  /// call awaits this future before answering.
  Future<void>? assignGate;

  int loadCount = 0;
  final List<String> assignedIds = [];

  @override
  Future<Result<List<SupportRequest>>> loadRequests({
    SupportRequestStatus? status,
  }) async {
    loadCount++;
    final failure = loadFailure;
    if (failure != null) return Failed(failure);
    final source = _loaded ? requestsAfterFirstLoad ?? requests : requests;
    _loaded = true;
    if (status == null) return Success(source);
    return Success(
      source.where((request) => request.status == status).toList(growable: false),
    );
  }

  @override
  Future<Result<SupportRequest>> loadRequest({required String id}) async {
    final failure = loadFailure;
    if (failure != null) return Failed(failure);
    return Success(requests.firstWhere((request) => request.id == id));
  }

  @override
  Future<Result<SupportRequest>> assign({required String id}) async {
    assignedIds.add(id);
    final gate = assignGate;
    if (gate != null) await gate;
    final failure = assignFailure;
    if (failure != null) return Failed(failure);
    final assigned = requests
        .firstWhere((request) => request.id == id)
        .copyWith(
          status: SupportRequestStatus.assigned,
          technicianId: technicianId,
          technician: const SupportTechnician(
            id: technicianId,
            name: 'Ana Torres',
          ),
          assignedAt: DateTime.utc(2026, 3, 11, 9, 31, 12),
        );
    requests = requests
        .map((request) => request.id == id ? assigned : request)
        .toList(growable: false);
    return Success(assigned);
  }
}

/// Id of the technician the console fixtures are signed in as.
const String technicianId = '11111111-2222-3333-4444-555555555555';

const String deviceId = '550e8400-e29b-41d4-a716-446655440000';
const String requestId = '8f14e45f-ceea-4d3c-b4e2-2f4b3c9a1d77';

Device buildDevice({
  String id = deviceId,
  String publicId = '132-491-092',
  String? name = 'Tablet Prueba',
  String? manufacturer = 'SKY',
  String? model = 'SKY_PAD10MAX',
  String? androidVersion = '14',
  String? appVersion = '1.0.0',
  bool isActive = true,
  bool isOnline = true,
}) => Device(
  id: id,
  publicId: publicId,
  name: name,
  manufacturer: manufacturer,
  model: model,
  androidVersion: androidVersion,
  appVersion: appVersion,
  isActive: isActive,
  isOnline: isOnline,
  createdAt: DateTime.utc(2026, 3, 11, 9, 14, 2),
  updatedAt: DateTime.utc(2026, 3, 11, 9, 20, 31),
);

SupportDevice buildSupportDevice({
  String id = deviceId,
  String publicId = '132-491-092',
  String? name = 'Tablet Prueba',
  String? manufacturer = 'SKY',
  String? model = 'SKY_PAD10MAX',
  bool isOnline = true,
}) => SupportDevice(
  id: id,
  publicId: publicId,
  name: name,
  manufacturer: manufacturer,
  model: model,
  isOnline: isOnline,
);

SupportRequest buildSupportRequest({
  String id = requestId,
  SupportRequestStatus? status,
  String? technician,
  SupportDevice? device,
  bool isDeviceOnline = true,
  DateTime? createdAt,
  DateTime? assignedAt,
  DateTime? respondedAt,
  DateTime? closedAt,
}) {
  final resolvedStatus = status ?? SupportRequestStatus.waiting;
  return SupportRequest(
    id: id,
    deviceId: deviceId,
    status: resolvedStatus,
    createdAt: createdAt ?? DateTime.utc(2026, 3, 11, 9, 30),
    technicianId: technician,
    technician: technician == null
        ? null
        : SupportTechnician(id: technician, name: 'Ana Torres'),
    device: device ?? buildSupportDevice(isOnline: isDeviceOnline),
    assignedAt: assignedAt,
    respondedAt: respondedAt,
    closedAt: closedAt,
  );
}
