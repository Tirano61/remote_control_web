import 'package:equatable/equatable.dart';

import 'signaling_limits.dart';

/// The `{ remoteSessionId, sdp }` payload shared by `webrtc:offer` and
/// `webrtc:answer`.
///
/// `docs/backend/REALTIME.md`: *"Identical to `webrtc:offer` in payload,
/// constraints, relayed shape and ACK. Only the event name differs"*. The
/// offer/answer distinction therefore lives in the type, exactly as it lives
/// in the event name on the wire — the SDP itself is never interpreted here.
sealed class WebRtcSessionDescription extends Equatable {
  const WebRtcSessionDescription({
    required this.remoteSessionId,
    required this.sdp,
  });

  /// Session the relay is addressed to. It must be the one this socket is
  /// currently joined to, or nothing is sent.
  final String remoteSessionId;

  /// Session description. Never logged, never persisted, never printed.
  final String sdp;

  /// What may be shown in a debug log instead of [sdp].
  int get sdpLength => sdp.length;

  /// `null` when the payload satisfies the documented DTO.
  SignalingPayloadViolation? validate() {
    if (remoteSessionId.trim().isEmpty) {
      return SignalingPayloadViolation.missingRemoteSessionId;
    }
    if (sdp.length < SignalingLimits.minSdpLength) {
      return SignalingPayloadViolation.emptySdp;
    }
    if (sdp.length > SignalingLimits.maxSdpLength) {
      return SignalingPayloadViolation.sdpTooLong;
    }
    return null;
  }

  @override
  List<Object?> get props => [remoteSessionId, sdp];

  /// Deliberately overridden: `Equatable` stringifies its props by default on
  /// Flutter Web, which would put the whole SDP into any log that printed an
  /// offer or an answer.
  @override
  String toString() =>
      '$runtimeType(remoteSessionId: $remoteSessionId, sdpLength: $sdpLength)';
}

/// Payload of `webrtc:offer`.
final class WebRtcOffer extends WebRtcSessionDescription {
  const WebRtcOffer({required super.remoteSessionId, required super.sdp});
}

/// Payload of `webrtc:answer`.
final class WebRtcAnswer extends WebRtcSessionDescription {
  const WebRtcAnswer({required super.remoteSessionId, required super.sdp});
}
