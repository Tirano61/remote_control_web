import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:remote_control_web/features/webrtc/data/flutter_webrtc_remote_video_renderer.dart';
import 'package:remote_control_web/features/webrtc/data/flutter_webrtc_remote_video_track.dart';
import 'package:remote_control_web/features/webrtc/presentation/remote_screen/remote_video_renderer.dart';

import '../../../support/webrtc_test_doubles.dart';

/// The `RTCVideoRenderer` side of the remote screen, tested without a browser.
///
/// What is exercised is exactly what the adapter owns: one renderer,
/// initialised once, the stream handed to `srcObject`, the replacement of a
/// track by another, the unbinding and the teardown. No frame is decoded and
/// no Chromium internal is simulated.
void main() {
  late List<FakeRtcVideoRenderer> createdRenderers;
  late List<FakeMediaStream> localStreams;
  late FlutterWebRtcRemoteVideoRenderer renderer;

  FakeRtcVideoRenderer rtcRenderer() => createdRenderers.single;

  FlutterWebRtcRemoteVideoRenderer build() => FlutterWebRtcRemoteVideoRenderer(
    rendererFactory: () {
      final created = FakeRtcVideoRenderer();
      createdRenderers.add(created);
      return created;
    },
    localMediaStreamFactory: (label) async {
      final stream = FakeMediaStream(label);
      localStreams.add(stream);
      return stream;
    },
  );

  /// A screen track as the peer connection adapter publishes it.
  FlutterWebRtcRemoteVideoTrack screenTrack(
    String id, {
    bool announcedInStream = true,
  }) {
    final track = FakeMediaStreamTrack(kind: 'video', id: id);
    return FlutterWebRtcRemoteVideoTrack(
      mediaStreamTrack: track,
      mediaStream: announcedInStream
          ? (FakeMediaStream('stream-$id')..tracks.add(track))
          : null,
    );
  }

  setUp(() {
    createdRenderers = [];
    localStreams = [];
    renderer = build();
  });

  group('initialize', () {
    test('one renderer is created, with the adapter', () {
      expect(createdRenderers, hasLength(1));
      expect(rtcRenderer().initializeCount, 0);
    });

    test('it is initialised once, however many callers ask', () async {
      await Future.wait([renderer.initialize(), renderer.initialize()]);
      await renderer.initialize();
      await renderer.attach(screenTrack('screen-0'));
      await renderer.attach(screenTrack('screen-1'));

      expect(rtcRenderer().initializeCount, 1);
      expect(createdRenderers, hasLength(1));
    });

    test('attach waits for the initialisation it needs', () async {
      final result = await renderer.attach(screenTrack('screen-0'));

      expect(result, RemoteVideoAttachResult.attached);
      expect(rtcRenderer().initializeCount, 1);
      expect(rtcRenderer().calls, ['initialize', 'srcObject']);
    });

    test('a failed initialisation is reported, not thrown, and retried', () async {
      rtcRenderer().initializeError = StateError('no video element');

      final failed = await renderer.attach(screenTrack('screen-0'));

      expect(failed, RemoteVideoAttachResult.failed);
      expect(renderer.isDisplaying, isFalse);

      rtcRenderer().initializeError = null;
      final retried = await renderer.attach(screenTrack('screen-0'));

      expect(retried, RemoteVideoAttachResult.attached);
      expect(rtcRenderer().initializeCount, 2);
    });
  });

  group('attach', () {
    test('the stream the track was announced in reaches the renderer', () async {
      final track = screenTrack('screen-0');

      final result = await renderer.attach(track);

      expect(result, RemoteVideoAttachResult.attached);
      expect(rtcRenderer().srcObject, same(track.mediaStream));
      expect(renderer.track, same(track));
      expect(renderer.isDisplaying, isTrue);
      // Nothing had to be built: the stream was usable as it was.
      expect(localStreams, isEmpty);
    });

    test('a track without a stream is wrapped in one, alone', () async {
      final track = screenTrack('screen-0', announcedInStream: false);

      await renderer.attach(track);

      final stream = localStreams.single;
      expect(rtcRenderer().srcObject, same(stream));
      expect(stream.tracks, [same(track.mediaStreamTrack)]);
    });

    test('audio never reaches the renderer', () async {
      final video = FakeMediaStreamTrack(kind: 'video', id: 'screen-0');
      final announced = FakeMediaStream('stream-0')
        ..tracks.addAll([video, FakeMediaStreamTrack(kind: 'audio', id: 'a')]);
      final track = FlutterWebRtcRemoteVideoTrack(
        mediaStreamTrack: video,
        mediaStream: announced,
      );

      await renderer.attach(track);

      // A video-only stream is handed over instead, so the web renderer never
      // creates an audio element.
      final bound = rtcRenderer().srcObject! as FakeMediaStream;
      expect(bound, isNot(same(announced)));
      expect(bound.getAudioTracks(), isEmpty);
      expect(bound.getVideoTracks().single.id, 'screen-0');
    });

    test('listeners are told a picture is available', () async {
      var notifications = 0;
      renderer.addListener(() => notifications++);

      await renderer.attach(screenTrack('screen-0'));

      expect(notifications, greaterThan(0));
    });

    test('attaching the same track again changes nothing', () async {
      final track = screenTrack('screen-0');
      await renderer.attach(track);

      final result = await renderer.attach(track);

      expect(result, RemoteVideoAttachResult.attached);
      expect(rtcRenderer().srcObjectAssignments, hasLength(1));
    });
  });

  group('an incompatible handle', () {
    test('is refused without a crash', () async {
      final result = await renderer.attach(
        const FakeRemoteVideoTrack('not-flutter-webrtc'),
      );

      expect(result, RemoteVideoAttachResult.unsupportedTrack);
      expect(renderer.isDisplaying, isFalse);
      expect(renderer.track, isNull);
      expect(rtcRenderer().srcObjectAssignments, isEmpty);
    });

    test('does not leave the previous picture on screen', () async {
      await renderer.attach(screenTrack('screen-0'));

      await renderer.attach(const FakeRemoteVideoTrack('not-flutter-webrtc'));

      expect(renderer.isDisplaying, isFalse);
      expect(rtcRenderer().srcObject, isNull);
    });
  });

  group('detach', () {
    test('the renderer stops showing the stream', () async {
      await renderer.attach(screenTrack('screen-0'));
      var notifications = 0;
      renderer.addListener(() => notifications++);

      await renderer.detach();

      expect(rtcRenderer().srcObject, isNull);
      expect(renderer.track, isNull);
      expect(renderer.isDisplaying, isFalse);
      expect(renderer.aspectRatio, isNull);
      expect(notifications, 1);
      // Detached is not disposed: the same renderer takes the next track.
      expect(rtcRenderer().disposeCount, 0);
    });

    test('the renderer is reused by the next track', () async {
      await renderer.attach(screenTrack('screen-0'));
      await renderer.detach();

      final next = screenTrack('screen-1');
      await renderer.attach(next);

      expect(rtcRenderer().srcObject, same(next.mediaStream));
      expect(createdRenderers, hasLength(1));
      expect(rtcRenderer().initializeCount, 1);
    });

    test('with nothing attached it is a no-op', () async {
      await renderer.detach();

      expect(rtcRenderer().srcObjectAssignments, isEmpty);
    });
  });

  group('dispose', () {
    test('releases the renderer once', () async {
      await renderer.attach(screenTrack('screen-0'));

      await renderer.dispose();
      await renderer.dispose();

      expect(rtcRenderer().disposeCount, 1);
      expect(rtcRenderer().srcObject, isNull);
      expect(renderer.track, isNull);
      expect(renderer.isDisplaying, isFalse);
      expect(rtcRenderer().listenerCount, 0);
    });

    test('nothing can be attached afterwards', () async {
      await renderer.dispose();

      final result = await renderer.attach(screenTrack('screen-0'));

      expect(result, RemoteVideoAttachResult.disposed);
      expect(rtcRenderer().srcObjectAssignments, isEmpty);
    });

    test('an initialisation in flight is waited for, then released', () async {
      final gate = Completer<void>();
      rtcRenderer().initializeGate = gate.future;
      final pending = renderer.attach(screenTrack('screen-0'));

      final disposing = renderer.dispose();
      gate.complete();
      await disposing;

      expect(await pending, RemoteVideoAttachResult.disposed);
      expect(rtcRenderer().disposeCount, 1);
      // The track never got bound to a renderer that is going away.
      expect(rtcRenderer().srcObject, isNull);
    });

    test('a renderer that was never initialised is still released', () async {
      await renderer.dispose();

      expect(rtcRenderer().disposeCount, 1);
      expect(rtcRenderer().initializeCount, 0);
    });

    test('a teardown the browser complains about is survived', () async {
      rtcRenderer().disposeError = StateError('already gone');

      await renderer.dispose();

      expect(rtcRenderer().disposeCount, 1);
    });
  });

  group('replacing the track', () {
    test('B replaces A on the same renderer', () async {
      final a = screenTrack('screen-a');
      final b = screenTrack('screen-b');

      await renderer.attach(a);
      await renderer.attach(b);

      expect(rtcRenderer().srcObject, same(b.mediaStream));
      expect(renderer.track, same(b));
      // Straight from A to B: one renderer, no second picture, no blank
      // frame in between.
      expect(createdRenderers, hasLength(1));
      expect(rtcRenderer().srcObjectAssignments, [
        same(a.mediaStream),
        same(b.mediaStream),
      ]);
    });

    test('the newest request wins when two overlap', () async {
      final gate = Completer<void>();
      rtcRenderer().initializeGate = gate.future;
      final a = screenTrack('screen-a');
      final b = screenTrack('screen-b');

      final first = renderer.attach(a);
      final second = renderer.attach(b);
      gate.complete();

      expect(await first, RemoteVideoAttachResult.superseded);
      expect(await second, RemoteVideoAttachResult.attached);
      expect(rtcRenderer().srcObjectAssignments, [same(b.mediaStream)]);
      expect(renderer.track, same(b));
    });

    test('a detach overtakes an attach still preparing', () async {
      final gate = Completer<void>();
      rtcRenderer().initializeGate = gate.future;

      final pending = renderer.attach(screenTrack('screen-a'));
      await renderer.detach();
      gate.complete();

      expect(await pending, RemoteVideoAttachResult.superseded);
      expect(renderer.isDisplaying, isFalse);
      expect(rtcRenderer().srcObjectAssignments, isEmpty);
    });
  });

  group('aspect ratio', () {
    test('it is unknown until the video reports its size', () async {
      await renderer.attach(screenTrack('screen-0'));

      expect(renderer.aspectRatio, isNull);
    });

    test('it follows the stream, landscape or portrait', () async {
      await renderer.attach(screenTrack('screen-0'));
      var notifications = 0;
      renderer.addListener(() => notifications++);

      rtcRenderer().reportVideoSize(1280, 800);
      expect(renderer.aspectRatio, 1280 / 800);

      // The tablet rotated: the capture changes shape, nothing is hardcoded.
      rtcRenderer().reportVideoSize(800, 1280);
      expect(renderer.aspectRatio, 800 / 1280);
      expect(notifications, 2);
    });

    test('nothing is reported while nothing is shown', () async {
      rtcRenderer().reportVideoSize(1280, 800);

      expect(renderer.aspectRatio, isNull);
    });
  });

  group('view', () {
    testWidgets('an RTCVideoView, contained and not mirrored', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(
        Builder(
          builder: (built) {
            context = built;
            return const SizedBox();
          },
        ),
      );

      final view = renderer.buildView(context);

      expect(view, isA<rtc.RTCVideoView>());
      final videoView = view as rtc.RTCVideoView;
      expect(videoView.mirror, isFalse);
      expect(
        videoView.objectFit,
        rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      );
    });

    test('building views creates no renderer', () {
      // The renderer is the adapter's, created with it: rebuilds only ask for
      // a new view of the same one.
      expect(createdRenderers, hasLength(1));
      expect(
        FlutterWebRtcRemoteVideoRenderer.objectFit,
        rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      );
      expect(FlutterWebRtcRemoteVideoRenderer.mirror, isFalse);
    });
  });
}

