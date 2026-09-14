import '../../../../core/error/result.dart';
import '../entities/support_request.dart';
import '../entities/support_request_status.dart';
import '../repositories/support_request_repository.dart';

/// Reads the support request queue.
///
/// The console asks for the whole queue and buckets it locally by `status`:
/// the technician needs `WAITING`, the requests already assigned to them and
/// the recently closed ones at the same time, and the documented `status`
/// filter accepts a single value per call. The bucketing is safe because the
/// status of every row comes from the backend response.
class LoadSupportRequests {
  const LoadSupportRequests({required SupportRequestRepository repository})
    : _repository = repository;

  final SupportRequestRepository _repository;

  Future<Result<List<SupportRequest>>> call({
    SupportRequestStatus? status,
  }) => _repository.loadRequests(status: status);
}
