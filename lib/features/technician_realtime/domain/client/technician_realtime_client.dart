import '../entities/join_remote_session_result.dart';
import '../entities/remote_session_active_notice.dart';
import '../entities/remote_session_closed_notice.dart';
import '../entities/remote_session_peer_joined_notice.dart';
import '../entities/technician_realtime_status.dart';

/// Port that hides Socket.IO from the rest of the application.
///
/// Presentation and domain depend on this interface only: nothing above the
/// data layer knows that a `Socket`, a namespace or a handshake exist. The
/// implementation owns the transport, the reconnection policy and the token.
///
/// It covers the `/technicians` namespace of `docs/backend/REALTIME.md` as far
/// as this stage needs it — connection, the `remote-session:closed` domain
/// notification and `remote-session:join`.
///
/// The `webrtc:*` relay travels over the very same socket, but it is a
/// different concern and has its own port, `TechnicianSignalingClient`. One
/// implementation serves both: there is exactly one physical connection.
abstract interface class TechnicianRealtimeClient {
  /// Current transport state.
  TechnicianRealtimeStatus get status;

  /// Transport state changes. Broadcast: several consumers may listen.
  Stream<TechnicianRealtimeStatus> get statusChanges;

  /// `remote-session:closed` notifications addressed to this technician.
  ///
  /// They require no join: the backend addresses the private room the socket
  /// entered when it authenticated.
  Stream<RemoteSessionClosedNotice> get remoteSessionClosed;

  /// `remote-session:active` notifications addressed to this technician.
  ///
  /// Like the closed one, it requires no join and is a trigger rather than a
  /// state: what the session became is read from REST.
  Stream<RemoteSessionActiveNotice> get remoteSessionActivated;

  /// Opens the namespace with the User JWT that is valid right now.
  ///
  /// Calling it while already connected or connecting does nothing.
  Future<void> connect();

  /// Closes the connection and stops reconnecting.
  Future<void> disconnect();

  /// `remote-session:peer-joined` notifications.
  ///
  /// The other half of the readiness contract: the join ACK answers whether
  /// the peer was *already* in the room, this stream says when it arrives
  /// afterwards. Both are needed, and neither is remembered across
  /// connections.
  Stream<RemoteSessionPeerJoinedNotice> get peerJoined;

  /// Sends `remote-session:join` and waits for its acknowledgement.
  ///
  ///
  /// Joining is connection scoped: after every reconnection the caller has to
  /// join again.
  ///
  /// An accepted join is also what makes signaling possible: the session it
  /// answered with becomes the only one `webrtc:*` may be relayed for, and its
  /// `peerJoined` flag is what tells the caller whether an offer would reach
  /// anybody yet.
  Future<JoinRemoteSessionResult> joinRemoteSession(String remoteSessionId);

  /// Forgets the joined signaling room without touching the connection.
  ///
  /// There is no event to leave a room — membership is a consequence of
  /// `remote-session:join` and of the connection staying up — so this only
  /// drops what the client believes. It is called when the console knows the
  /// membership is over or worthless: the assistance ended, the user signed
  /// out, or the backend answered a relay with `NOT_JOINED`.
  void forgetJoinedRemoteSession();

  /// Releases the streams and the underlying socket.
  Future<void> dispose();
}
