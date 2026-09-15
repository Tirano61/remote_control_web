import '../../domain/entities/join_remote_session_result.dart';
import '../../domain/entities/signaling_error_code.dart';
import '../realtime_contract.dart';

/// Parses the `JoinRemoteSessionAck` of the `/technicians` namespace.
///
/// Accepted:  `{ "joined": true,  "remoteSessionId": "...", "peerJoined": ? }`
/// Rejected:  `{ "joined": false, "error": "UNAUTHORIZED" }`
///
/// Anything else is a malformed acknowledgement: it is never silently read as
/// a success.
///
/// `peerJoined` is **required** in an accepted ACK. It is the readiness half
/// of the contract, and guessing a default would be inventing it: `false`
/// would ignore a device that is already waiting, and `true` would send an
/// offer into an empty room. An accepted ACK without it is therefore
/// malformed, exactly like one that echoes the wrong session.
class JoinRemoteSessionAckDto {
  const JoinRemoteSessionAckDto._();

  static JoinRemoteSessionResult fromAck(
    Object? ack, {
    required String requestedRemoteSessionId,
  }) {
    final Map<Object?, Object?> payload;
    if (ack is Map<Object?, Object?>) {
      payload = ack;
    } else {
      return const JoinRemoteSessionFailed(
        JoinRemoteSessionFailureReason.malformedAck,
      );
    }

    final joined = payload[TechnicianRealtimeContract.joinedField];
    if (joined is! bool) {
      return const JoinRemoteSessionFailed(
        JoinRemoteSessionFailureReason.malformedAck,
      );
    }

    if (joined) {
      final id = payload[TechnicianRealtimeContract.remoteSessionIdField];
      // The backend echoes the session it joined; anything else would mean the
      // socket is in a room the console did not ask for.
      if (id is! String || id != requestedRemoteSessionId) {
        return const JoinRemoteSessionFailed(
          JoinRemoteSessionFailureReason.malformedAck,
        );
      }
      final peerJoined = payload[TechnicianRealtimeContract.peerJoinedField];
      if (peerJoined is! bool) {
        return const JoinRemoteSessionFailed(
          JoinRemoteSessionFailureReason.malformedAck,
        );
      }
      return JoinRemoteSessionAccepted(id, peerJoined: peerJoined);
    }

    final error = payload[TechnicianRealtimeContract.errorField];
    if (error is! String || error.trim().isEmpty) {
      return const JoinRemoteSessionFailed(
        JoinRemoteSessionFailureReason.malformedAck,
      );
    }
    return JoinRemoteSessionRejected(SignalingErrorCode.fromWire(error));
  }
}
