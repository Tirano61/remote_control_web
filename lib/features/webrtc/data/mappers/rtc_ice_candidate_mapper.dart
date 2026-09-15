import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../../signaling/domain/entities/webrtc_ice_candidate.dart';

/// Translates ICE candidates between `flutter_webrtc` and the signaling model.
///
/// Nothing is filtered by candidate type: host, srflx and relay candidates are
/// relayed exactly as they were produced, with their `sdpMid` and
/// `sdpMLineIndex`, because deciding which ones are useful is ICE's job.
///
/// End-of-candidates:
///
/// * **outgoing** — the browser signals the end of gathering with a `null`
///   candidate, and `flutter_webrtc` drops that event before it reaches this
///   application. Nothing is therefore sent for it, which the contract allows:
///   the empty `candidate` string is *accepted*, never required;
/// * **incoming** — `docs/backend/REALTIME.md` explicitly allows
///   `candidate: ""`, which is how the peer says "no more candidates for this
///   m-section". It is not discarded as invalid: it is handed to
///   `addCandidate` as it is, since an empty candidate line with an `sdpMid`
///   is the standard end-of-candidates indication.
class RtcIceCandidateMapper {
  const RtcIceCandidateMapper._();

  /// `onIceCandidate` -> the payload of `webrtc:ice-candidate`.
  ///
  /// Returns `null` when there is nothing to relay, which is what a candidate
  /// without a candidate line is.
  static WebRtcIceCandidate? fromRtc(
    rtc.RTCIceCandidate candidate, {
    required String remoteSessionId,
  }) {
    final line = candidate.candidate;
    if (line == null) return null;
    return WebRtcIceCandidate(
      remoteSessionId: remoteSessionId,
      candidate: line,
      sdpMid: candidate.sdpMid,
      sdpMLineIndex: candidate.sdpMLineIndex,
    );
  }

  /// A relayed `webrtc:ice-candidate` -> the argument of `addCandidate`.
  ///
  /// Returns `null` when the candidate cannot be applied. That is the case
  /// without an `sdpMid`: the contract makes it optional because some
  /// implementations omit it, but the web implementation of `flutter_webrtc`
  /// dereferences it, and a browser cannot place a candidate that names
  /// neither a mid nor an m-line index anyway. Dropping one candidate is
  /// survivable; ICE has the others.
  static rtc.RTCIceCandidate? toRtc(WebRtcIceCandidate candidate) {
    final sdpMid = candidate.sdpMid;
    if (sdpMid == null) return null;
    return rtc.RTCIceCandidate(
      candidate.candidate,
      sdpMid,
      candidate.sdpMLineIndex,
    );
  }
}
