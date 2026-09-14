import '../../../../core/error/result.dart';
import '../entities/device.dart';

/// Devices boundary of the domain layer.
///
/// Implementations own the REST calls and obtain the User JWT themselves, so
/// use cases and BLoCs never handle the token.
abstract interface class DeviceRepository {
  /// `GET /devices` — every device, newest first, each with its current
  /// `isOnline`.
  Future<Result<List<Device>>> loadDevices();

  /// `GET /devices/:id` — one device, same shape as a `GET /devices` element.
  Future<Result<Device>> loadDevice({required String id});
}
