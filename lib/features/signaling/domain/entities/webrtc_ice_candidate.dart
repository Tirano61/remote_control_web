import 'package:equatable/equatable.dart';

import 'signaling_limits.dart';

/// The `webrtc:ice-candidate` payload of `docs/backend/REALTIME.md`.
///
/// `sdpMid` and `sdpMLineIndex` are genuinely optional in the contract — *"may
/// be omitted or sent explicitly as `null`, because real WebRTC
/// implementations produce them that way"* — so they are nullable here as
/// well, and the client always puts both keys on the wire with an explicit
/// `null` rather than dropping them.
class WebRtcIceCandidate extends Equatable {
  const WebRtcIceCandidate({
    required this.remoteSessionId,
    required this.candidate,
    this.sdpMid,
    this.sdpMLineIndex,
  });

  /// Session the relay is addressed to.
  final String remoteSessionId;

  /// Candidate line. The empty string is valid: *"some implementations use it
  /// to signal end-of-candidates"*. Never logged.
  final String candidate;

  final String? sdpMid;

  final int? sdpMLineIndex;

  /// What may be shown in a debug log instead of [candidate].
  int get candidateLength => candidate.length;

  /// The empty candidate some implementations send to close the gathering.
  bool get isEndOfCandidates => candidate.isEmpty;

  /// `null` when the payload satisfies the documented DTO.
  SignalingPayloadViolation? validate() {
    if (remoteSessionId.trim().isEmpty) {
      return SignalingPayloadViolation.missingRemoteSessionId;
    }
    if (candidate.length > SignalingLimits.maxCandidateLength) {
      return SignalingPayloadViolation.candidateTooLong;
    }
    final mid = sdpMid;
    if (mid != null && mid.length > SignalingLimits.maxSdpMidLength) {
      return SignalingPayloadViolation.sdpMidTooLong;
    }
    final index = sdpMLineIndex;
    if (index != null &&
        (index < SignalingLimits.minSdpMLineIndex ||
            index > SignalingLimits.maxSdpMLineIndex)) {
      return SignalingPayloadViolation.sdpMLineIndexOutOfRange;
    }
    return null;
  }

  @override
  List<Object?> get props => [
    remoteSessionId,
    candidate,
    sdpMid,
    sdpMLineIndex,
  ];

  /// Never the candidate itself: `Equatable` stringifies its props by default
  /// on Flutter Web, which would leak the whole candidate line into any log.
  @override
  String toString() =>
      'WebRtcIceCandidate(remoteSessionId: $remoteSessionId, '
      'candidateLength: $candidateLength)';
}
