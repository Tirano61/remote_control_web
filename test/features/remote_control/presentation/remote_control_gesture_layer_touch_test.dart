import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
import 'package:remote_control_web/features/remote_control/presentation/widgets/remote_control_gesture_layer.dart';

/// The surface when its receiver follows a held press as a remote touch.
///
/// The box is 1200 x 800. A portrait picture (800 / 1280) is drawn 500 wide from
/// x = 350 to x = 850; a landscape one (1.6) 750 tall from y = 25 to y = 775.
void main() {
  const timeout = RemoteControlGestureLayer.longPressTimeout;
  const centre = Offset(600, 400);

  late List<String> events;
  late List<NormalizedRemotePoint> points;
  late List<NormalizedRemotePoint> taps;
  late List<NormalizedRemotePoint> longPresses;
  late int swipes;
  late double? aspectRatio;

  setUp(() {
    events = [];
    points = [];
    taps = [];
    longPresses = [];
    swipes = 0;
    aspectRatio = 800 / 1280;
  });

  void record(String name, NormalizedRemotePoint? point) {
    events.add(name);
    if (point != null) points.add(point);
  }

  Future<void> pumpLayer(
    WidgetTester tester, {
    double width = 1200,
    bool mounted = true,
  }) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 800,
            child: mounted
                ? RemoteControlGestureLayer(
                    videoAspectRatio: () => aspectRatio,
                    onTap: taps.add,
                    onSwipe:
                        ({
                          required NormalizedRemotePoint start,
                          required NormalizedRemotePoint end,
                          required int durationMs,
                        }) => swipes++,
                    onLongPress: longPresses.add,
                    onTouch: RemoteTouchCallbacks(
                      onHold: (pointer, point) => record('hold', point),
                      onMove: (pointer, point) => record('move', point),
                      onRelease: (pointer, point) => record('release', point),
                      onCancel: (pointer) => record('cancel', null),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  /// A press at [at], held for the long press timeout, still down.
  Future<TestGesture> hold(WidgetTester tester, [Offset at = centre]) async {
    final gesture = await tester.startGesture(at);
    await tester.pump(timeout);
    return gesture;
  }

  void expectPoint(NormalizedRemotePoint point, double x, double y) {
    expect(point.x, closeTo(x, 1e-9));
    expect(point.y, closeTo(y, 1e-9));
  }

  group('recognition, as before', () {
    testWidgets('a short click: a tap, no touch', (tester) async {
      await pumpLayer(tester);
      final gesture = await tester.startGesture(centre);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pump(timeout * 2);

      expect(taps, hasLength(1));
      expect(events, isEmpty);
    });

    testWidgets('6 px before the timeout: a swipe, no touch', (tester) async {
      await pumpLayer(tester);
      final gesture = await tester.startGesture(centre);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 6));
      await tester.pump(timeout * 2);
      await gesture.moveBy(const Offset(0, 100));
      await gesture.up();
      await tester.pump();

      expect(swipes, 1);
      expect(events, isEmpty);
      expect(longPresses, isEmpty);
    });

    testWidgets('held still: the hold where it went down, not a long press', (
      tester,
    ) async {
      await pumpLayer(tester);
      final gesture = await tester.startGesture(centre);
      await tester.pump(const Duration(milliseconds: 200));
      // A tremble under the threshold does not move where it is reported.
      await gesture.moveBy(const Offset(3, 2));
      await tester.pump(timeout);

      expect(events, ['hold']);
      expectPoint(points.single, 0.5, 0.5);
      expect(longPresses, isEmpty);
      await gesture.up();
    });

    testWidgets('before the hold, leaving the picture still drops the press', (
      tester,
    ) async {
      await pumpLayer(tester);
      final gesture = await tester.startGesture(centre);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveTo(const Offset(200, 400));
      await tester.pump(timeout * 2);
      await gesture.up();
      await tester.pump();

      // No swipe to a band, nothing clamped, no hold.
      expect(swipes, 0);
      expect(taps, isEmpty);
      expect(events, isEmpty);
    });
  });

  group('after the hold', () {
    testWidgets('every move goes on, and the release ends it', (tester) async {
      await pumpLayer(tester);
      final gesture = await hold(tester);

      await gesture.moveTo(const Offset(650, 400));
      await gesture.moveTo(const Offset(700, 480));
      await gesture.up();
      await tester.pump(timeout * 2);

      expect(events, ['hold', 'move', 'move', 'release']);
      expectPoint(points[1], 0.6, 0.5);
      expectPoint(points[2], 0.7, 0.6);
      expectPoint(points[3], 0.7, 0.6);
      // Never a tap, a swipe or a long press as well.
      expect(taps, isEmpty);
      expect(swipes, 0);
      expect(longPresses, isEmpty);
    });

    testWidgets('released without moving: a release where it is', (
      tester,
    ) async {
      await pumpLayer(tester);
      final gesture = await hold(tester);
      await tester.pump(const Duration(seconds: 3));
      await gesture.up();
      await tester.pump();

      expect(events, ['hold', 'release']);
      expect(taps, isEmpty);
    });

    group('clamped to the picture, never to the box', () {
      testWidgets('left: x = 0', (tester) async {
        await pumpLayer(tester);
        final gesture = await hold(tester);
        await gesture.moveTo(const Offset(100, 400));
        await gesture.moveTo(const Offset(-50, 400));
        await gesture.up();

        expect(events, ['hold', 'move', 'move', 'release']);
        for (final point in points.skip(1)) {
          expectPoint(point, 0, 0.5);
        }
      });

      testWidgets('right: x = 1', (tester) async {
        await pumpLayer(tester);
        final gesture = await hold(tester);
        await gesture.moveTo(const Offset(1000, 400));
        await gesture.up();

        expectPoint(points[1], 1, 0.5);
        expectPoint(points[2], 1, 0.5);
      });

      testWidgets('above: y = 0, below: y = 1', (tester) async {
        aspectRatio = 1.6;
        await pumpLayer(tester);
        final gesture = await hold(tester);
        await gesture.moveTo(const Offset(600, 10));
        await gesture.moveTo(const Offset(600, 790));
        await gesture.up();

        expectPoint(points[1], 0.5, 0);
        expectPoint(points[2], 0.5, 1);
        expectPoint(points[3], 0.5, 1);
      });

      testWidgets('back on the picture: followed again', (tester) async {
        await pumpLayer(tester);
        final gesture = await hold(tester);
        await gesture.moveTo(const Offset(100, 400));
        await gesture.moveTo(const Offset(475, 400));
        await gesture.up();

        expectPoint(points[1], 0, 0.5);
        expectPoint(points[2], 0.25, 0.5);
        expect(events.last, 'release');
      });
    });
  });

  group('cancelled, exactly once', () {
    testWidgets('the browser cancels the pointer', (tester) async {
      await pumpLayer(tester);
      final gesture = await hold(tester);
      await gesture.moveBy(const Offset(20, 0));

      await gesture.cancel();
      await tester.pump();

      expect(events, ['hold', 'move', 'cancel']);
    });

    testWidgets('a second pointer', (tester) async {
      await pumpLayer(tester);
      final gesture = await hold(tester);

      final second = await tester.startGesture(const Offset(500, 300));
      await second.up();
      await gesture.moveBy(const Offset(20, 0));
      await gesture.up();
      await tester.pump();

      expect(events, ['hold', 'cancel']);
      expect(taps, isEmpty);
    });

    testWidgets('the wheel', (tester) async {
      await pumpLayer(tester);
      final gesture = await hold(tester);

      final mouse = TestPointer(9, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(centre));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
      await gesture.up();
      await tester.pump();

      expect(events, ['hold', 'cancel']);
    });

    testWidgets('another button pressed', (tester) async {
      await pumpLayer(tester);
      final mouse = TestPointer(42, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.down(centre));
      await tester.pump(timeout);

      await tester.sendEventToBinding(
        PointerMoveEvent(
          pointer: 42,
          kind: PointerDeviceKind.mouse,
          position: centre + const Offset(10, 0),
          buttons: kPrimaryButton | kSecondaryButton,
        ),
      );
      await tester.sendEventToBinding(mouse.up());
      await tester.pump();

      expect(events, ['hold', 'cancel']);
    });

    testWidgets('the aspect ratio changes', (tester) async {
      await pumpLayer(tester);
      final gesture = await hold(tester);

      aspectRatio = 1280 / 800;
      await pumpLayer(tester);
      await gesture.moveBy(const Offset(10, 0));
      await gesture.up();
      await tester.pump();

      expect(events, ['hold', 'cancel']);
    });

    testWidgets('the surface changes size, the pointer standing still', (
      tester,
    ) async {
      await pumpLayer(tester);
      final gesture = await hold(tester);

      await pumpLayer(tester, width: 1100);
      await tester.pump();

      expect(events, ['hold', 'cancel']);
      await gesture.up();
      await tester.pump();
      expect(events, ['hold', 'cancel']);
    });

    testWidgets('the surface goes away', (tester) async {
      await pumpLayer(tester);
      final gesture = await hold(tester);

      await pumpLayer(tester, mounted: false);
      await gesture.up();
      await tester.pump();

      expect(events, ['hold', 'cancel']);
    });

    testWidgets('a release after it went away reports nothing', (tester) async {
      await pumpLayer(tester);
      final gesture = await hold(tester);
      await gesture.up();
      await tester.pump();

      await pumpLayer(tester, mounted: false);

      expect(events, ['hold', 'release']);
    });
  });

  group('without onTouch, the legacy long press', () {
    testWidgets('one long press and nothing after it', (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
                onSwipe:
                    ({
                      required NormalizedRemotePoint start,
                      required NormalizedRemotePoint end,
                      required int durationMs,
                    }) => swipes++,
                onLongPress: longPresses.add,
              ),
            ),
          ),
        ),
      );
      final gesture = await hold(tester);
      await gesture.moveTo(const Offset(100, 400));
      await gesture.up();
      await tester.pump();

      expect(longPresses, hasLength(1));
      expect(taps, isEmpty);
      expect(swipes, 0);
    });
  });
}
