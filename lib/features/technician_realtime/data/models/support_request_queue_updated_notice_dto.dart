import '../../domain/entities/support_request_queue_updated_notice.dart';
import '../realtime_contract.dart';

/// Parses the `support-request:queue-updated` payload:
/// `{ "supportRequestId": "..." }`.
///
/// Same rules as `support-request:updated`: a payload without a usable
/// `supportRequestId` is dropped, never thrown on, and any other field is
/// ignored, so nothing the event carries can ever become state.
class SupportRequestQueueUpdatedNoticeDto {
  const SupportRequestQueueUpdatedNoticeDto._();

  static SupportRequestQueueUpdatedNotice? fromEvent(Object? data) {
    if (data is! Map<Object?, Object?>) return null;
    final id = data[TechnicianRealtimeContract.supportRequestIdField];
    if (id is! String || id.trim().isEmpty) return null;
    return SupportRequestQueueUpdatedNotice(supportRequestId: id);
  }
}
