import '../../domain/entities/remote_session_closed_notice.dart';
import '../realtime_contract.dart';

/// Parses the `remote-session:closed` payload of the `/technicians` namespace:
/// `{ "remoteSessionId": "...", "endedBy": "DEVICE" }`.
///
/// A payload that does not carry a usable `remoteSessionId` is dropped rather
/// than turned into a half built notice: the console would not know what to
/// reconcile, and the event is only a trigger anyway.
class RemoteSessionClosedNoticeDto {
  const RemoteSessionClosedNoticeDto._();

  static RemoteSessionClosedNotice? fromEvent(Object? data) {
    if (data is! Map<Object?, Object?>) return null;
    final id = data[TechnicianRealtimeContract.remoteSessionIdField];
    if (id is! String || id.trim().isEmpty) return null;
    final endedBy = data[TechnicianRealtimeContract.endedByField];
    return RemoteSessionClosedNotice(
      remoteSessionId: id,
      endedBy: endedBy is String ? endedBy : null,
    );
  }
}
