import '../../domain/entities/remote_signaling_message.dart';
import '../../domain/entities/signaling_origin.dart';
import '../../domain/entities/webrtc_ice_candidate.dart';
import '../../domain/entities/webrtc_session_description.dart';
import '../signaling_contract.dart';

/// Parses the relayed `webrtc:*` payloads of `docs/backend/REALTIME.md`.
///
/// ```json
/// { "remoteSessionId": "...", "from": "DEVICE", "sdp": "..." }
/// { "remoteSessionId": "...", "from": "DEVICE", "candidate": "...",
///   "sdpMid": "0", "sdpMLineIndex": 0 }
/// ```
///
/// Parsing is defensive on purpose: this data arrives over a socket, and a
/// payload that does not match the contract is dropped rather than turned into
/// a half built message. Returning `null` is how a malformed event is ignored
/// without crashing the console.
///
/// The documented size limits are *not* re-checked here. The backend validates
/// them before relaying, and refusing a message the peer legitimately sent
/// would break the negotiation for nothing.
class RemoteSignalingMessageDto {
  const RemoteSignalingMessageDto._();

  static RemoteSignalingMessage? fromEvent(String event, Object? data) {
    if (data is! Map<Object?, Object?>) return null;

    final id = data[SignalingContract.remoteSessionIdField];
    if (id is! String || id.trim().isEmpty) return null;

    // Metadata only. An absent or unknown `from` does not discard a payload
    // that is otherwise valid for the session this socket joined.
    final origin = SignalingOrigin.fromWire(data[SignalingContract.fromField]);

    switch (event) {
      case SignalingContract.offerEvent:
        final sdp = _sdpOf(data);
        if (sdp == null) return null;
        return OfferReceived(
          offer: WebRtcOffer(remoteSessionId: id, sdp: sdp),
          origin: origin,
        );

      case SignalingContract.answerEvent:
        final sdp = _sdpOf(data);
        if (sdp == null) return null;
        return AnswerReceived(
          answer: WebRtcAnswer(remoteSessionId: id, sdp: sdp),
          origin: origin,
        );

      case SignalingContract.iceCandidateEvent:
        final candidate = data[SignalingContract.candidateField];
        // The empty string is a valid candidate: end-of-candidates.
        if (candidate is! String) return null;

        final sdpMid = data[SignalingContract.sdpMidField];
        if (sdpMid != null && sdpMid is! String) return null;

        final sdpMLineIndex = data[SignalingContract.sdpMLineIndexField];
        if (sdpMLineIndex != null && sdpMLineIndex is! int) return null;

        return IceCandidateReceived(
          candidate: WebRtcIceCandidate(
            remoteSessionId: id,
            candidate: candidate,
            sdpMid: sdpMid as String?,
            sdpMLineIndex: sdpMLineIndex as int?,
          ),
          origin: origin,
        );
    }

    return null;
  }

  /// `sdp` is required and must carry at least one character.
  static String? _sdpOf(Map<Object?, Object?> data) {
    final sdp = data[SignalingContract.sdpField];
    if (sdp is! String || sdp.isEmpty) return null;
    return sdp;
  }
}
