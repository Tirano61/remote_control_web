import 'package:equatable/equatable.dart';

import '../../../technician_realtime/domain/entities/signaling_error_code.dart';
import 'signaling_limits.dart';

/// Outcome of one `webrtc:*` relay attempt.
///
/// Four things can happen, and they mean very different things: the backend
/// took the message, the backend refused it, the client never sent it, or no
/// usable acknowledgement came back.
sealed class SignalingRelayResult extends Equatable {
  const SignalingRelayResult();

  /// Whether the backend handed the message to the peer's namespace.
  bool get isDelivered => false;

  @override
  List<Object?> get props => const [];
}

/// ACK `{ "delivered": true, "remoteSessionId": ... }`.
///
/// It means exactly one thing: *the backend relay accepted the message and
/// emitted it into the other namespace*. It does **not** mean the remote peer
/// received it, parsed the SDP, applied it, or that a WebRTC connection
/// exists. `docs/backend/REALTIME.md`: *"If the other end has not joined the
/// session yet, the room is empty and the message is silently dropped."*
final class SignalingRelayDelivered extends SignalingRelayResult {
  const SignalingRelayDelivered(this.remoteSessionId);

  final String remoteSessionId;

  @override
  bool get isDelivered => true;

  @override
  List<Object?> get props => [remoteSessionId];

  @override
  String toString() => 'SignalingRelayDelivered($remoteSessionId)';
}

/// ACK `{ "delivered": false, "error": ... }`.
///
/// [error] is the stable code to branch on. An unknown future code is kept and
/// treated as a refusal, never as a success.
final class SignalingRelayRefused extends SignalingRelayResult {
  const SignalingRelayRefused({
    required this.remoteSessionId,
    required this.error,
  });

  /// The session the refused message was addressed to. It is taken from the
  /// request, because a rejected ACK carries no id.
  final String remoteSessionId;

  final SignalingErrorCode error;

  @override
  List<Object?> get props => [remoteSessionId, error];

  @override
  String toString() =>
      'SignalingRelayRefused($remoteSessionId, ${error.wireValue})';
}

/// The message never reached the wire.
///
/// A local decision, taken before emitting: no socket, no room membership, a
/// different session, or a payload that could only have produced
/// `INVALID_PAYLOAD`.
final class SignalingRelayNotSent extends SignalingRelayResult {
  const SignalingRelayNotSent(this.reason, {this.violation});

  final SignalingNotSentReason reason;

  /// Set when [reason] is [SignalingNotSentReason.invalidPayload].
  final SignalingPayloadViolation? violation;

  @override
  List<Object?> get props => [reason, violation];

  @override
  String toString() => violation == null
      ? 'SignalingRelayNotSent($reason)'
      : 'SignalingRelayNotSent($reason, $violation)';
}

/// The message was emitted but no usable acknowledgement came back.
///
/// The backend *always* answers its acknowledgements, including on rejection,
/// so this means the message never made it or the answer did not have the
/// documented shape.
final class SignalingRelayUnanswered extends SignalingRelayResult {
  const SignalingRelayUnanswered(this.reason);

  final SignalingRelayUnansweredReason reason;

  @override
  List<Object?> get props => [reason];

  @override
  String toString() => 'SignalingRelayUnanswered($reason)';
}

/// Why a relay was refused locally, before any emission.
enum SignalingNotSentReason {
  /// There is no connected socket to send it through.
  notConnected,

  /// This socket is not in any signaling room. `remote-session:join` first.
  notJoined,

  /// This socket is joined, but to a different remote session.
  sessionMismatch,

  /// The payload would have been rejected with `INVALID_PAYLOAD`.
  invalidPayload,
}

/// Why a relay produced no usable acknowledgement.
enum SignalingRelayUnansweredReason {
  /// Nothing came back within the acknowledgement timeout.
  timeout,

  /// The acknowledgement did not match the documented contract.
  malformedAck,
}
