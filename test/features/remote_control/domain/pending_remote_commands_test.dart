import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_web/features/remote_control/domain/services/pending_remote_commands.dart';

/// The tablet runs one gesture at a time, so a valid answer can take as long as
/// everything sent before it.
void main() {
  const margin = Duration(seconds: 3);

  RemoteSwipeCommand swipe(String id, int durationMs) => RemoteSwipeCommand(
    id: id,
    start: const NormalizedRemotePoint(0.5, 0.8),
    end: const NormalizedRemotePoint(0.5, 0.2),
    durationMs: durationMs,
  );

  RemoteTapCommand tap(String id) =>
      RemoteTapCommand(id: id, point: const NormalizedRemotePoint(0.5, 0.5));

  group('deadlineFor', () {
    Duration deadline(
      RemoteControlCommand command, [
      List<RemoteControlCommand> ahead = const [],
    ]) => PendingRemoteCommands.deadlineFor(
      command,
      ahead: ahead,
      margin: margin,
    );

    test('a tap alone is its gesture and the margin', () {
      expect(deadline(tap('a')), const Duration(milliseconds: 3050));
    });

    test('a swipe alone is its duration and the margin', () {
      expect(deadline(swipe('a', 350)), const Duration(milliseconds: 3350));
    });

    test('no command gets less than three seconds', () {
      expect(deadline(tap('a')), greaterThanOrEqualTo(margin));
      expect(deadline(swipe('a', 50)), greaterThanOrEqualTo(margin));
    });

    test('everything ahead is added, whatever its kind', () {
      expect(
        deadline(swipe('c', 2000), [tap('a'), swipe('b', 2000)]),
        const Duration(milliseconds: 50 + 2000 + 2000 + 3000),
      );
    });

    test('what the tablet can hold fits below the maximum', () {
      // One gesture running and 16 queued, all of them the longest swipe, and
      // the last one is the last one the tablet would still accept.
      final ahead = [for (var i = 0; i < 16; i++) swipe('$i', 2000)];

      expect(deadline(swipe('last', 2000), ahead), const Duration(seconds: 37));
      expect(
        const Duration(seconds: 37),
        lessThan(PendingRemoteCommands.maxDeadline),
      );
    });

    test('a queue longer than that stops at the maximum', () {
      final ahead = [for (var i = 0; i < 40; i++) swipe('$i', 2000)];

      expect(deadline(swipe('last', 2000), ahead), const Duration(seconds: 45));
      expect(PendingRemoteCommands.maxDeadline, const Duration(seconds: 45));
    });
  });

  group('track', () {
    late List<String> expired;

    setUp(() => expired = []);

    test('a lone swipe expires at its deadline and not before', () {
      fakeAsync((time) {
        final pending = PendingRemoteCommands(margin: margin);
        pending.track(swipe('a', 350), onTimeout: expired.add);

        time.elapse(const Duration(milliseconds: 3349));
        expect(expired, isEmpty);

        time.elapse(const Duration(milliseconds: 1));
        expect(expired, ['a']);
      });
    });

    test('a swipe behind another does not expire at three seconds', () {
      fakeAsync((time) {
        final pending = PendingRemoteCommands(margin: margin);
        pending
          ..track(swipe('a', 2000), onTimeout: expired.add)
          ..track(swipe('b', 2000), onTimeout: expired.add);

        time.elapse(const Duration(seconds: 3));
        expect(expired, isEmpty);

        // 2 + 3 for the first; 2 + 2 + 3 for the second.
        time.elapse(const Duration(seconds: 2));
        expect(expired, ['a']);

        time.elapse(const Duration(seconds: 2));
        expect(expired, ['a', 'b']);
      });
    });

    test('the last of a long queue gets its whole budget', () {
      fakeAsync((time) {
        final pending = PendingRemoteCommands(margin: margin);
        for (var i = 0; i < 16; i++) {
          pending.track(swipe('$i', 2000), onTimeout: (_) {});
        }
        pending.track(swipe('last', 2000), onTimeout: expired.add);

        time.elapse(const Duration(seconds: 36));
        expect(expired, isEmpty);

        time.elapse(const Duration(seconds: 1));
        expect(expired, ['last']);
      });
    });

    test('only what is still waiting counts as ahead', () {
      fakeAsync((time) {
        final pending = PendingRemoteCommands(margin: margin);
        pending.track(swipe('a', 2000), onTimeout: expired.add);
        expect(pending.settle('a'), isNotNull);

        pending.track(swipe('b', 100), onTimeout: expired.add);

        time.elapse(const Duration(milliseconds: 3100));
        expect(expired, ['b']);
      });
    });

    test('settling cancels the deadline and gives the command back', () {
      fakeAsync((time) {
        final pending = PendingRemoteCommands(margin: margin);
        final command = swipe('a', 350);
        pending.track(command, onTimeout: expired.add);

        expect(pending.settle('a'), command);
        expect(pending.settle('a'), isNull);

        time.elapse(const Duration(minutes: 1));
        expect(expired, isEmpty);
        expect(pending.length, 0);
      });
    });

    test('clearing cancels every deadline, tap or swipe', () {
      fakeAsync((time) {
        final pending = PendingRemoteCommands(margin: margin);
        pending
          ..track(tap('a'), onTimeout: expired.add)
          ..track(swipe('b', 2000), onTimeout: expired.add);

        pending.clear();

        time.elapse(const Duration(minutes: 1));
        expect(expired, isEmpty);
        expect(pending.length, 0);
        expect(time.pendingTimers, isEmpty);
      });
    });
  });
}
