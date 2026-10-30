import '../../domain/entities/support_request_updated_notice.dart';
import '../realtime_contract.dart';

/// Parses the `support-request:updated` payload:
/// `{ "supportRequestId": "..." }`.
///
/// A payload without a usable `supportRequestId` is dropped rather than turned
/// into a half built notice: a malformed event must not cost a REST round
/// trip, let alone throw inside a socket callback. Any other field is ignored,
/// so nothing the event carries can ever become state.
class SupportRequestUpdatedNoticeDto {
  const SupportRequestUpdatedNoticeDto._();

  static SupportRequestUpdatedNotice? fromEvent(Object? data) {
    if (data is! Map<Object?, Object?>) return null;
    final id = data[TechnicianRealtimeContract.supportRequestIdField];
    if (id is! String || id.trim().isEmpty) return null;
    return SupportRequestUpdatedNotice(supportRequestId: id);
  }
}
