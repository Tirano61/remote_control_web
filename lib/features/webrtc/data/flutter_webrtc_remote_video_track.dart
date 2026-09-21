import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../domain/entities/remote_video_track.dart';

/// The `flutter_webrtc` side of a [RemoteVideoTrack].
///
/// It is the only place that holds the real media objects, and it exists so
/// that the rest of the application can talk about "the tablet's screen"
/// without importing `package:flutter_webrtc`.
///
/// Both objects are kept because a renderer needs a `MediaStream`
/// (`RTCVideoRenderer.srcObject`) while the track is what says whether this is
/// video at all and what its id is. The `streams` list of `onTrack` is filled
/// from the `msid` of the remote description, so it is normally present — but
/// a sender may omit it, and a null [mediaStream] is a legitimate state, not
/// an error.
///
/// Nothing here is a copy: the objects belong to the peer connection and die
/// with it. This class never closes or disposes them, and releasing it means
/// dropping the reference.
class FlutterWebRtcRemoteVideoTrack implements RemoteVideoTrack {
  const FlutterWebRtcRemoteVideoTrack({
    required this.mediaStreamTrack,
    this.mediaStream,
  });

  /// The remote track itself. `kind` is always `video` here: the adapter
  /// filters before building this object.
  final rtc.MediaStreamTrack mediaStreamTrack;

  /// The stream the track was announced in, when the remote description named
  /// one. What a future `RTCVideoRenderer` will be given.
  final rtc.MediaStream? mediaStream;

  @override
  String get id => mediaStreamTrack.id ?? '';
}
