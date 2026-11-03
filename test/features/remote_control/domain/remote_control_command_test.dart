import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_web/features/remote_control/domain/services/remote_control_command_id_generator.dart';

void main() {
  const start = NormalizedRemotePoint(0.5, 0.8);
  const end = NormalizedRemotePoint(0.5, 0.2);

  group('the duration of a swipe', () {
    const expectations = {20: 50, 50: 50, 350: 350, 2000: 2000, 3000: 2000};

    expectations.forEach((elapsedMs, durationMs) {
      test('$elapsedMs ms -> $durationMs', () {
        expect(
          RemoteSwipeCommand.durationMsFor(Duration(milliseconds: elapsedMs)),
          durationMs,
        );
      });
    });

    test('a clock that went backwards still gives a valid duration', () {
      expect(
        RemoteSwipeCommand.durationMsFor(const Duration(milliseconds: -5)),
        RemoteSwipeCommand.minDurationMs,
      );
    });
  });

  group('what the tablet would have to work on', () {
    test('a tap is its 50 ms', () {
      expect(
        const RemoteTapCommand(id: 'tap-1', point: start).estimatedWork,
        const Duration(milliseconds: 50),
      );
    });

    test('a swipe is its duration', () {
      expect(
        RemoteSwipeCommand(
          id: 'swipe-1',
          start: start,
          end: end,
          durationMs: 350,
        ).estimatedWork,
        const Duration(milliseconds: 350),
      );
    });

    test('Back, Home and Recents are 50 ms of the queue', () {
      expect(remoteNavigationEstimatedWork, const Duration(milliseconds: 50));
      expect(
        const RemoteBackCommand(id: 'back-1').estimatedWork,
        remoteNavigationEstimatedWork,
      );
      expect(
        const RemoteHomeCommand(id: 'home-1').estimatedWork,
        remoteNavigationEstimatedWork,
      );
      expect(
        const RemoteRecentsCommand(id: 'recents-1').estimatedWork,
        remoteNavigationEstimatedWork,
      );
    });
  });

  group('Back, Home and Recents', () {
    test('an id is all they need', () {
      const back = RemoteBackCommand(id: 'back-1');
      const home = RemoteHomeCommand(id: 'home-1');
      const recents = RemoteRecentsCommand(id: 'recents-1');

      expect(back.props, ['back-1']);
      expect(home.props, ['home-1']);
      expect(recents.props, ['recents-1']);
      expect(back.kind, RemoteCommandKind.back);
      expect(home.kind, RemoteCommandKind.home);
      expect(recents.kind, RemoteCommandKind.recents);
    });

    test('they are not taps, nor each other', () {
      const back = RemoteBackCommand(id: 'same');
      const home = RemoteHomeCommand(id: 'same');
      const recents = RemoteRecentsCommand(id: 'same');

      expect(back, isNot(isA<RemoteTapCommand>()));
      expect(home, isNot(isA<RemoteTapCommand>()));
      expect(recents, isNot(isA<RemoteTapCommand>()));
      expect(back == const RemoteBackCommand(id: 'same'), isTrue);
      expect(recents == const RemoteRecentsCommand(id: 'same'), isTrue);
      expect(back == home, isFalse);
      expect(recents == back, isFalse);
      expect(recents == home, isFalse);
    });

    test('only they are navigation', () {
      expect(RemoteCommandKind.values.where((kind) => kind.isNavigation), [
        RemoteCommandKind.back,
        RemoteCommandKind.home,
        RemoteCommandKind.recents,
      ]);
    });

    test('what gets printed is the id', () {
      expect(
        const RemoteBackCommand(id: 'back-1').toString(),
        'RemoteBackCommand(back-1)',
      );
      expect(
        const RemoteHomeCommand(id: 'home-1').toString(),
        'RemoteHomeCommand(home-1)',
      );
      expect(
        const RemoteRecentsCommand(id: 'recents-1').toString(),
        'RemoteRecentsCommand(recents-1)',
      );
    });

    test('the settle time is 350 ms', () {
      expect(remoteNavigationSettleDuration, const Duration(milliseconds: 350));
    });
  });

  group('a swipe that breaks the contract is a bug', () {
    test('start and end being the same', () {
      expect(
        () => RemoteSwipeCommand(
          id: 'swipe-1',
          start: start,
          end: start,
          durationMs: 350,
        ),
        throwsAssertionError,
      );
    });

    for (final durationMs in const [49, 2001]) {
      test('a duration of $durationMs', () {
        expect(
          () => RemoteSwipeCommand(
            id: 'swipe-1',
            start: start,
            end: end,
            durationMs: durationMs,
          ),
          throwsAssertionError,
        );
      });
    }
  });

  test('coordinates stay out of what gets printed', () {
    final swipe = RemoteSwipeCommand(
      id: 'swipe-1',
      start: start,
      end: end,
      durationMs: 350,
    );

    expect(swipe.toString(), 'RemoteSwipeCommand(swipe-1)');
  });

  test('the sequence is shared by every kind of command', () {
    final ids = SequentialRemoteControlCommandIdGenerator();

    expect(
      [
        ids.next(RemoteCommandKind.tap),
        ids.next(RemoteCommandKind.swipe),
        ids.next(RemoteCommandKind.back),
        ids.next(RemoteCommandKind.home),
        ids.next(RemoteCommandKind.recents),
        ids.next(RemoteCommandKind.tap),
      ],
      ['tap-1', 'swipe-2', 'back-3', 'home-4', 'recents-5', 'tap-6'],
    );
  });
}
