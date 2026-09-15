import 'package:equatable/equatable.dart';

/// The `remote-session:peer-joined` notification of the `/technicians`
/// namespace: `{ "remoteSessionId": "..." }`.
///
/// It says one thing only: the other end of that session is now inside its
/// signaling room, so a `webrtc:offer` would reach somebody instead of being
/// dropped into an empty room.
///
/// It is **readiness, never authorization**. What this technician may do with
/// the session was decided by the join the backend already accepted; this
/// event does not widen it, and an event naming a session the console does not
/// hold changes nothing.
///
/// It is idempotent: receiving it twice, or after an ACK that already said
/// `peerJoined: true`, means exactly what receiving it once means.
class RemoteSessionPeerJoinedNotice extends Equatable {
  const RemoteSessionPeerJoinedNotice({required this.remoteSessionId});

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];

  @override
  String toString() =>
      'RemoteSessionPeerJoinedNotice(remoteSessionId: $remoteSessionId)';
}
