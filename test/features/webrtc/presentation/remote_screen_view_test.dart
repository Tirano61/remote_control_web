import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
import 'package:remote_control_web/features/remote_control/presentation/widgets/remote_tap_layer.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/remote_video_track.dart';
import 'package:remote_control_web/features/webrtc/presentation/widgets/remote_screen_view.dart';

import '../../../support/webrtc_test_doubles.dart';

/// The remote screen surface, with a fake renderer: no frame is decoded, what
/// is checked is who owns the renderer and how the picture is laid out.
void main() {
  late FakeRemoteVideoRendererFactory renderers;

  setUp(() => renderers = FakeRemoteVideoRendererFactory());

  Future<void> pumpView(
    WidgetTester tester, {
    RemoteVideoTrack? track,
    double width = 1000,
    double maxHeight = 500,
    bool mounted = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: mounted
                  ? RemoteScreenView(
                      track: track,
                      rendererFactory: renderers.create,
                      maxHeight: maxHeight,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Size surfaceSize(WidgetTester tester) =>
      tester.getSize(find.byKey(const Key('remote_screen_surface')));

  group('without a track', () {
    testWidgets('a placeholder is shown, not an error', (tester) async {
      await pumpView(tester);

      expect(find.text(kWaitingForRemoteScreenNotice), findsOneWidget);
      expect(find.byKey(const Key('remote_screen_video')), findsNothing);
    });

    testWidgets('the renderer is ready, with nothing attached', (tester) async {
      await pumpView(tester);

      expect(renderers.created, hasLength(1));
      expect(renderers.last.initializeCount, 1);
      expect(renderers.last.attachedTracks, isEmpty);
    });
  });

  group('with a track', () {
    testWidgets('it is attached and its view shown', (tester) async {
      const track = FakeRemoteVideoTrack('screen-0');

      await pumpView(tester, track: track);

      expect(renderers.last.attachedTracks, [same(track)]);
      expect(find.byKey(const Key('remote_screen_video')), findsOneWidget);
      expect(find.byKey(const Key('fake_remote_video_screen-0')), findsOneWidget);
    });

    testWidgets('the placeholder stays until the picture has a size', (
      tester,
    ) async {
      await pumpView(tester, track: const FakeRemoteVideoTrack('screen-0'));
      expect(find.text(kWaitingForRemoteScreenNotice), findsOneWidget);

      // What the browser reports once it has decoded the first frames. No
      // timer decides it.
      renderers.last.reportVideoAspectRatio(1280 / 800);
      await tester.pump();

      expect(find.text(kWaitingForRemoteScreenNotice), findsNothing);
      expect(find.byKey(const Key('fake_remote_video_screen-0')), findsOneWidget);
    });
  });

  group('lifecycle', () {
    testWidgets('rebuilds never create another renderer', (tester) async {
      const track = FakeRemoteVideoTrack('screen-0');
      await pumpView(tester, track: track);

      await pumpView(tester, track: track, maxHeight: 400);
      await pumpView(tester, track: track, width: 700);

      expect(renderers.created, hasLength(1));
      expect(renderers.last.initializeCount, 1);
      expect(renderers.last.attachedTracks, hasLength(1));
    });

    testWidgets('a new track replaces the old one on the same renderer', (
      tester,
    ) async {
      const a = FakeRemoteVideoTrack('screen-a');
      const b = FakeRemoteVideoTrack('screen-b');
      await pumpView(tester, track: a);

      await pumpView(tester, track: b);

      expect(renderers.created, hasLength(1));
      expect(renderers.last.attachedTracks, [same(a), same(b)]);
      expect(find.byKey(const Key('fake_remote_video_screen-b')), findsOneWidget);
      expect(find.byKey(const Key('fake_remote_video_screen-a')), findsNothing);
    });

    testWidgets('losing the track detaches it', (tester) async {
      await pumpView(tester, track: const FakeRemoteVideoTrack('screen-0'));

      await pumpView(tester);

      expect(renderers.last.detachCount, 1);
      expect(renderers.last.isDisposed, isFalse);
      expect(find.byKey(const Key('remote_screen_video')), findsNothing);
      expect(find.text(kWaitingForRemoteScreenNotice), findsOneWidget);
    });

    testWidgets('the renderer is disposed with the widget, once', (
      tester,
    ) async {
      await pumpView(tester, track: const FakeRemoteVideoTrack('screen-0'));

      await pumpView(tester, mounted: false);

      expect(renderers.created, hasLength(1));
      expect(renderers.last.disposeCount, 1);
      expect(renderers.last.isDisplaying, isFalse);
    });
  });

  group('aspect ratio', () {
    Future<Size> pictureFor(
      WidgetTester tester,
      double aspectRatio, {
      double width = 1000,
      double maxHeight = 500,
    }) async {
      await pumpView(
        tester,
        track: const FakeRemoteVideoTrack('screen-0'),
        width: width,
        maxHeight: maxHeight,
      );
      renderers.last.reportVideoAspectRatio(aspectRatio);
      await tester.pump();
      return surfaceSize(tester);
    }

    testWidgets('landscape keeps its proportions', (tester) async {
      final size = await pictureFor(tester, 1280 / 800);

      expect(size.height, 500);
      expect(size.width, 800);
    });

    testWidgets('portrait keeps its proportions', (tester) async {
      final size = await pictureFor(tester, 800 / 1280);

      expect(size.height, 500);
      expect(size.width, closeTo(312.5, 0.001));
    });

    testWidgets('a narrow window bounds it by width instead', (tester) async {
      final size = await pictureFor(tester, 1280 / 800, width: 320);

      expect(size.width, 320);
      expect(size.height, 200);
    });

    testWidgets('a new resolution reshapes it without a new renderer', (
      tester,
    ) async {
      await pictureFor(tester, 1280 / 800);

      renderers.last.reportVideoAspectRatio(800 / 1280);
      await tester.pump();

      expect(surfaceSize(tester).width, closeTo(312.5, 0.001));
      expect(renderers.created, hasLength(1));
    });
  });

  group('remote tap', () {
    late List<NormalizedRemotePoint> taps;

    setUp(() => taps = []);

    final surface = find.byKey(const Key('remote_screen_surface'));

    Future<void> pumpInteractive(
      WidgetTester tester, {
      RemoteVideoTrack? track = const FakeRemoteVideoTrack('screen-0'),
      double? aspectRatio = 1280 / 800,
      bool isEnabled = true,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 1000,
                child: RemoteScreenView(
                  track: track,
                  rendererFactory: renderers.create,
                  maxHeight: 500,
                  onRemoteTap: isEnabled ? taps.add : null,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      if (aspectRatio != null) {
        renderers.last.reportVideoAspectRatio(aspectRatio);
        await tester.pump();
      }
    }

    /// Clicks at a fraction of the surface.
    Future<void> clickAt(WidgetTester tester, double fx, double fy) async {
      final box = tester.getRect(surface);
      await tester.tapAt(
        Offset(box.left + box.width * fx, box.top + box.height * fy),
      );
      await tester.pump();
    }

    testWidgets('a click on the picture becomes a position', (tester) async {
      await pumpInteractive(tester);

      await clickAt(tester, 0.5, 0.25);

      expect(taps, hasLength(1));
      expect(taps.single.x, closeTo(0.5, 1e-9));
      expect(taps.single.y, closeTo(0.25, 1e-9));
    });

    testWidgets('x grows right and y grows down, not mirrored', (tester) async {
      await pumpInteractive(tester);

      await clickAt(tester, 0.1, 0.9);

      expect(taps.single.x, closeTo(0.1, 1e-9));
      expect(taps.single.y, closeTo(0.9, 1e-9));
    });

    testWidgets('control disabled: no command', (tester) async {
      await pumpInteractive(tester, isEnabled: false);

      await clickAt(tester, 0.5, 0.5);

      expect(find.byKey(const Key('remote_screen_tap_layer')), findsNothing);
      expect(taps, isEmpty);
    });

    testWidgets('no track: no command', (tester) async {
      await pumpInteractive(tester, track: null, aspectRatio: null);

      await clickAt(tester, 0.5, 0.5);

      expect(find.byKey(const Key('remote_screen_tap_layer')), findsNothing);
      expect(taps, isEmpty);
    });

    testWidgets('a track with no frame yet: no command', (tester) async {
      await pumpInteractive(tester, aspectRatio: null);
      expect(find.text(kWaitingForRemoteScreenNotice), findsOneWidget);

      await clickAt(tester, 0.5, 0.5);

      expect(taps, isEmpty);
    });

    testWidgets('outside the surface: no command', (tester) async {
      // The surface takes the picture's own shape, so at this size the bands
      // are the empty space beside it.
      await pumpInteractive(tester, aspectRatio: 800 / 1280);
      final box = tester.getRect(surface);
      expect(box.left, greaterThan(0));

      await tester.tapAt(Offset(box.left - 10, box.center.dy));
      await tester.tapAt(Offset(box.right + 10, box.center.dy));
      await tester.pump();

      expect(taps, isEmpty);
    });

    testWidgets('a band inside the surface: no command', (tester) async {
      await pumpInteractive(tester);

      // The tablet turned and the surface has not been rebuilt yet: portrait
      // video in a landscape box, with bands at the sides.
      renderers.last.changeVideoAspectRatioWithoutNotifying(800 / 1280);

      await clickAt(tester, 0.05, 0.5);
      await clickAt(tester, 0.95, 0.5);

      expect(taps, isEmpty);
    });

    testWidgets('a drag is not a tap', (tester) async {
      await pumpInteractive(tester);

      await tester.dragFrom(tester.getCenter(surface), const Offset(120, 0));
      await tester.pump();

      expect(taps, isEmpty);
    });

    testWidgets('nothing happens until the pointer goes up', (tester) async {
      await pumpInteractive(tester);

      final gesture = await tester.startGesture(tester.getCenter(surface));
      await tester.pump();
      expect(taps, isEmpty);

      await gesture.up();
      await tester.pump();
      expect(taps, hasLength(1));
    });

    testWidgets('after a rotation the new geometry is used', (tester) async {
      await pumpInteractive(tester);

      await clickAt(tester, 0.5, 0.5);
      expect(taps.last, const NormalizedRemotePoint(0.5, 0.5));

      renderers.last.reportVideoAspectRatio(800 / 1280);
      await tester.pump();
      expect(surfaceSize(tester).width, closeTo(312.5, 0.001));

      await clickAt(tester, 0.25, 0.75);

      expect(taps, hasLength(2));
      expect(taps.last.x, closeTo(0.25, 1e-9));
      expect(taps.last.y, closeTo(0.75, 1e-9));

      renderers.last.reportVideoAspectRatio(1280 / 800);
      await tester.pump();

      await clickAt(tester, 0.75, 0.25);

      expect(taps, hasLength(3));
      expect(taps.last.x, closeTo(0.75, 1e-9));
      expect(taps.last.y, closeTo(0.25, 1e-9));
      expect(renderers.created, hasLength(1));
    });

    testWidgets('losing the track stops the clicks', (tester) async {
      await pumpInteractive(tester);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 1000,
                child: RemoteScreenView(
                  track: null,
                  rendererFactory: renderers.create,
                  maxHeight: 500,
                  onRemoteTap: taps.add,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await clickAt(tester, 0.5, 0.5);

      expect(find.byKey(const Key('remote_screen_tap_layer')), findsNothing);
      expect(taps, isEmpty);
    });

    testWidgets('the status knows whether there is a picture', (tester) async {
      final seen = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RemoteScreenView(
              track: const FakeRemoteVideoTrack('screen-0'),
              rendererFactory: renderers.create,
              maxHeight: 500,
              controlStatusBuilder: (context, hasPicture) {
                seen.add(hasPicture);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(seen.last, isFalse);

      renderers.last.reportVideoAspectRatio(1280 / 800);
      await tester.pump();

      expect(seen.last, isTrue);
    });
  });

  group('RemoteTapLayer', () {
    late List<NormalizedRemotePoint> taps;
    late double? aspectRatio;

    setUp(() {
      taps = [];
      aspectRatio = 800 / 1280;
    });

    /// A box whose shape does not follow the video, so that the bands of
    /// `contain` are inside it.
    Future<void> pumpLayer(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 1200,
              height: 800,
              child: RemoteTapLayer(
                videoAspectRatio: () => aspectRatio,
                onTap: taps.add,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('both bands of a portrait video are ignored', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpLayer(tester);

      await tester.tapAt(const Offset(200, 400));
      await tester.tapAt(const Offset(349, 400));
      await tester.tapAt(const Offset(851, 400));
      await tester.tapAt(const Offset(1000, 400));
      await tester.pump();

      expect(taps, isEmpty);
    });

    testWidgets('the picture between them is not', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpLayer(tester);

      await tester.tapAt(const Offset(600, 400));
      await tester.pump();

      expect(taps.single.x, closeTo(0.5, 1e-9));
      expect(taps.single.y, closeTo(0.5, 1e-9));
    });

    testWidgets('the ratio is read at the click, never kept', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpLayer(tester);

      await tester.tapAt(const Offset(100, 400));
      await tester.pump();
      expect(taps, isEmpty);

      // Landscape now fills the box: no widget was rebuilt for it.
      aspectRatio = 1200 / 800;
      await tester.tapAt(const Offset(100, 400));
      await tester.pump();

      expect(taps.single.x, closeTo(100 / 1200, 1e-9));
      expect(taps.single.y, closeTo(0.5, 1e-9));
    });

    testWidgets('no ratio is no tap', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      aspectRatio = null;
      await pumpLayer(tester);

      await tester.tapAt(const Offset(600, 400));
      await tester.pump();

      expect(taps, isEmpty);
    });

    testWidgets('the click cursor only shows over the picture', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpLayer(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      MouseCursor cursor() =>
          RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1)!;

      await mouse.addPointer(location: const Offset(100, 400));
      await tester.pump();
      await mouse.moveTo(const Offset(101, 400));
      await tester.pump();
      expect(cursor(), SystemMouseCursors.basic);

      await mouse.moveTo(const Offset(600, 400));
      await tester.pump();
      expect(cursor(), SystemMouseCursors.click);

      await mouse.moveTo(const Offset(900, 400));
      await tester.pump();
      expect(cursor(), SystemMouseCursors.basic);
    });
  });
}
