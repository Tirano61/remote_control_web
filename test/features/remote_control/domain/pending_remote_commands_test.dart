import 'dart:developer' as developer;

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
      command.estimatedWork,
      ahead: ahead.map((pending) => pending.estimatedWork),
      margin: margin,
    );

    test('a tap alone is its gesture and the margin', () {
      expect(deadline(tap('a')), const Duration(milliseconds: 3050));
    });

    test('a swipe alone is its duration and the margin', () {
      expect(deadline(swipe('a', 350)), const Duration(milliseconds: 3350));
    });

    test('Back, Home and Recents alone are their 50 ms and the margin', () {
      const expected = Duration(milliseconds: 3050);

      expect(deadline(const RemoteBackCommand(id: 'a')), expected);
      expect(deadline(const RemoteHomeCommand(id: 'a')), expected);
      expect(deadline(const RemoteRecentsCommand(id: 'a')), expected);
    });

    test('Recents waits for what is ahead, and counts for what follows', () {
      expect(
        deadline(const RemoteRecentsCommand(id: 'b'), [swipe('a', 2000)]),
        const Duration(milliseconds: 2000 + 50 + 3000),
      );
      expect(
        deadline(tap('b'), [const RemoteRecentsCommand(id: 'a')]),
        const Duration(milliseconds: 50 + 50 + 3000),
      );
    });

    test('Recents stops at the same maximum', () {
      final ahead = [for (var i = 0; i < 40; i++) swipe('$i', 2000)];

      expect(
        deadline(const RemoteRecentsCommand(id: 'last'), ahead),
        PendingRemoteCommands.maxDeadline,
      );
    });

    test(
      'Back and Home wait for what is ahead, and count for what follows',
      () {
        expect(
          deadline(const RemoteHomeCommand(id: 'b'), [swipe('a', 2000)]),
          const Duration(milliseconds: 2000 + 50 + 3000),
        );
        expect(
          deadline(tap('b'), [const RemoteBackCommand(id: 'a')]),
          const Duration(milliseconds: 50 + 50 + 3000),
        );
      },
    );

    test('Back and Home stop at the same maximum', () {
      final ahead = [for (var i = 0; i < 40; i++) swipe('$i', 2000)];

      expect(
        deadline(const RemoteBackCommand(id: 'last'), ahead),
        PendingRemoteCommands.maxDeadline,
      );
    });

    test('a text alone is its five seconds and the margin', () {
      expect(
        deadline(const RemoteSetTextCommand(id: 'a', text: 'b')),
        const Duration(seconds: 8),
      );
    });

    test('a text stops at the same maximum', () {
      final ahead = [for (var i = 0; i < 40; i++) swipe('$i', 2000)];

      expect(
        deadline(const RemoteSetTextCommand(id: 'last', text: 'b'), ahead),
        PendingRemoteCommands.maxDeadline,
      );
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

    test('settling cancels the deadline and says what it was', () {
      fakeAsync((time) {
        final pending = PendingRemoteCommands(margin: margin);
        pending.track(swipe('a', 350), onTimeout: expired.add);

        expect(
          pending.settle('a'),
          const PendingRemoteCommand(
            commandId: 'a',
            kind: RemoteCommandKind.swipe,
            estimatedWork: Duration(milliseconds: 350),
          ),
        );
        expect(pending.settle('a'), isNull);

        time.elapse(const Duration(minutes: 1));
        expect(expired, isEmpty);
        expect(pending.length, 0);
      });
    });

    group('a text', () {
      const sentinel = 'SUPER_SECRET_REMOTE_TEXT_123';

      test('what is kept while waiting is not the command', () {
        fakeAsync((time) {
          final pending = PendingRemoteCommands(margin: margin);
          pending.track(
            const RemoteSetTextCommand(id: 'text-1', text: sentinel),
            onTimeout: expired.add,
          );

          final kept = pending.commands.single;
          expect(kept, isNot(isA<RemoteControlCommand>()));
          expect(kept.commandId, 'text-1');
          expect(kept.kind, RemoteCommandKind.setText);
          expect(kept.estimatedWork, remoteSetTextEstimatedWork);
          expect(kept.props, isNot(contains(sentinel)));
          expect('$kept', isNot(contains(sentinel)));

          final settled = pending.settle('text-1')!;
          expect(settled, isNot(isA<RemoteControlCommand>()));
          expect(settled, kept);
        });
      });

      test('its deadline is eight seconds', () {
        fakeAsync((time) {
          final pending = PendingRemoteCommands(margin: margin);
          pending.track(
            const RemoteSetTextCommand(id: 'text-1', text: sentinel),
            onTimeout: expired.add,
          );

          time.elapse(const Duration(milliseconds: 7999));
          expect(expired, isEmpty);

          time.elapse(const Duration(milliseconds: 1));
          expect(expired, ['text-1']);
        });
      });

      test('neither the map nor the deadline keep the command alive', () async {
        final pending = PendingRemoteCommands(margin: margin);

        WeakReference<RemoteSetTextCommand> tracked() {
          final command = RemoteSetTextCommand(
            id: 'text-1',
            // Not a constant: those are never collected.
            text: String.fromCharCodes(sentinel.codeUnits),
          );
          pending.track(command, onTimeout: expired.add);
          return WeakReference(command);
        }

        final reference = tracked();
        await _collectGarbage();

        expect(pending.length, 1);
        expect(reference.target, isNull);
        pending.clear();
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

/// Allocates until the VM has been through full collections, which is the only
/// way to see that something is really not referenced any more.
Future<void> _collectGarbage() async {
  final barrier = developer.reachabilityBarrier;
  final storage = <List<int>>[];
  while (developer.reachabilityBarrier < barrier + 2) {
    await Future<void>.delayed(Duration.zero);
    storage.add(List.generate(30000, (n) => n));
    if (storage.length > 100) storage.removeAt(0);
  }
}
