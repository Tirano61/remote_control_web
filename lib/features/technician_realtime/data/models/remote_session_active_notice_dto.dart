import '../../domain/entities/remote_session_active_notice.dart';
import '../realtime_contract.dart';

/// Parses the `remote-session:active` payload:
/// `{ "remoteSessionId": "..." }`.
///
/// A payload without a usable `remoteSessionId` is dropped rather than turned
/// into a half built notice: a notification that names no session cannot
/// trigger anything, and guessing which session it meant is exactly the kind
/// of invention REST exists to avoid.
class RemoteSessionActiveNoticeDto {
  const RemoteSessionActiveNoticeDto._();

  static RemoteSessionActiveNotice? fromEvent(Object? data) {
    if (data is! Map<Object?, Object?>) return null;
    final id = data[TechnicianRealtimeContract.remoteSessionIdField];
    if (id is! String || id.trim().isEmpty) return null;
    return RemoteSessionActiveNotice(remoteSessionId: id);
  }
}
