import '../../../technician_realtime/domain/entities/signaling_error_code.dart';
import '../../domain/entities/signaling_relay_result.dart';
import '../signaling_contract.dart';

/// Parses the `SignalingRelayAck` of `docs/backend/REALTIME.md`.
///
/// Accepted:  `{ "delivered": true,  "remoteSessionId": "..." }`
/// Rejected:  `{ "delivered": false, "error": "NOT_JOINED" }`
///
/// Anything else is an unanswered relay: an acknowledgement that does not have
/// the documented shape is never read as a delivery.
class SignalingRelayAckDto {
  const SignalingRelayAckDto._();

  static SignalingRelayResult fromAck(
    Object? ack, {
    required String remoteSessionId,
  }) {
    const malformed = SignalingRelayUnanswered(
      SignalingRelayUnansweredReason.malformedAck,
    );

    if (ack is! Map<Object?, Object?>) return malformed;

    final delivered = ack[SignalingContract.deliveredField];
    if (delivered is! bool) return malformed;

    if (delivered) {
      final id = ack[SignalingContract.remoteSessionIdField];
      // The backend echoes the session it relayed for; anything else would
      // mean this acknowledgement is not about the message that was sent.
      if (id is! String || id != remoteSessionId) return malformed;
      return SignalingRelayDelivered(id);
    }

    final error = ack[SignalingContract.errorField];
    if (error is! String || error.trim().isEmpty) return malformed;
    return SignalingRelayRefused(
      // A rejected ACK carries no id, so it comes from the request.
      remoteSessionId: remoteSessionId,
      error: SignalingErrorCode.fromWire(error),
    );
  }
}
