/// A video track the tablet is sending, as the application sees it.
///
/// It is deliberately opaque. The real object behind it is a
/// `MediaStreamTrack` living inside the `flutter_webrtc` adapter, and nothing
/// above the data layer may touch it: a BLoC has no use for a media object,
/// and a widget must not depend on the WebRTC package to know that a screen is
/// arriving.
///
/// What crosses the boundary is therefore an identity, not media:
///
/// ```text
/// id   the browser's track id — an opaque string, no frame, no codec,
///      no content; safe to log and safe to compare.
/// ```
///
/// **Rendering.** The track is displayed with an `RTCVideoRenderer`, which
/// needs the real media object. Presentation hands this handle to a
/// `RemoteVideoRenderer` port, whose only implementation lives in `data` next
/// to the peer connection adapter, where the concrete implementation of this
/// interface is recognised and unwrapped. So presentation never learns what
/// is inside — exactly as it passes a `WebRtcOffer` to signaling.
abstract interface class RemoteVideoTrack {
  /// The track id reported by WebRTC. Opaque, stable for the life of the
  /// track, and free of media content.
  String get id;
}
