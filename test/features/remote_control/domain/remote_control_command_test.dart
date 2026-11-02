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
        ids.next(RemoteCommandKind.tap),
      ],
      ['tap-1', 'swipe-2', 'tap-3'],
    );
  });
}
