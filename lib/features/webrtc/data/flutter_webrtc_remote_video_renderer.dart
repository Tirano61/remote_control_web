import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../../core/logging/debug_log.dart';
import '../domain/entities/remote_video_track.dart';
import '../presentation/remote_screen/remote_video_renderer.dart';
import 'flutter_webrtc_remote_video_track.dart';

/// Creates the `RTCVideoRenderer`. Replaced in tests, where no browser exists.
typedef RtcVideoRendererFactory = rtc.RTCVideoRenderer Function();

/// Creates an empty local `MediaStream`. Replaced in tests.
typedef RtcLocalMediaStreamFactory =
    Future<rtc.MediaStream> Function(String label);

rtc.RTCVideoRenderer _createRenderer() => rtc.RTCVideoRenderer();

/// Shows a [FlutterWebRtcRemoteVideoTrack] with an `RTCVideoRenderer`.
///
/// Together with the peer connection adapter, this is the only place that
/// touches the real media objects. Presentation hands it an opaque
/// [RemoteVideoTrack]; it recognises its own concrete handle and unwraps it
/// here, so no BLoC and no widget imports `package:flutter_webrtc`.
///
/// One instance owns exactly one `RTCVideoRenderer`, created with it and
/// initialised at most once:
///
/// ```text
/// constructor  RTCVideoRenderer()
/// initialize   renderer.initialize()           (memoised)
/// attach       renderer.srcObject = stream     (replaces the previous one)
/// detach       renderer.srcObject = null
/// dispose      renderer.dispose()               (once)
/// ```
///
/// Nothing here owns the media. The track and the stream it was announced in
/// belong to the peer connection and die with it, so they are never stopped
/// or disposed here: letting go of the reference is all this side does.
///
/// Security: no frame and no media content is ever logged — only the track's
/// opaque id.
class FlutterWebRtcRemoteVideoRenderer extends ChangeNotifier
    implements RemoteVideoRenderer {
  FlutterWebRtcRemoteVideoRenderer({
    RtcVideoRendererFactory rendererFactory = _createRenderer,
    RtcLocalMediaStreamFactory localMediaStreamFactory =
        rtc.createLocalMediaStream,
  }) : _renderer = rendererFactory(),
       _localMediaStreamFactory = localMediaStreamFactory {
    _renderer.addListener(_onRendererChanged);
  }

  /// The image is letterboxed into the space it gets: never cropped, never
  /// stretched. A tablet screen is read, not decorated.
  static const rtc.RTCVideoViewObjectFit objectFit =
      rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitContain;

  /// A screen is not a selfie: what the tablet shows is shown as it is.
  static const bool mirror = false;

  final rtc.RTCVideoRenderer _renderer;
  final RtcLocalMediaStreamFactory _localMediaStreamFactory;

  /// The single `initialize()` of the renderer, memoised as a future so that
  /// overlapping callers wait on the same one.
  Future<void>? _initialization;
  bool _isInitialized = false;
  bool _isDisposed = false;

  /// Bumped by every attach, detach and dispose. An attach that finds a
  /// different number after an await was overtaken by a newer request and
  /// must not touch the renderer any more: the newest request always wins.
  int _attachment = 0;

  FlutterWebRtcRemoteVideoTrack? _track;

  @override
  RemoteVideoTrack? get track => _track;

  @override
  bool get isDisplaying => !_isDisposed && _isInitialized && _track != null;

  @override
  double? get aspectRatio {
    if (!isDisplaying) return null;
    final value = _renderer.value;
    // Unknown until the video element has decoded enough to know its size.
    if (value.width <= 0 || value.height <= 0) return null;
    // Already accounts for a rotation reported by the renderer.
    return value.aspectRatio;
  }

  @override
  Future<void> initialize() {
    if (_isDisposed) return Future<void>.value();
    return _initialization ??= _initializeRenderer().then(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        // Not memoised as a failure: a later attach may try again. `then`
        // always runs after the assignment above, so this cannot be undone
        // by it.
        _initialization = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }

  Future<void> _initializeRenderer() async {
    await _renderer.initialize();
    _isInitialized = true;
  }

  @override
  Future<RemoteVideoAttachResult> attach(RemoteVideoTrack track) async {
    if (_isDisposed) return RemoteVideoAttachResult.disposed;
    if (identical(track, _track)) return RemoteVideoAttachResult.attached;

    final attachment = ++_attachment;

    if (track is! FlutterWebRtcRemoteVideoTrack) {
      // Not produced by the `flutter_webrtc` adapter: there is no media
      // object to unwrap. Whatever was on screen is not this track, so it is
      // not left there either.
      logDebug('remote video track not displayable ${track.id}');
      _clear();
      return RemoteVideoAttachResult.unsupportedTrack;
    }

    try {
      await initialize();
      if (attachment != _attachment) return _overtaken();

      final stream = await _videoStreamOf(track);
      if (attachment != _attachment) return _overtaken();

      _renderer.srcObject = stream;
      _track = track;
      logDebug('remote video attached ${track.id}');
      notifyListeners();
      return RemoteVideoAttachResult.attached;
    } catch (_) {
      if (attachment != _attachment) return _overtaken();
      logDebug('remote video attach failed ${track.id}');
      _clear();
      return RemoteVideoAttachResult.failed;
    }
  }

  @override
  Future<void> detach() async {
    if (_isDisposed) return;
    _attachment++;
    if (_track == null) return;
    _clear();
    logDebug('remote video detached');
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _attachment++;
    _track = null;
    _renderer.removeListener(_onRendererChanged);
    super.dispose();

    // An initialisation still in flight would otherwise finish after the
    // dispose and leave its video element behind.
    final initialization = _initialization;
    if (initialization != null) {
      try {
        await initialization;
      } catch (_) {
        // Nothing was created, so there is nothing more to release for it.
      }
    }
    _unbind();
    try {
      await _renderer.dispose();
    } catch (_) {
      logDebug('remote video renderer teardown ignored an error');
    }
    logDebug('remote video renderer disposed');
  }

  @override
  Widget buildView(BuildContext context) =>
      rtc.RTCVideoView(_renderer, objectFit: objectFit, mirror: mirror);

  /// The stream to hand to `srcObject`, carrying the screen track only.
  ///
  /// The stream the track was announced in is used as it is when it holds
  /// that video track and nothing else — the normal case, since the tablet
  /// sends no audio. Otherwise (no `msid` in the answer, or a stream that
  /// unexpectedly carries more) a local stream wrapping the track alone is
  /// built, which is the least an `RTCVideoRenderer` needs: it renders
  /// streams, not tracks. Audio is never handed to the renderer, so nothing
  /// can ever be played.
  Future<rtc.MediaStream> _videoStreamOf(
    FlutterWebRtcRemoteVideoTrack track,
  ) async {
    final announced = track.mediaStream;
    if (announced != null && _carriesOnly(announced, track)) return announced;

    final stream = await _localMediaStreamFactory('remote-screen-${track.id}');
    await stream.addTrack(track.mediaStreamTrack);
    return stream;
  }

  static bool _carriesOnly(
    rtc.MediaStream stream,
    FlutterWebRtcRemoteVideoTrack track,
  ) {
    if (stream.getAudioTracks().isNotEmpty) return false;
    final videoTracks = stream.getVideoTracks();
    return videoTracks.length == 1 &&
        videoTracks.single.id == track.mediaStreamTrack.id;
  }

  RemoteVideoAttachResult _overtaken() => _isDisposed
      ? RemoteVideoAttachResult.disposed
      : RemoteVideoAttachResult.superseded;

  /// Nothing on screen any more, and listeners told so.
  void _clear() {
    final hadTrack = _track != null;
    _track = null;
    _unbind();
    if (hadTrack && !_isDisposed) notifyListeners();
  }

  void _unbind() {
    if (!_isInitialized) return;
    try {
      _renderer.srcObject = null;
    } catch (_) {
      // Unbinding something the browser already released is not an error.
    }
  }

  /// The renderer learned the video's size (first frames, a rotation, a new
  /// resolution).
  void _onRendererChanged() {
    if (!_isDisposed) notifyListeners();
  }
}
