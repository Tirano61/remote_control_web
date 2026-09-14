import '../../../../core/error/result.dart';
import '../entities/device.dart';
import '../repositories/device_repository.dart';

/// Reads the device list for the technician console.
///
/// The backend returns them newest first; presence (`isOnline`) is recomputed
/// server side on every call, which is why a manual refresh is enough and no
/// polling is needed.
class LoadDevices {
  const LoadDevices({required DeviceRepository repository})
    : _repository = repository;

  final DeviceRepository _repository;

  Future<Result<List<Device>>> call() => _repository.loadDevices();
}
