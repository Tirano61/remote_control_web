import '../../../../core/error/result.dart';
import '../entities/support_request.dart';
import '../entities/support_request_status.dart';

/// Support requests boundary of the domain layer, technician side.
///
/// Implementations own the REST calls and obtain the User JWT themselves.
abstract interface class SupportRequestRepository {
  /// `GET /support-requests` — the queue, oldest first.
  ///
  /// [status] maps to the documented `status` query parameter; omitting it
  /// returns every request.
  Future<Result<List<SupportRequest>>> loadRequests({
    SupportRequestStatus? status,
  });

  /// `GET /support-requests/:id` — one request, same shape as a queue element.
  Future<Result<SupportRequest>> loadRequest({required String id});

  /// `POST /support-requests/:id/assign` — take the request.
  ///
  /// The technician is the authenticated user: no identifier is ever sent.
  Future<Result<SupportRequest>> assign({required String id});
}
