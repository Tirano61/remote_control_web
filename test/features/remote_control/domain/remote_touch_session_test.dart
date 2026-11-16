import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
import 'package:remote_control_web/features/remote_control/domain/geometry/remote_video_geometry.dart';
import 'package:remote_control_web/features/remote_control/domain/services/remote_control_command_id_generator.dart';
import 'package:remote_control_web/features/remote_control/domain/services/remote_touch_session.dart';

const _start = NormalizedRemotePoint(0.4, 0.5);

RemoteTouchSession _touch(List<RemoteTouchTimer> fired) => RemoteTouchSession(
  touchId: 't-1',
  holdId: 'hold-2',
  pointer: 1,
  generation: 1,
  remoteSessionId: 'session',
  channel: Object(),
  initialPoint: _start,
  support: RemoteTouchSupport.unknown,
  answerDeadline: const Duration(seconds: 8),
  onTimer: fired.add,
);

void main() {
  group('RemoteTouchSession', () {
    test('the limits are the ones agreed with the tablet', () {
      expect(
        RemoteTouchSession.keepaliveInterval,
        const Duration(milliseconds: 250),
      );
      expect(
        RemoteTouchSession.minMoveInterval,
        const Duration(milliseconds: 33),
      );
      expect(RemoteTouchSession.minMoveDistance, 0.002);
      expect(RemoteTouchSession.maxLifetime, const Duration(seconds: 30));
    });

    test('the keepalive starts with the hold, and only one timer runs', () {
      fakeAsync((time) {
        final fired = <RemoteTouchTimer>[];
        final touch = _touch(fired)..start();

        time.elapse(const Duration(milliseconds: 250));
        expect(fired, [RemoteTouchTimer.keepalive]);
        touch.move('mv-3', isKeepalive: true);
        expect(time.pendingTimers.length, 3); // keepalive, throttle, lifetime

        touch.end();
        expect(time.pendingTimers, isEmpty);
      });
    });

    test('seq: 1, 2, 3, never reused, release and cancel included', () {
      fakeAsync((time) {
        final touch = _touch([])..start();
        expect(touch.move('mv-3', isKeepalive: true).seq, 1);
        touch.observe(const NormalizedRemotePoint(0.6, 0.6));
        expect(touch.move('mv-4', isKeepalive: false).seq, 2);
        expect(touch.release('rel-5', _start).seq, 3);
        expect(touch.lastSeq, 3);
        touch.end();
      });
    });

    test('a move is due once far enough and out of the window', () {
      fakeAsync((time) {
        final touch = _touch([])..start();

        expect(
          touch.observe(const NormalizedRemotePoint(0.4015, 0.5)),
          isFalse,
        );
        expect(touch.observe(const NormalizedRemotePoint(0.402, 0.5)), isTrue);
        touch.move('mv-3', isKeepalive: false);
        expect(touch.observe(const NormalizedRemotePoint(0.5, 0.5)), isFalse);
        time.elapse(const Duration(milliseconds: 33));
        expect(touch.isMoveDue, isTrue);
        touch.end();
      });
    });

    test('ids of this touch are recognised, and forgotten at the end', () {
      fakeAsync((time) {
        final touch = _touch([])..start();
        touch.move('mv-3', isKeepalive: true);
        touch.release('rel-4', _start);

        expect(touch.messageOf('hold-2'), RemoteTouchMessage.hold);
        expect(touch.messageOf('mv-3'), RemoteTouchMessage.move);
        expect(touch.messageOf('rel-4'), RemoteTouchMessage.release);
        expect(touch.messageOf('tap-9'), isNull);

        touch.end();
        expect(touch.messageOf('mv-3'), isNull);
        expect(touch.trackedMoveIds, 0);
      });
    });

    test('the move ids kept are bounded', () {
      fakeAsync((time) {
        final touch = _touch([])..start();
        for (var i = 0; i < 2000; i++) {
          touch.move('mv-$i', isKeepalive: true);
        }
        expect(touch.trackedMoveIds, RemoteTouchSession.maxTrackedMoveIds);
        expect(touch.messageOf('mv-1999'), RemoteTouchMessage.move);
        touch.end();
      });
    });

    test('releasing stops streaming and waits for an answer', () {
      fakeAsync((time) {
        final fired = <RemoteTouchTimer>[];
        final touch = _touch(fired)..start();
        touch.release('rel-3', _start);

        expect(touch.stage, RemoteTouchStage.releasing);
        expect(touch.isStreaming, isFalse);
        expect(touch.observe(const NormalizedRemotePoint(0.9, 0.9)), isFalse);
        time.elapse(const Duration(seconds: 8));
        expect(fired, [RemoteTouchTimer.deadline]);
        touch.end();
      });
    });

    test('the lifetime reports at 30 s', () {
      fakeAsync((time) {
        final fired = <RemoteTouchTimer>[];
        final touch = _touch(fired)..start();
        // A keepalive every time it is due, as the bloc does.
        for (var i = 0; i < 120; i++) {
          if (i == 119) {
            expect(fired, isNot(contains(RemoteTouchTimer.lifetime)));
          }
          time.elapse(const Duration(milliseconds: 250));
          if (fired.last == RemoteTouchTimer.keepalive) {
            touch.move('mv-$i', isKeepalive: true);
          }
        }
        expect(
          fired.where((t) => t == RemoteTouchTimer.lifetime),
          hasLength(1),
        );
        touch.end();
      });
    });

    test('the hold answered: active', () {
      final touch = _touch([]);
      touch.confirmHold();
      expect(touch.stage, RemoteTouchStage.active);
      expect(touch.holdAnswer, RemoteTouchHoldAnswer.confirmed);
      touch.end();
    });
  });

  group('ids', () {
    test('touch names come from the same counter as the ids', () {
      final ids = SequentialRemoteControlCommandIdGenerator();
      expect(ids.nextTouch(), 't-1');
      expect(ids.nextTouch(), 't-2');
    });
  });

  group('clampToPicture', () {
    // A 1200 x 800 box: a portrait picture 500 wide from x = 350, and a
    // landscape one 750 tall from y = 25.
    NormalizedRemotePoint? portrait(double x, double y) =>
        RemoteVideoGeometry.clampToPicture(
          pointerX: x,
          pointerY: y,
          containerWidth: 1200,
          containerHeight: 800,
          videoAspectRatio: 800 / 1280,
        );
    NormalizedRemotePoint? landscape(double x, double y) =>
        RemoteVideoGeometry.clampToPicture(
          pointerX: x,
          pointerY: y,
          containerWidth: 1200,
          containerHeight: 800,
          videoAspectRatio: 1.6,
        );

    test('on the picture: the same point as normalize', () {
      expect(portrait(600, 400), const NormalizedRemotePoint(0.5, 0.5));
      expect(
        portrait(600, 400),
        RemoteVideoGeometry.normalize(
          pointerX: 600,
          pointerY: 400,
          containerWidth: 1200,
          containerHeight: 800,
          videoAspectRatio: 800 / 1280,
        ),
      );
    });

    test('left band and beyond: x = 0, of the picture, not of the box', () {
      expect(portrait(349, 400), const NormalizedRemotePoint(0, 0.5));
      expect(portrait(-500, 400), const NormalizedRemotePoint(0, 0.5));
    });

    test('right band and beyond: x = 1', () {
      expect(portrait(851, 400), const NormalizedRemotePoint(1, 0.5));
      expect(portrait(5000, 400), const NormalizedRemotePoint(1, 0.5));
    });

    test('above: y = 0, below: y = 1', () {
      expect(landscape(600, 10), const NormalizedRemotePoint(0.5, 0));
      expect(landscape(600, -300), const NormalizedRemotePoint(0.5, 0));
      expect(landscape(600, 790), const NormalizedRemotePoint(0.5, 1));
      expect(landscape(600, 3000), const NormalizedRemotePoint(0.5, 1));
    });

    test('a corner', () {
      expect(landscape(-10, -10), const NormalizedRemotePoint(0, 0));
      expect(landscape(1300, 900), const NormalizedRemotePoint(1, 1));
    });

    test('no picture or no position: null', () {
      expect(
        RemoteVideoGeometry.clampToPicture(
          pointerX: 1,
          pointerY: 1,
          containerWidth: 0,
          containerHeight: 800,
          videoAspectRatio: 1,
        ),
        isNull,
      );
      expect(portrait(double.nan, 1), isNull);
      expect(portrait(1, double.infinity), isNull);
    });

    test('normalize still never moves a band to an edge', () {
      expect(
        RemoteVideoGeometry.normalize(
          pointerX: 349,
          pointerY: 400,
          containerWidth: 1200,
          containerHeight: 800,
          videoAspectRatio: 800 / 1280,
        ),
        isNull,
      );
    });
  });
}
