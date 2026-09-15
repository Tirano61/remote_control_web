/// Sizes `docs/backend/REALTIME.md` documents for the `webrtc:*` payloads.
///
/// They are validated here as well as on the backend, so that an obviously
/// invalid payload never reaches the wire: the backend would answer
/// `INVALID_PAYLOAD`, which is a contract error and must not be produced by
/// this client in the first place.
class SignalingLimits {
  const SignalingLimits._();

  /// `sdp` is `1–32768 characters`: the empty string is *not* accepted.
  static const int minSdpLength = 1;
  static const int maxSdpLength = 32768;

  /// `candidate` is `max 1024 characters; the empty string is allowed`,
  /// because some implementations use it to signal end-of-candidates.
  static const int maxCandidateLength = 1024;

  /// `sdpMid` is `string | null`, optional, `max 64 characters`.
  static const int maxSdpMidLength = 64;

  /// `sdpMLineIndex` is `integer | null`, optional, `0–255`.
  static const int minSdpMLineIndex = 0;
  static const int maxSdpMLineIndex = 255;
}

/// Why a payload built by this client would not satisfy the documented DTO.
///
/// Reaching one of these is a programming error, not something the user can
/// act on: it is reported to the caller and never retried or "fixed" by
/// trimming the payload.
enum SignalingPayloadViolation {
  /// No `remoteSessionId` to address the relay to.
  missingRemoteSessionId,

  /// `sdp` is empty; the contract requires at least one character.
  emptySdp,

  /// `sdp` is longer than [SignalingLimits.maxSdpLength].
  sdpTooLong,

  /// `candidate` is longer than [SignalingLimits.maxCandidateLength].
  candidateTooLong,

  /// `sdpMid` is longer than [SignalingLimits.maxSdpMidLength].
  sdpMidTooLong,

  /// `sdpMLineIndex` is outside `0–255`.
  sdpMLineIndexOutOfRange,
}
