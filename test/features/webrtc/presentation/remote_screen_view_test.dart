import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
