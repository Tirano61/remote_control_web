import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
import 'package:remote_control_web/features/remote_control/domain/geometry/remote_video_geometry.dart';

/// Where a click lands on the tablet. The picture is drawn with `contain`, so
/// the container may hold empty bands, and none of them is a touch on anything.
void main() {
  NormalizedRemotePoint? normalize(
    double pointerX,
    double pointerY, {
    required double containerWidth,
    required double containerHeight,
    required double videoWidth,
    required double videoHeight,
  }) => RemoteVideoGeometry.normalize(
    pointerX: pointerX,
    pointerY: pointerY,
    containerWidth: containerWidth,
    containerHeight: containerHeight,
    videoAspectRatio: videoWidth / videoHeight,
  );

  void expectPoint(NormalizedRemotePoint? point, double x, double y) {
    expect(point, isNotNull);
    expect(point!.x, closeTo(x, 1e-9));
    expect(point.y, closeTo(y, 1e-9));
  }

  group('same aspect ratio', () {
    NormalizedRemotePoint? at(double x, double y) => normalize(
      x,
      y,
      containerWidth: 1280,
      containerHeight: 800,
      videoWidth: 1280,
      videoHeight: 800,
    );

    test('there are no bands', () {
      final rect = RemoteVideoGeometry.containRect(
        containerWidth: 1280,
        containerHeight: 800,
        videoAspectRatio: 1280 / 800,
      )!;

      expect(rect.left, 0);
      expect(rect.top, 0);
      expect(rect.width, 1280);
      expect(rect.height, 800);
    });

    test('the centre is the centre', () {
      expectPoint(at(640, 400), 0.5, 0.5);
    });

    test('the four corners are the corners', () {
      expectPoint(at(0, 0), 0, 0);
      expectPoint(at(1280, 0), 1, 0);
      expectPoint(at(0, 800), 0, 1);
      expectPoint(at(1280, 800), 1, 1);
    });

    test('outside the container is not the picture', () {
      expect(at(-1, 400), isNull);
      expect(at(1281, 400), isNull);
      expect(at(640, -1), isNull);
      expect(at(640, 801), isNull);
    });
  });

  group('portrait video in a landscape container', () {
    // 800x1280 in 1200x800: 500 wide, centred, 350 of band at each side.
    NormalizedRemotePoint? at(double x, double y) => normalize(
      x,
      y,
      containerWidth: 1200,
      containerHeight: 800,
      videoWidth: 800,
      videoHeight: 1280,
    );

    test('the picture takes the full height, with bands at the sides', () {
      final rect = RemoteVideoGeometry.containRect(
        containerWidth: 1200,
        containerHeight: 800,
        videoAspectRatio: 800 / 1280,
      )!;

      expect(rect.left, closeTo(350, 1e-9));
      expect(rect.top, 0);
      expect(rect.width, closeTo(500, 1e-9));
      expect(rect.height, 800);
    });

    test('the left band is not a tap', () {
      expect(at(0, 400), isNull);
      expect(at(349, 400), isNull);
      expect(at(349.9, 400), isNull);
    });

    test('the right band is not a tap', () {
      expect(at(851, 400), isNull);
      expect(at(850.1, 400), isNull);
      expect(at(1200, 400), isNull);
    });

    test('the centre of the video is the centre of the tablet', () {
      expectPoint(at(600, 400), 0.5, 0.5);
    });

    test('the top-left of the video is exactly 0,0', () {
      expectPoint(at(350, 0), 0, 0);
    });

    test('the bottom-right of the video is 1,1', () {
      expectPoint(at(850, 800), 1, 1);
    });
  });

  group('landscape video in a tall container', () {
    // 1280x800 in 800x1000: 500 high, centred, 250 of band above and below.
    NormalizedRemotePoint? at(double x, double y) => normalize(
      x,
      y,
      containerWidth: 800,
      containerHeight: 1000,
      videoWidth: 1280,
      videoHeight: 800,
    );

    test('the picture takes the full width, with bands above and below', () {
      final rect = RemoteVideoGeometry.containRect(
        containerWidth: 800,
        containerHeight: 1000,
        videoAspectRatio: 1280 / 800,
      )!;

      expect(rect.left, 0);
      expect(rect.top, closeTo(250, 1e-9));
      expect(rect.width, 800);
      expect(rect.height, closeTo(500, 1e-9));
    });

    test('the top band is not a tap', () {
      expect(at(400, 0), isNull);
      expect(at(400, 249.9), isNull);
    });

    test('the bottom band is not a tap', () {
      expect(at(400, 750.1), isNull);
      expect(at(400, 1000), isNull);
    });

    test('the centre of the video is the centre of the tablet', () {
      expectPoint(at(400, 500), 0.5, 0.5);
    });

    test('the top-left of the video is exactly 0,0', () {
      expectPoint(at(0, 250), 0, 0);
    });

    test('the bottom-right of the video is 1,1', () {
      expectPoint(at(800, 750), 1, 1);
    });
  });

  group('edges', () {
    const fractions = [0.0, 1.0];

    // Sizes picked because their divisions do not come out round.
    const containers = [
      (1100.0, 770.0),
      (1093.0, 617.0),
      (333.0, 777.0),
      (1234.5, 987.6),
    ];
    const videos = [(800.0, 1280.0), (1280.0, 800.0), (1079.0, 2341.0)];

    for (final (containerWidth, containerHeight) in containers) {
      for (final (videoWidth, videoHeight) in videos) {
        test('never leaves 0..1 with ${videoWidth}x$videoHeight '
            'in ${containerWidth}x$containerHeight', () {
          final rect = RemoteVideoGeometry.containRect(
            containerWidth: containerWidth,
            containerHeight: containerHeight,
            videoAspectRatio: videoWidth / videoHeight,
          )!;

          NormalizedRemotePoint? at(double fx, double fy) => normalize(
            rect.left + rect.width * fx,
            rect.top + rect.height * fy,
            containerWidth: containerWidth,
            containerHeight: containerHeight,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
          );

          for (final fx in fractions) {
            for (final fy in fractions) {
              expectPoint(at(fx, fy), fx, fy);
            }
          }
          expectPoint(at(0.5, 0.5), 0.5, 0.5);
        });
      }
    }

    test('a video that fills the box by rounding keeps its edges', () {
      // What the surface really does: its box is computed from the ratio, so
      // the rectangle computed back can end a rounding error away from it.
      const aspectRatio = 1079 / 2341;
      const height = 617.0;
      const width = height * aspectRatio;

      final point = RemoteVideoGeometry.normalize(
        pointerX: 0,
        pointerY: 0,
        containerWidth: width,
        containerHeight: height,
        videoAspectRatio: aspectRatio,
      );
      final farPoint = RemoteVideoGeometry.normalize(
        pointerX: width,
        pointerY: height,
        containerWidth: width,
        containerHeight: height,
        videoAspectRatio: aspectRatio,
      );

      expectPoint(point, 0, 0);
      expectPoint(farPoint, 1, 1);
    });

    test('rounding is not an excuse to accept a band', () {
      // A tenth of a CSS pixel into the band: it stays a band, never the edge.
      expect(
        normalize(
          349.9,
          0,
          containerWidth: 1200,
          containerHeight: 800,
          videoWidth: 800,
          videoHeight: 1280,
        ),
        isNull,
      );
    });
  });

  group('rotation', () {
    test('the same click follows the geometry it is given', () {
      const pointerX = 600.0;
      const pointerY = 400.0;

      final portrait = normalize(
        pointerX,
        pointerY,
        containerWidth: 1200,
        containerHeight: 800,
        videoWidth: 800,
        videoHeight: 1280,
      );
      expectPoint(portrait, 0.5, 0.5);

      // Nothing was kept from the portrait call.
      final landscape = normalize(
        900,
        pointerY,
        containerWidth: 1200,
        containerHeight: 800,
        videoWidth: 1280,
        videoHeight: 800,
      );
      expectPoint(landscape, 0.75, 0.5);
    });

    test('what was a band in portrait is the picture in landscape', () {
      expect(
        normalize(
          100,
          400,
          containerWidth: 1200,
          containerHeight: 800,
          videoWidth: 800,
          videoHeight: 1280,
        ),
        isNull,
      );
      expectPoint(
        normalize(
          120,
          400,
          containerWidth: 1200,
          containerHeight: 800,
          videoWidth: 1280,
          videoHeight: 800,
        ),
        0.1,
        0.5,
      );
    });
  });

  group('values that describe no picture', () {
    test('produce no rectangle and no point', () {
      for (final (width, height, ratio) in const [
        (0.0, 800.0, 1.6),
        (1200.0, 0.0, 1.6),
        (1200.0, 800.0, 0.0),
        (-1200.0, 800.0, 1.6),
        (1200.0, 800.0, double.nan),
        (1200.0, 800.0, double.infinity),
        (double.nan, 800.0, 1.6),
      ]) {
        expect(
          RemoteVideoGeometry.containRect(
            containerWidth: width,
            containerHeight: height,
            videoAspectRatio: ratio,
          ),
          isNull,
        );
        expect(
          RemoteVideoGeometry.normalize(
            pointerX: 1,
            pointerY: 1,
            containerWidth: width,
            containerHeight: height,
            videoAspectRatio: ratio,
          ),
          isNull,
        );
      }
    });

    test('a pointer that is not a number is not on the picture', () {
      expect(
        normalize(
          double.nan,
          400,
          containerWidth: 1280,
          containerHeight: 800,
          videoWidth: 1280,
          videoHeight: 800,
        ),
        isNull,
      );
    });
  });
}