/// A scripted `RTCVideoRenderer`. It records what the adapter asked for and
/// lets the test report a video size, which is what the browser does once the
/// first frames are decoded.
class FakeRtcVideoRenderer extends ValueNotifier<rtc.RTCVideoValue>
    implements rtc.RTCVideoRenderer {
  FakeRtcVideoRenderer() : super(rtc.RTCVideoValue.empty);

  final List<String> calls = [];
  final List<rtc.MediaStream?> srcObjectAssignments = [];

  int initializeCount = 0;
  int disposeCount = 0;
  Object? initializeError;
  Object? disposeError;

  /// Keeps `initialize` in flight so the test can interleave something.
  Future<void>? initializeGate;

  rtc.MediaStream? _srcObject;

  /// Listeners currently registered — the adapter's own, while it lives.
  int listenerCount = 0;

  @override
  void addListener(VoidCallback listener) {
    listenerCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listenerCount--;
    super.removeListener(listener);
  }

  @override
  Future<void> initialize() async {
    initializeCount++;
    calls.add('initialize');
    final gate = initializeGate;
    if (gate != null) await gate;
    final error = initializeError;
    if (error != null) throw error;
  }

  @override
  rtc.MediaStream? get srcObject => _srcObject;

  @override
  set srcObject(rtc.MediaStream? stream) {
    // A null that unbinds nothing is not worth recording.
    if (stream == null && _srcObject == null) return;
    calls.add('srcObject');
    _srcObject = stream;
    if (stream != null) srcObjectAssignments.add(stream);
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    super.dispose();
    final error = disposeError;
    if (error != null) throw error;
  }

  void reportVideoSize(double width, double height) => value =
      rtc.RTCVideoValue(width: width, height: height, renderVideo: true);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not used by the adapter',
  );
}

/// A remote track. Only `kind` and `id` are read: no media is simulated.
class FakeMediaStreamTrack implements rtc.MediaStreamTrack {
  FakeMediaStreamTrack({required this.kind, required this.id});

  @override
  final String kind;

  @override
  final String id;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not used by the adapter',
  );
}

class FakeMediaStream implements rtc.MediaStream {
  FakeMediaStream(this.id);

  @override
  final String id;

  final List<rtc.MediaStreamTrack> tracks = [];

  @override
  Future<void> addTrack(
    rtc.MediaStreamTrack track, {
    bool addToNative = true,
  }) async => tracks.add(track);

  @override
  List<rtc.MediaStreamTrack> getTracks() => List.of(tracks);

  @override
  List<rtc.MediaStreamTrack> getAudioTracks() =>
      tracks.where((track) => track.kind == 'audio').toList();

  @override
  List<rtc.MediaStreamTrack> getVideoTracks() =>
      tracks.where((track) => track.kind == 'video').toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not used by the adapter',
  );
}
