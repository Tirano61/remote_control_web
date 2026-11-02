import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_control/domain/services/remote_navigation_guard.dart';

/// Ends when the action was accepted and the settle time has passed, whichever
/// comes last, or at once when it was not accepted.
void main() {
  const settle = Duration(milliseconds: 350);

  late RemoteNavigationGuard guard;

  setUp(() => guard = RemoteNavigationGuard(settleDuration: settle));

  /// Begins on [commandId], feeding the deadline back the way the BLoC does.
  void begin(String commandId) =>
      guard.begin(commandId, onElapsed: guard.elapse);

  test('nothing is held back until something begins', () {
    expect(guard.isActive, isFalse);
  });

  test('an answer before the settle time waits for it', () {
    fakeAsync((time) {
      begin('home-1');
      expect(guard.isActive, isTrue);

      time.elapse(const Duration(milliseconds: 80));
      guard.accept('home-1');
      expect(guard.isActive, isTrue);

      time.elapse(const Duration(milliseconds: 269));
      expect(guard.isActive, isTrue);

      time.elapse(const Duration(milliseconds: 1));
      expect(guard.isActive, isFalse);
    });
  });

  test('an answer after the settle time ends it there and then', () {
    fakeAsync((time) {
      begin('back-1');

      time.elapse(const Duration(milliseconds: 500));
      expect(guard.isActive, isTrue);

      guard.accept('back-1');
      expect(guard.isActive, isFalse);
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('the settle time alone does not end it', () {
    fakeAsync((time) {
      begin('back-1');

      time.elapse(const Duration(minutes: 1));

      expect(guard.isActive, isTrue);
    });
  });

  test('a command that was not accepted ends it at once', () {
    fakeAsync((time) {
      begin('home-1');

      time.elapse(const Duration(milliseconds: 50));
      guard.release('home-1');

      expect(guard.isActive, isFalse);
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('another command is none of its business', () {
    fakeAsync((time) {
      begin('home-2');

      guard
        ..accept('tap-1')
        ..release('tap-1')
        ..elapse('tap-1');

      time.elapse(settle);
      expect(guard.isActive, isTrue);

      guard.accept('home-2');
      expect(guard.isActive, isFalse);
    });
  });

  test('clearing cancels the deadline', () {
    fakeAsync((time) {
      begin('back-1');

      guard.clear();

      expect(guard.isActive, isFalse);
      expect(time.pendingTimers, isEmpty);
    });
  });

  test('what is left of a command says nothing about the next one', () {
    fakeAsync((time) {
      begin('back-1');
      guard.accept('back-1');
      time.elapse(settle);
      expect(guard.isActive, isFalse);

      begin('home-2');
      guard.accept('home-2');
      expect(guard.isActive, isTrue);

      time.elapse(settle);
      expect(guard.isActive, isFalse);
    });
  });
}
