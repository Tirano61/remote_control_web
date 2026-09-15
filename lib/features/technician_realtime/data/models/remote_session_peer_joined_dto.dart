import '../../domain/entities/remote_session_peer_joined_notice.dart';
import '../realtime_contract.dart';

/// Parses the `remote-session:peer-joined` payload:
/// `{ "remoteSessionId": "..." }`.
///
/// A payload without a usable `remoteSessionId` is dropped rather than turned
/// into a half built notice: readiness that names no session is not readiness.
class RemoteSessionPeerJoinedDto {
  const RemoteSessionPeerJoinedDto._();

  static RemoteSessionPeerJoinedNotice? fromEvent(Object? data) {
    if (data is! Map<Object?, Object?>) return null;
    final id = data[TechnicianRealtimeContract.remoteSessionIdField];
    if (id is! String || id.trim().isEmpty) return null;
    return RemoteSessionPeerJoinedNotice(remoteSessionId: id);
  }
}
