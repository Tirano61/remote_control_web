import 'package:equatable/equatable.dart';

import 'signaling_error_code.dart';

/// Outcome of a `remote-session:join`.
sealed class JoinRemoteSessionResult extends Equatable {
  const JoinRemoteSessionResult();

  @override
  List<Object?> get props => const [];
}

/// ACK `{ "joined": true, "remoteSessionId": ... }`.
///
/// The socket is now in the signaling room of that session. It stays there
/// until the connection drops — rooms are connection scoped.
final class JoinRemoteSessionAccepted extends JoinRemoteSessionResult {
  const JoinRemoteSessionAccepted(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];

  @override
  String toString() => 'JoinRemoteSessionAccepted($remoteSessionId)';
}

/// ACK `{ "joined": false, "error": ... }`.
final class JoinRemoteSessionRejected extends JoinRemoteSessionResult {
  const JoinRemoteSessionRejected(this.error);

  final SignalingErrorCode error;

  @override
  List<Object?> get props => [error];

  @override
  String toString() => 'JoinRemoteSessionRejected(${error.wireValue})';
}

/// No usable ACK came back.
///
/// The backend always answers its acknowledgements, so this means the message
/// never made it: the socket was down, the connection died while waiting, or
/// the answer did not have the documented shape.
final class JoinRemoteSessionFailed extends JoinRemoteSessionResult {
  const JoinRemoteSessionFailed(this.reason);

  final JoinRemoteSessionFailureReason reason;

  @override
  List<Object?> get props => [reason];

  @override
  String toString() => 'JoinRemoteSessionFailed($reason)';
}

enum JoinRemoteSessionFailureReason {
  /// There was no connected socket to send the join through.
  notConnected,

  /// The acknowledgement never arrived.
  timeout,

  /// The acknowledgement did not match the documented contract.
  malformedAck,
}
