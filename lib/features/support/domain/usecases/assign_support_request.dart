import '../../../../core/error/result.dart';
import '../entities/support_request.dart';
import '../repositories/support_request_repository.dart';

/// Takes a support request: `WAITING -> ASSIGNED`.
///
/// The technician identity comes from the User JWT. Nothing identifying the
/// technician is sent by the client, and the backend performs a conditional
/// transition, so two technicians pressing "take" at the same time cannot both
/// succeed: the loser gets a `409`.
class AssignSupportRequest {
  const AssignSupportRequest({required SupportRequestRepository repository})
    : _repository = repository;

  final SupportRequestRepository _repository;

  Future<Result<SupportRequest>> call({required String requestId}) =>
      _repository.assign(id: requestId);
}
