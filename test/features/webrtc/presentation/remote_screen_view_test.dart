import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
import 'package:remote_control_web/features/remote_control/presentation/widgets/remote_control_gesture_layer.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/remote_video_track.dart';
import 'package:remote_control_web/features/webrtc/presentation/widgets/remote_screen_view.dart';

import '../../../support/webrtc_test_doubles.dart';

/// A swipe as the surface reports it.
typedef _Swipe = ({
  NormalizedRemotePoint start,
  NormalizedRemotePoint end,
  int durationMs,
});

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
    late List<_Swipe> swipes;

    void recordSwipe({
      required NormalizedRemotePoint start,
      required NormalizedRemotePoint end,
      required int durationMs,
    }) => swipes.add((start: start, end: end, durationMs: durationMs));

    setUp(() {
      taps = [];
      swipes = [];
    });

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
                  onRemoteSwipe: isEnabled ? recordSwipe : null,
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

      expect(find.byKey(const Key('remote_screen_gesture_layer')), findsNothing);
      expect(taps, isEmpty);
    });

    testWidgets('no track: no command', (tester) async {
      await pumpInteractive(tester, track: null, aspectRatio: null);

      await clickAt(tester, 0.5, 0.5);

      expect(find.byKey(const Key('remote_screen_gesture_layer')), findsNothing);
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

    testWidgets('a drag is a swipe and not a tap', (tester) async {
      await pumpInteractive(tester);

      await tester.dragFrom(tester.getCenter(surface), const Offset(120, 0));
      await tester.pump();

      expect(taps, isEmpty);
      expect(swipes, hasLength(1));
      expect(swipes.single.start, const NormalizedRemotePoint(0.5, 0.5));
      expect(swipes.single.end.x, closeTo(0.5 + 120 / 800, 1e-9));
      expect(swipes.single.end.y, closeTo(0.5, 1e-9));
    });

    testWidgets('control disabled: a drag sends nothing', (tester) async {
      await pumpInteractive(tester, isEnabled: false);

      await tester.dragFrom(tester.getCenter(surface), const Offset(120, 0));
      await tester.pump();

      expect(swipes, isEmpty);
    });

    testWidgets('a track with no frame yet: a drag sends nothing', (
      tester,
    ) async {
      await pumpInteractive(tester, aspectRatio: null);

      await tester.dragFrom(tester.getCenter(surface), const Offset(120, 0));
      await tester.pump();

      expect(swipes, isEmpty);
    });

    testWidgets('control going away during a drag drops it', (tester) async {
      await pumpInteractive(tester);
      final gesture = await tester.startGesture(tester.getCenter(surface));
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();

      await pumpInteractive(tester, isEnabled: false);
      await gesture.moveBy(const Offset(50, 0));
      await gesture.up();
      await tester.pump();

      expect(taps, isEmpty);
      expect(swipes, isEmpty);
    });

    testWidgets('control coming back does not revive a drag', (tester) async {
      await pumpInteractive(tester);
      final gesture = await tester.startGesture(tester.getCenter(surface));
      await gesture.moveBy(const Offset(50, 0));
      await pumpInteractive(tester, isEnabled: false);

      await pumpInteractive(tester);
      await gesture.moveBy(const Offset(50, 0));
      await gesture.up();
      await tester.pump();

      expect(swipes, isEmpty);
    });

    group('a rotation during the press', () {
      testWidgets('portrait to landscape: no swipe, and the next one is right', (
        tester,
      ) async {
        await pumpInteractive(tester, aspectRatio: 800 / 1280);

        final gesture = await tester.startGesture(tester.getCenter(surface));
        await gesture.moveBy(const Offset(0, -80));
        renderers.last.reportVideoAspectRatio(1280 / 800);
        await tester.pump();
        await gesture.moveBy(const Offset(0, -20));
        await gesture.up();
        await tester.pump();

        expect(taps, isEmpty);
        expect(swipes, isEmpty);

        final box = tester.getRect(surface);
        expect(box.width, 800);
        final next = await tester.startGesture(
          Offset(box.left + box.width * 0.25, box.top + box.height * 0.75),
        );
        await next.moveTo(
          Offset(box.left + box.width * 0.75, box.top + box.height * 0.25),
        );
        await next.up();
        await tester.pump();

        expect(swipes, hasLength(1));
        expect(swipes.single.start.x, closeTo(0.25, 1e-9));
        expect(swipes.single.start.y, closeTo(0.75, 1e-9));
        expect(swipes.single.end.x, closeTo(0.75, 1e-9));
        expect(swipes.single.end.y, closeTo(0.25, 1e-9));
      });

      testWidgets('a press that had not moved does not become a tap', (
        tester,
      ) async {
        await pumpInteractive(tester);

        final gesture = await tester.startGesture(tester.getCenter(surface));
        renderers.last.reportVideoAspectRatio(800 / 1280);
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(taps, isEmpty);
        expect(swipes, isEmpty);
      });

      testWidgets('there and back with the pointer still: dropped all the same', (
        tester,
      ) async {
        await pumpInteractive(tester);

        final gesture = await tester.startGesture(tester.getCenter(surface));
        await gesture.moveBy(const Offset(50, 0));
        renderers.last.reportVideoAspectRatio(800 / 1280);
        await tester.pump();
        renderers.last.reportVideoAspectRatio(1280 / 800);
        await tester.pump();
        await gesture.moveBy(const Offset(50, 0));
        await gesture.up();
        await tester.pump();

        expect(swipes, isEmpty);
      });
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
                  onRemoteSwipe: recordSwipe,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await clickAt(tester, 0.5, 0.5);

      expect(find.byKey(const Key('remote_screen_gesture_layer')), findsNothing);
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

  group('RemoteControlGestureLayer', () {
    late List<NormalizedRemotePoint> taps;
    late List<_Swipe> swipes;
    late double? aspectRatio;

    void recordSwipe({
      required NormalizedRemotePoint start,
      required NormalizedRemotePoint end,
      required int durationMs,
    }) => swipes.add((start: start, end: end, durationMs: durationMs));

    setUp(() {
      taps = [];
      swipes = [];
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
              child: RemoteControlGestureLayer(
                videoAspectRatio: () => aspectRatio,
                onTap: taps.add,
                onSwipe: recordSwipe,
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

    /// The box is 1200 x 800 and the picture 500 x 800, from x = 350 to x = 850,
    /// so a fraction of the picture is easy to tell from these positions.
    Future<void> pumpBox(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpLayer(tester);
    }

    /// A press at [from], moved through [through] in order, released at the last.
    Future<void> stroke(
      WidgetTester tester,
      Offset from,
      List<Offset> through,
    ) async {
      final gesture = await tester.startGesture(from);
      for (final position in through) {
        await gesture.moveTo(position);
      }
      await gesture.up();
      await tester.pump();
    }

    void expectPoint(NormalizedRemotePoint point, double x, double y) {
      expect(point.x, closeTo(x, 1e-9));
      expect(point.y, closeTo(y, 1e-9));
    }

    group('tap or swipe', () {
      const centre = Offset(600, 400);

      testWidgets('no movement: a tap', (tester) async {
        await pumpBox(tester);

        await stroke(tester, centre, const []);

        expect(taps, hasLength(1));
        expect(swipes, isEmpty);
      });

      testWidgets('less than the threshold: a tap, where it was released', (
        tester,
      ) async {
        await pumpBox(tester);

        await stroke(tester, centre, [centre + const Offset(5, 0)]);

        expect(swipes, isEmpty);
        expectPoint(taps.single, 255 / 500, 0.5);
      });

      testWidgets('just under the threshold: still a tap', (tester) async {
        await pumpBox(tester);

        await stroke(tester, centre, [centre + const Offset(5.99, 0)]);

        expect(taps, hasLength(1));
        expect(swipes, isEmpty);
      });

      testWidgets('exactly the threshold: a swipe', (tester) async {
        await pumpBox(tester);
        expect(RemoteControlGestureLayer.dragThreshold, 6);

        await stroke(tester, centre, [centre + const Offset(6, 0)]);

        expect(taps, isEmpty);
        expect(swipes, hasLength(1));
      });

      testWidgets('the distance is measured on both axes', (tester) async {
        await pumpBox(tester);

        // 3-4-5: under the threshold, whatever each axis says.
        await stroke(tester, centre, [centre + const Offset(3, 4)]);
        expect(taps, hasLength(1));
        expect(swipes, isEmpty);

        // 6-8-10: over it.
        await stroke(tester, centre, [centre + const Offset(6, 8)]);
        expect(taps, hasLength(1));
        expect(swipes, hasLength(1));
      });

      testWidgets('nothing is sent until the pointer goes up, and only once', (
        tester,
      ) async {
        await pumpBox(tester);

        final gesture = await tester.startGesture(centre);
        expect(taps, isEmpty);
        for (var i = 1; i <= 10; i++) {
          await gesture.moveTo(centre + Offset(0, i * 10));
          expect(swipes, isEmpty);
          expect(taps, isEmpty);
        }

        await gesture.up();
        await tester.pump();

        expect(swipes, hasLength(1));
        expect(taps, isEmpty);
      });

      testWidgets('dragged away and brought back: neither', (tester) async {
        await pumpBox(tester);

        await stroke(tester, centre, [
          centre + const Offset(0, 100),
          centre + const Offset(2, 0),
        ]);

        expect(taps, isEmpty);
        expect(swipes, isEmpty);
      });

      testWidgets('dragged away and back to the very start: neither', (
        tester,
      ) async {
        await pumpBox(tester);

        await stroke(tester, centre, [centre + const Offset(0, 100), centre]);

        expect(taps, isEmpty);
        expect(swipes, isEmpty);
      });

      testWidgets('a detour: only the two ends are sent', (tester) async {
        await pumpBox(tester);

        await stroke(tester, centre, [
          centre + const Offset(100, 0),
          centre + const Offset(0, 200),
        ]);

        expectPoint(swipes.single.start, 0.5, 0.5);
        expectPoint(swipes.single.end, 0.5, 0.75);
      });
    });

    group('where it lands on the tablet', () {
      testWidgets('vertical, from the bottom up', (tester) async {
        await pumpBox(tester);

        await stroke(tester, const Offset(600, 640), const [Offset(600, 160)]);

        expectPoint(swipes.single.start, 0.5, 0.8);
        expectPoint(swipes.single.end, 0.5, 0.2);
      });

      testWidgets('horizontal, from left to right', (tester) async {
        await pumpBox(tester);

        await stroke(tester, const Offset(400, 400), const [Offset(800, 400)]);

        expectPoint(swipes.single.start, 0.1, 0.5);
        expectPoint(swipes.single.end, 0.9, 0.5);
      });

      testWidgets('diagonal', (tester) async {
        await pumpBox(tester);

        await stroke(tester, const Offset(400, 160), const [Offset(800, 640)]);

        expectPoint(swipes.single.start, 0.1, 0.2);
        expectPoint(swipes.single.end, 0.9, 0.8);
      });

      testWidgets('from edge to edge of the picture', (tester) async {
        await pumpBox(tester);

        await stroke(tester, const Offset(350, 0), const [Offset(850, 799)]);

        expectPoint(swipes.single.start, 0, 0);
        expectPoint(swipes.single.end, 1, 799 / 800);
      });
    });

    group('the bands', () {
      testWidgets('pressed on a band: nothing, even entering the picture', (
        tester,
      ) async {
        await pumpBox(tester);

        await stroke(tester, const Offset(200, 400), const [
          Offset(600, 400),
          Offset(700, 400),
        ]);

        expect(taps, isEmpty);
        expect(swipes, isEmpty);
      });

      testWidgets('released on a band: nothing, and no clamp to the edge', (
        tester,
      ) async {
        await pumpBox(tester);

        await stroke(tester, const Offset(600, 400), const [Offset(200, 400)]);

        expect(taps, isEmpty);
        expect(swipes, isEmpty);
      });

      testWidgets('leaving the picture and coming back: dropped for good', (
        tester,
      ) async {
        await pumpBox(tester);

        await stroke(tester, const Offset(600, 400), const [
          Offset(300, 400),
          Offset(700, 400),
        ]);

        expect(taps, isEmpty);
        expect(swipes, isEmpty);
      });

      testWidgets('leaving by less than the threshold is leaving too', (
        tester,
      ) async {
        await pumpBox(tester);

        await stroke(tester, const Offset(351, 400), const [Offset(348, 400)]);

        expect(taps, isEmpty);
        expect(swipes, isEmpty);
      });

      testWidgets('leaving the surface altogether', (tester) async {
        await pumpBox(tester);

        await stroke(tester, const Offset(600, 400), const [Offset(1350, 400)]);

        expect(taps, isEmpty);
        expect(swipes, isEmpty);
      });

      testWidgets('a dropped press does not spoil the next one', (tester) async {
        await pumpBox(tester);
        await stroke(tester, const Offset(600, 400), const [Offset(200, 400)]);

        await stroke(tester, const Offset(600, 400), const [Offset(600, 500)]);

        expect(swipes, hasLength(1));
      });
    });

    group('the duration', () {
      /// A press whose pointer events say it took [elapsedMs].
      Future<void> strokeTaking(WidgetTester tester, int elapsedMs) async {
        const pressedAt = Duration(seconds: 100);
        final releasedAt = pressedAt + Duration(milliseconds: elapsedMs);
        final gesture = await tester.createGesture();
        await gesture.down(const Offset(600, 200), timeStamp: pressedAt);
        await gesture.moveTo(const Offset(600, 600), timeStamp: pressedAt);
        await gesture.up(timeStamp: releasedAt);
        await tester.pump();
      }

      const expectations = {20: 50, 50: 50, 180: 180, 350: 350, 2000: 2000};

      expectations.forEach((elapsedMs, durationMs) {
        testWidgets('$elapsedMs ms -> $durationMs', (tester) async {
          await pumpBox(tester);

          await strokeTaking(tester, elapsedMs);

          expect(swipes.single.durationMs, durationMs);
        });
      });

      for (final elapsedMs in const [3000, 3500]) {
        testWidgets('$elapsedMs ms -> 2000', (tester) async {
          await pumpBox(tester);

          await strokeTaking(tester, elapsedMs);

          expect(swipes.single.durationMs, 2000);
        });
      }
    });

    group('a change of geometry during the press', () {
      testWidgets('the ratio read at the release: no gesture', (tester) async {
        await pumpBox(tester);

        final gesture = await tester.startGesture(const Offset(600, 200));
        await gesture.moveTo(const Offset(600, 600));
        aspectRatio = 1200 / 800;
        await gesture.up();
        await tester.pump();

        expect(taps, isEmpty);
        expect(swipes, isEmpty);
      });

      testWidgets('the ratio read at a move: no gesture, even if it returns', (
        tester,
      ) async {
        await pumpBox(tester);

        final gesture = await tester.startGesture(const Offset(600, 200));
        aspectRatio = 1200 / 800;
        await gesture.moveTo(const Offset(600, 400));
        aspectRatio = 800 / 1280;
        await gesture.moveTo(const Offset(600, 600));
        await gesture.up();
        await tester.pump();

        expect(swipes, isEmpty);
      });

      testWidgets('losing the picture: no gesture', (tester) async {
        await pumpBox(tester);

        final gesture = await tester.startGesture(const Offset(600, 200));
        aspectRatio = null;
        await gesture.moveTo(const Offset(600, 600));
        await gesture.up();
        await tester.pump();

        expect(swipes, isEmpty);
      });
    });

    group('other pointers', () {
      testWidgets('another button is not a gesture', (tester) async {
        await pumpBox(tester);

        final gesture = await tester.startGesture(
          const Offset(600, 200),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await gesture.moveTo(const Offset(600, 600));
        await gesture.up();
        await tester.pump();

        expect(taps, isEmpty);
        expect(swipes, isEmpty);
      });

      testWidgets('another button without moving is not a tap', (tester) async {
        await pumpBox(tester);

        final gesture = await tester.startGesture(
          const Offset(600, 200),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await gesture.up();
        await tester.pump();

        expect(taps, isEmpty);
      });

      testWidgets('another button joining the drag drops it', (tester) async {
        await pumpBox(tester);

        const pointer = 7;
        final gesture = await tester.startGesture(
          const Offset(600, 200),
          pointer: pointer,
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveTo(const Offset(600, 300));
        await gesture.updateWithCustomEvent(
          const PointerMoveEvent(
            pointer: pointer,
            kind: PointerDeviceKind.mouse,
            position: Offset(600, 400),
            buttons: kPrimaryButton | kSecondaryButton,
          ),
        );
        await gesture.up();
        await tester.pump();

        expect(taps, isEmpty);
        expect(swipes, isEmpty);
      });

      testWidgets('the primary mouse button is', (tester) async {
        await pumpBox(tester);

        final gesture = await tester.startGesture(
          const Offset(600, 200),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveTo(const Offset(600, 600));
        await gesture.up();
        await tester.pump();

        expect(swipes, hasLength(1));
      });

      testWidgets('a second finger drops the press', (tester) async {
        await pumpBox(tester);

        final first = await tester.startGesture(const Offset(500, 200));
        await first.moveTo(const Offset(500, 300));
        final second = await tester.startGesture(const Offset(700, 200));
        await second.moveTo(const Offset(700, 300));
        await first.moveTo(const Offset(500, 400));
        await first.up();
        await second.up();
        await tester.pump();

        expect(taps, isEmpty);
        expect(swipes, isEmpty);

        await stroke(tester, const Offset(600, 200), const [Offset(600, 300)]);
        expect(swipes, hasLength(1));
      });

      testWidgets('a pointer the system cancelled sends nothing', (
        tester,
      ) async {
        await pumpBox(tester);

        final gesture = await tester.startGesture(const Offset(600, 200));
        await gesture.moveTo(const Offset(600, 600));
        await gesture.cancel();
        await tester.pump();

        expect(taps, isEmpty);
        expect(swipes, isEmpty);

        await stroke(tester, const Offset(600, 200), const [Offset(600, 300)]);
        expect(swipes, hasLength(1));
      });

      testWidgets('the wheel during a press drops it', (tester) async {
        await pumpBox(tester);
        final gesture = await tester.startGesture(
          const Offset(600, 200),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveTo(const Offset(600, 300));

        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(600, 300),
            scrollDelta: Offset(0, 100),
          ),
        );
        await gesture.moveTo(const Offset(600, 600));
        await gesture.up();
        await tester.pump();

        expect(swipes, isEmpty);
      });

      testWidgets('a finger moves the tablet and not the page around it', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        aspectRatio = 1200 / 800;
        final page = ScrollController();
        addTearDown(page.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: SingleChildScrollView(
              controller: page,
              child: Column(
                children: [
                  SizedBox(
                    width: 1200,
                    height: 800,
                    child: RemoteControlGestureLayer(
                      videoAspectRatio: () => aspectRatio,
                      onTap: taps.add,
                      onSwipe: recordSwipe,
                    ),
                  ),
                  const SizedBox(height: 2000),
                ],
              ),
            ),
          ),
        );

        final gesture = await tester.startGesture(const Offset(700, 700));
        await gesture.moveBy(const Offset(0, -100));
        await tester.pump();
        await gesture.moveBy(const Offset(0, -300));
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(page.offset, 0);
        expect(swipes, hasLength(1));
      });
    });
  });
}
