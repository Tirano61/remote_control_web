import '../entities/join_remote_session_result.dart';
import '../entities/remote_session_closed_notice.dart';
import '../entities/technician_realtime_status.dart';

/// Port that hides Socket.IO from the rest of the application.
///
/// Presentation and domain depend on this interface only: nothing above the
/// data layer knows that a `Socket`, a namespace or a handshake exist. The
/// implementation owns the transport, the reconnection policy and the token.
///
/// It covers the `/technicians` namespace of `docs/backend/REALTIME.md` as far
/// as this stage needs it — connection, the `remote-session:closed` domain
/// notification and `remote-session:join`. WebRTC signaling events are a later
/// stage and are deliberately absent.
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

  /// Opens the namespace with the User JWT that is valid right now.
  ///
  /// Calling it while already connected or connecting does nothing.
  Future<void> connect();

  /// Closes the connection and stops reconnecting.
  Future<void> disconnect();

  /// Sends `remote-session:join` and waits for its acknowledgement.
  ///
  /// Joining is connection scoped: after every reconnection the caller has to
  /// join again.
  Future<JoinRemoteSessionResult> joinRemoteSession(String remoteSessionId);

  /// Releases the streams and the underlying socket.
  Future<void> dispose();
}
