import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_status.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_web/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../../support/webrtc_test_doubles.dart';

const _sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';
const _otherSessionId = '9a0f3d1b-4c88-9e64-6f2a-5c7e8b103d1b';
const _start = NormalizedRemotePoint(0.41, 0.52);
const _pointer = 7;

/// A BLoC on a clock the test moves: keepalives, throttling and deadlines are
/// all timers.
class _Harness {
  _Harness(this.time)
    : peers = FakeWebRtcPeerClient(),
      signaling = FakeTechnicianSignalingClient()
        ..joinedRemoteSessionId = _sessionId {
    bloc = WebRtcSessionBloc(
      peerClient: peers,
      signalingClient: signaling,
      iceConfiguration: const WebRtcIceConfiguration(),
    );
  }

  final FakeAsync time;
  final FakeWebRtcPeerClient peers;
  final FakeTechnicianSignalingClient signaling;
  late final WebRtcSessionBloc bloc;

  void run() {
    for (var i = 0; i < 12; i++) {
      time.elapse(Duration.zero);
    }
  }

  void wait(int milliseconds) {
    time.elapse(Duration(milliseconds: milliseconds));
    run();
  }

  /// Connected, `control` open, `ACTIVE`, and a picture on screen.
  void ready({String sessionId = _sessionId}) {
    bloc.add(WebRtcNegotiationRequested(sessionId));
    run();
    peers.last
      ..emitControlChannelState(WebRtcDataChannelState.open)
      ..emitPeerState(WebRtcPeerConnectionState.connected)
      ..emitRemoteVideoTrack();
    bloc.add(WebRtcRemoteSessionActivityChanged(sessionId));
    run();
    bloc.add(
      WebRtcRemotePictureChanged(remoteSessionId: sessionId, isDisplayed: true),
    );
    run();
  }

  void hold({
    NormalizedRemotePoint point = _start,
    int pointer = _pointer,
    String sessionId = _sessionId,
  }) {
    bloc.add(
      WebRtcRemoteTouchHoldRequested(
        remoteSessionId: sessionId,
        pointer: pointer,
        point: point,
      ),
    );
    run();
  }

  void move(double x, double y, {int pointer = _pointer}) {
    bloc.add(
      WebRtcRemoteTouchMoved(
        remoteSessionId: _sessionId,
        pointer: pointer,
        point: NormalizedRemotePoint(x, y),
      ),
    );
    run();
  }

  void release(double x, double y, {int pointer = _pointer}) {
    bloc.add(
      WebRtcRemoteTouchReleased(
        remoteSessionId: _sessionId,
        pointer: pointer,
        point: NormalizedRemotePoint(x, y),
      ),
    );
    run();
  }

  void cancel({int pointer = _pointer}) {
    bloc.add(
      WebRtcRemoteTouchCancelled(remoteSessionId: _sessionId, pointer: pointer),
    );
    run();
  }

  void ack(String id, {RemoteControlError? error}) {
    peers.last.emitRemoteControlAck(id, error: error);
    run();
  }

  void tap() {
    bloc.add(
      const WebRtcRemoteTapRequested(
        remoteSessionId: _sessionId,
        point: _start,
      ),
    );
    run();
  }

  RemoteControlStatus get status => bloc.state.remoteControl;
  List<RemoteControlCommand> get sent => peers.last.sentRemoteControlCommands;
  List<String> get ids => sent.map((c) => c.id).toList();
  List<String> get types => sent.map((c) => c.kind.logName).toList();
  List<RemoteTouchMoveCommand> get moves =>
      sent.whereType<RemoteTouchMoveCommand>().toList();
  List<RemoteTouchHoldCommand> get holds =>
      sent.whereType<RemoteTouchHoldCommand>().toList();
  List<RemoteLongPressCommand> get longPresses =>
      sent.whereType<RemoteLongPressCommand>().toList();
  List<RemoteTouchReleaseCommand> get releases =>
      sent.whereType<RemoteTouchReleaseCommand>().toList();
  List<RemoteTouchCancelCommand> get cancels =>
      sent.whereType<RemoteTouchCancelCommand>().toList();

  /// The `seq` of every touch message after the hold, in the order sent.
  List<int> get seqs => [
    for (final command in sent)
      switch (command) {
        RemoteTouchMoveCommand(:final seq) => seq,
        RemoteTouchReleaseCommand(:final seq) => seq,
        RemoteTouchCancelCommand(:final seq) => seq,
        _ => -1,
      },
  ].where((seq) => seq >= 0).toList();

  RemoteTouchPhase? get phase => status.lastTouch?.phase;

  void dispose() {
    bloc.close();
    signaling.dispose();
    run();
  }
}

void main() {
  setUpAll(() => debugPrint = (String? message, {int? wrapWidth}) {});
  tearDownAll(() => debugPrint = debugPrintThrottled);

  void onClock(void Function(_Harness h) body) {
    fakeAsync((time) {
      final harness = _Harness(time);
      body(harness);
      harness.dispose();
      expect(time.pendingTimers, isEmpty);
    });
  }

  group('the hold', () {
    test(
      'unknown support: a touch_hold, where it started, and nothing else',
      () {
        onClock((h) {
          h.ready();

          h.hold();

          expect(h.sent, const [
            RemoteTouchHoldCommand(id: 'hold-2', touch: 't-1', point: _start),
          ]);
          expect(h.longPresses, isEmpty);
          expect(h.status.isTouchActive, isTrue);
          expect(h.phase, RemoteTouchPhase.holding);
          expect(h.status.lastCommand, isNull);
          expect(h.status.isSettling, isFalse);
        });
      },
    );

    test('what it asks of the state is what a long press asks', () {
      onClock((h) {
        h.ready();
        h.bloc.add(
          const WebRtcRemotePictureChanged(
            remoteSessionId: _sessionId,
            isDisplayed: false,
          ),
        );
        h.run();

        h.hold();
        h.hold(sessionId: _otherSessionId);

        expect(h.sent, isEmpty);
        expect(h.status.isTouchActive, isFalse);
      });
    });

    test('not while a tap is unanswered', () {
      onClock((h) {
        h.ready();
        h.tap();

        h.hold();

        expect(h.types, ['tap']);
      });
    });

    test('its ok says the finger is held, and settles nothing', () {
      onClock((h) {
        h.ready();
        h.hold();

        h.ack('hold-2');

        expect(h.phase, RemoteTouchPhase.held);
        expect(h.status.isTouchActive, isTrue);
        expect(h.status.isSettling, isFalse);
      });
    });
  });

  group('capability', () {
    test('ok: supported, and the next hold is a touch_hold again', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.ack('hold-2');
        h.release(0.41, 0.52);
        final releaseId = h.releases.single.id;
        h.ack(releaseId);
        h.wait(400);

        h.hold(pointer: 8);

        expect(h.holds, hasLength(2));
        expect(h.longPresses, isEmpty);
      });
    });

    test('unsupported_command: exactly one long_press, where it started', () {
      onClock((h) {
        h.ready();
        h.hold();

        h.ack('hold-2', error: RemoteControlError.unsupportedCommand);

        expect(h.longPresses, const [
          RemoteLongPressCommand(id: 'long-3', point: _start),
        ]);
        expect(h.types, ['touch_hold', 'long_press']);
        expect(h.status.isTouchActive, isFalse);
        expect(h.status.lastTouch, isNull);
        expect(
          h.status.lastCommand,
          const RemoteCommandFeedback(
            commandId: 'long-3',
            kind: RemoteCommandKind.longPress,
            outcome: RemoteCommandOutcome.pending,
          ),
        );
      });
    });

    test('unsupported: the next hold is a long_press at once', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.ack('hold-2', error: RemoteControlError.unsupportedCommand);
        h.ack('long-3');
        h.wait(400);

        h.hold(pointer: 8, point: const NormalizedRemotePoint(0.2, 0.3));

        expect(h.holds, hasLength(1));
        expect(
          h.longPresses.last,
          const RemoteLongPressCommand(
            id: 'long-4',
            point: NormalizedRemotePoint(0.2, 0.3),
          ),
        );
        // A legacy long press is followed by nothing: no drag is simulated.
        h.move(0.6, 0.6, pointer: 8);
        h.release(0.6, 0.6, pointer: 8);
        h.wait(1000);
        expect(h.types, ['touch_hold', 'long_press', 'long_press']);
      });
    });

    test('moved while waiting: still the long_press where it started', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.move(0.6, 0.7);

        h.ack('hold-2', error: RemoteControlError.unsupportedCommand);
        // The old tablet refuses the move as well.
        h.ack(h.moves.single.id, error: RemoteControlError.unsupportedCommand);

        expect(h.longPresses.single.point, _start);
        expect(h.sent.whereType<RemoteSwipeCommand>(), isEmpty);
        expect(h.longPresses, hasLength(1));
      });
    });

    test('released while waiting: the hold was real, so the long_press', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.release(0.41, 0.52);
        expect(h.status.isSettling, isTrue);

        h.ack('hold-2', error: RemoteControlError.unsupportedCommand);

        expect(h.longPresses.single.point, _start);
      });
    });

    test('cancelled while waiting: no long_press', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.cancel();

        h.ack('hold-2', error: RemoteControlError.unsupportedCommand);
        h.ack(
          h.cancels.single.id,
          error: RemoteControlError.unsupportedCommand,
        );

        expect(h.longPresses, isEmpty);
        expect(h.status.isTouchActive, isFalse);
        // And the next hold no longer pays the round trip.
        h.hold(pointer: 8);
        expect(h.longPresses, hasLength(1));
      });
    });

    test('an answer after its touch ended still teaches', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.move(0.6, 0.7);
        // The move is refused before the hold is answered.
        h.ack(h.moves.single.id, error: RemoteControlError.touchEnded);
        expect(h.status.isTouchActive, isFalse);

        h.ack('hold-2', error: RemoteControlError.unsupportedCommand);

        expect(h.longPresses, isEmpty, reason: 'no fallback for a dead touch');
        h.hold(pointer: 8);
        expect(h.holds, hasLength(1));
        expect(h.longPresses, hasLength(1));
      });
    });

    for (final error in const [
      RemoteControlError.gestureRejected,
      RemoteControlError.accessibilityUnavailable,
      RemoteControlError.sessionNotActive,
      RemoteControlError.touchEnded,
      RemoteControlError.invalidCommand,
    ]) {
      test('${error.code} says nothing about support', () {
        onClock((h) {
          h.ready();
          h.hold();

          h.ack('hold-2', error: error);

          expect(h.status.isTouchActive, isFalse);
          expect(h.phase, RemoteTouchPhase.failed);
          expect(h.longPresses, isEmpty);
          h.hold(pointer: 8);
          expect(h.holds, hasLength(2));
        });
      });
    }

    test('a timeout says nothing about support either', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.release(0.41, 0.52);
        h.wait(9000);
        expect(h.status.isTouchActive, isFalse);
        h.wait(400);

        h.hold(pointer: 8);

        expect(h.holds, hasLength(2));
        expect(h.longPresses, isEmpty);
      });
    });

    void learnUnsupported(_Harness h) {
      h.hold();
      h.ack('hold-2', error: RemoteControlError.unsupportedCommand);
      h.ack('long-3');
      h.wait(400);
    }

    test('forgotten with the RemoteSession', () {
      onClock((h) {
        h.ready();
        learnUnsupported(h);
        h.bloc.add(const WebRtcRemoteSessionActivityChanged(null));
        h.run();
        h.bloc.add(const WebRtcRemoteSessionActivityChanged(_sessionId));
        h.run();

        h.hold(pointer: 8);

        expect(h.holds, hasLength(2));
      });
    });

    test('forgotten with the channel', () {
      onClock((h) {
        h.ready();
        learnUnsupported(h);
        h.peers.last
          ..emitControlChannelState(WebRtcDataChannelState.closed)
          ..emitControlChannelState(WebRtcDataChannelState.open);
        h.run();

        h.hold(pointer: 8);

        expect(h.holds, hasLength(2));
      });
    });

    test('forgotten with the peer connection and its generation', () {
      onClock((h) {
        h.ready();
        learnUnsupported(h);
        h.peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
        h.run();
        h.ready();
        expect(h.peers.sessions, hasLength(2));

        h.hold(pointer: 8);

        expect(h.holds.single.id, isNot('hold-2'));
        expect(h.longPresses, isEmpty);
      });
    });
  });

  group('keepalive', () {
    test('250 ms after the hold, unanswered: a same-point move, seq 1', () {
      onClock((h) {
        h.ready();
        h.hold();

        h.wait(249);
        expect(h.moves, isEmpty);
        h.wait(1);

        expect(h.moves, const [
          RemoteTouchMoveCommand(
            id: 'mv-3',
            touch: 't-1',
            seq: 1,
            point: _start,
          ),
        ]);

        h.wait(250);
        expect(h.moves.map((m) => m.seq), [1, 2]);
        expect(h.moves.last.point, _start);
      });
    });

    test('held still for seconds: one every 250 ms, and only one timer', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.ack('hold-2');

        for (var i = 0; i < 12; i++) {
          h.wait(250);
          expect(h.time.pendingTimers.length, lessThanOrEqualTo(4));
        }

        expect(h.moves, hasLength(12));
        expect(h.moves.every((m) => m.point == _start), isTrue);
        expect(h.moves.map((m) => m.seq), List.generate(12, (i) => i + 1));
      });
    });

    test('a real move resets it', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.wait(200);
        h.move(0.5, 0.5);
        expect(h.moves, hasLength(1));

        h.wait(200);
        expect(h.moves, hasLength(1));
        h.wait(50);
        expect(h.moves, hasLength(2));
        expect(h.moves.last.point, const NormalizedRemotePoint(0.5, 0.5));
      });
    });

    test('stops at the release', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.wait(250);
        h.release(0.41, 0.52);

        h.wait(3000);

        expect(h.moves, hasLength(1));
      });
    });
  });

  group('moves', () {
    test('before the hold is answered: sent', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.wait(100);

        h.move(0.43, 0.55);

        expect(h.moves, const [
          RemoteTouchMoveCommand(
            id: 'mv-3',
            touch: 't-1',
            seq: 1,
            point: NormalizedRemotePoint(0.43, 0.55),
          ),
        ]);
        expect(h.phase, RemoteTouchPhase.dragging);
      });
    });

    test('at most about 30 a second, whatever the browser sends', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.ack('hold-2');

        // 200 pointer moves a second, for a second, all of them far apart.
        for (var i = 1; i <= 200; i++) {
          h.time.elapse(const Duration(milliseconds: 5));
          h.move(0.1 + i * 0.004, 0.5);
        }

        expect(h.moves.length, inInclusiveRange(28, 31));
        // The last one still went out: latest point wins.
        h.wait(50);
        expect(h.moves.last.point.x, closeTo(0.1 + 200 * 0.004, 1e-9));
      });
    });

    test('a move under 0.002 waits, and the keepalive carries it', () {
      onClock((h) {
        h.ready();
        h.hold();

        h.move(0.4105, 0.5205);
        h.wait(100);
        h.move(0.411, 0.521);
        h.wait(100);

        expect(h.moves, isEmpty);
        h.wait(50);
        expect(h.moves.single.point, const NormalizedRemotePoint(0.411, 0.521));
      });
    });

    test('moves between two windows: only the last one goes out', () {
      onClock((h) {
        h.ready();
        h.hold();

        h.move(0.45, 0.52);
        expect(h.moves, hasLength(1));
        h.time.elapse(const Duration(milliseconds: 5));
        h.move(0.46, 0.52);
        h.time.elapse(const Duration(milliseconds: 5));
        h.move(0.47, 0.52);
        h.time.elapse(const Duration(milliseconds: 5));
        h.move(0.48, 0.52);
        expect(h.moves, hasLength(1));

        h.wait(33);

        expect(h.moves.map((m) => m.point.x), [0.45, 0.48]);
        expect(h.moves.map((m) => m.seq), [1, 2]);
      });
    });

    test('another pointer moves nothing', () {
      onClock((h) {
        h.ready();
        h.hold();

        h.move(0.8, 0.8, pointer: 99);

        expect(h.moves, isEmpty);
      });
    });
  });

  group('seq and ids', () {
    test('every move, keepalive, release and cancel takes the next seq', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.wait(250); // keepalive 1
        h.wait(40); // out of its throttling window
        h.move(0.6, 0.6); // 2
        h.wait(250); // keepalive 3
        h.release(0.7, 0.7); // 4

        expect(h.seqs, [1, 2, 3, 4]);
        expect(h.ids.toSet(), hasLength(h.ids.length));
        for (final command in h.sent.skip(1)) {
          expect(command, isNot(isA<RemoteTouchHoldCommand>()));
        }
        expect(h.sent.map((c) => c.id.split('-').first), [
          'hold',
          'mv',
          'mv',
          'mv',
          'rel',
        ]);
      });
    });

    test('a cancel takes the next seq too', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.wait(250);
        h.wait(40);
        h.move(0.6, 0.6);

        h.cancel();

        expect(h.seqs, [1, 2, 3]);
        expect(
          h.cancels.single,
          const RemoteTouchCancelCommand(id: 'cxl-5', touch: 't-1', seq: 3),
        );
      });
    });

    test('every message names the same touch', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.move(0.6, 0.6);
        h.release(0.7, 0.7);

        expect(h.holds.single.touch, 't-1');
        expect(h.moves.single.touch, 't-1');
        expect(h.releases.single.touch, 't-1');
      });
    });
  });

  group('a move refused', () {
    test('touch_ended: the touch is over, and nothing is retried', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.ack('hold-2');
        h.move(0.6, 0.6);

        h.ack(h.moves.single.id, error: RemoteControlError.touchEnded);

        expect(h.status.isTouchActive, isFalse);
        expect(h.status.lastTouch?.failure, RemoteCommandOutcome.touchEnded);
        final count = h.sent.length;
        h.move(0.7, 0.7);
        h.wait(3000);
        h.release(0.7, 0.7);
        expect(h.sent, hasLength(count));
        expect(h.holds, hasLength(1));

        // Everything else is available again.
        expect(h.bloc.state.canSendRemoteLongPress, isTrue);
        h.tap();
        expect(h.sent.last, isA<RemoteTapCommand>());
      });
    });

    test('later refusals of the same touch change nothing', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.move(0.6, 0.6);
        h.wait(250);
        final first = h.moves.first.id;
        final second = h.moves.last.id;

        h.ack(first, error: RemoteControlError.touchEnded);
        h.tap();
        h.ack(second, error: RemoteControlError.touchEnded);

        expect(h.status.lastCommand?.kind, RemoteCommandKind.tap);
        expect(h.status.lastCommand?.outcome, RemoteCommandOutcome.pending);
      });
    });
  });

  group('the release', () {
    test('before the hold is answered: one release, no tap, no long_press', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.wait(100);

        h.release(0.6, 0.7);

        expect(h.releases, const [
          RemoteTouchReleaseCommand(
            id: 'rel-3',
            touch: 't-1',
            seq: 1,
            point: NormalizedRemotePoint(0.6, 0.7),
          ),
        ]);
        expect(h.sent.whereType<RemoteTapCommand>(), isEmpty);
        expect(h.longPresses, isEmpty);
        expect(h.phase, RemoteTouchPhase.releasing);
        expect(h.status.isTouchActive, isTrue);
      });
    });

    test('the touch lives until its answer, whichever comes first', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.release(0.6, 0.7);

        h.ack('hold-2');
        expect(h.status.isTouchActive, isTrue);
        expect(h.phase, RemoteTouchPhase.releasing);
        h.release(0.6, 0.7);
        expect(h.releases, hasLength(1));

        h.ack('rel-3');
        expect(h.status.isTouchActive, isFalse);
        expect(h.phase, RemoteTouchPhase.released);
      });
    });

    test('nothing moves after it', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.release(0.6, 0.7);

        h.move(0.8, 0.8);
        h.wait(2000);

        expect(h.moves, isEmpty);
      });
    });

    test('touch_ended: over, no retry', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.release(0.6, 0.7);

        h.ack('rel-3', error: RemoteControlError.touchEnded);

        expect(h.status.isTouchActive, isFalse);
        expect(h.status.isSettling, isFalse);
        expect(h.status.lastTouch?.failure, RemoteCommandOutcome.touchEnded);
        h.wait(10000);
        expect(h.releases, hasLength(1));
      });
    });

    test('no answer: given up after the deadline, never resent', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.release(0.6, 0.7);

        h.wait(7999);
        expect(h.status.isTouchActive, isTrue);
        h.wait(1);

        expect(h.status.isTouchActive, isFalse);
        expect(h.status.isSettling, isFalse);
        expect(h.status.lastTouch?.failure, RemoteCommandOutcome.timedOut);
        expect(h.releases, hasLength(1));
      });
    });
  });

  group('the cancel', () {
    test('one cancel, without coordinates, and nothing after it', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.ack('hold-2');

        h.cancel();
        h.cancel();

        expect(h.cancels, const [
          RemoteTouchCancelCommand(id: 'cxl-3', touch: 't-1', seq: 1),
        ]);
        expect(h.phase, RemoteTouchPhase.cancelling);
        h.wait(2000);
        expect(h.moves, isEmpty);
        h.release(0.5, 0.5);
        expect(h.releases, isEmpty);
      });
    });

    test('its answer ends the touch, without settling', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.cancel();

        h.ack('cxl-3');

        expect(h.status.isTouchActive, isFalse);
        expect(h.status.isSettling, isFalse);
        expect(h.phase, RemoteTouchPhase.cancelled);
        h.tap();
        expect(h.sent.last, isA<RemoteTapCommand>());
      });
    });

    test('the hold refused after a cancel: the cancel still ends it', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.cancel();

        h.ack('hold-2', error: RemoteControlError.touchEnded);
        expect(h.status.isTouchActive, isTrue);
        h.ack('cxl-3');

        expect(h.phase, RemoteTouchPhase.cancelled);
      });
    });

    test('unanswered: given up after the deadline', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.cancel();

        h.wait(8000);

        expect(h.status.isTouchActive, isFalse);
        expect(h.phase, RemoteTouchPhase.cancelled);
      });
    });

    test('the picture going away cancels it', () {
      onClock((h) {
        h.ready();
        h.hold();

        h.bloc.add(
          const WebRtcRemotePictureChanged(
            remoteSessionId: _sessionId,
            isDisplayed: false,
          ),
        );
        h.run();

        expect(h.cancels, hasLength(1));
      });
    });
  });

  group('the 30 seconds', () {
    test('a cancel at 30 s, and no keepalive after it', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.ack('hold-2');

        h.wait(29999);
        expect(h.cancels, isEmpty);
        final moves = h.moves.length;
        h.wait(1);

        expect(h.cancels, hasLength(1));
        h.wait(5000);
        expect(h.moves, hasLength(moves));
      });
    });
  });

  group('nothing else while it lasts', () {
    test('no tap, swipe, long press, navigation, text, action or touch', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.ack('hold-2');

        h.tap();
        h.bloc
          ..add(
            const WebRtcRemoteSwipeRequested(
              remoteSessionId: _sessionId,
              start: NormalizedRemotePoint(0.5, 0.8),
              end: NormalizedRemotePoint(0.5, 0.2),
              durationMs: 300,
            ),
          )
          ..add(
            const WebRtcRemoteLongPressRequested(
              remoteSessionId: _sessionId,
              point: _start,
            ),
          )
          ..add(const WebRtcRemoteBackRequested(remoteSessionId: _sessionId))
          ..add(const WebRtcRemoteHomeRequested(remoteSessionId: _sessionId))
          ..add(const WebRtcRemoteRecentsRequested(remoteSessionId: _sessionId))
          ..add(
            const WebRtcRemoteTextRequested(
              remoteSessionId: _sessionId,
              text: 'x',
            ),
          )
          ..add(
            const WebRtcRemoteImeEnterRequested(remoteSessionId: _sessionId),
          );
        h.run();
        h.hold(pointer: 8);

        expect(h.types, ['touch_hold']);
        expect(h.bloc.state.canSendRemoteText, isFalse);
        expect(h.bloc.state.canSendRemoteImeEnter, isFalse);
        expect(h.bloc.state.canSendRemoteLongPress, isFalse);
        // Not a pending command: the touch is its own kind of pending.
        expect(h.status.pendingCommands, 0);
        // Nor does it take the picture away from the surface following it.
        expect(h.bloc.state.canSendRemoteControl, isTrue);
      });
    });
  });

  group('FINALIZAR and the ways out', () {
    test('FINALIZAR: a best-effort cancel, and the touch is gone at once', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.move(0.6, 0.6);

        h.bloc.add(const WebRtcRemoteSessionActivityChanged(null));
        h.run();

        expect(h.cancels, hasLength(1));
        expect(h.cancels.single.seq, 2);
        expect(h.status.isTouchActive, isFalse);
        final count = h.sent.length;
        h.wait(40000);
        expect(h.sent, hasLength(count));
      });
    });

    test('the assistance terminated: a best-effort cancel, nothing after', () {
      onClock((h) {
        h.ready();
        h.hold();
        final session = h.peers.last;

        h.bloc.add(const WebRtcSessionTerminated());
        h.run();

        expect(
          session.sentRemoteControlCommands.last,
          isA<RemoteTouchCancelCommand>(),
        );
        h.wait(40000);
        expect(session.sentRemoteControlCommands, hasLength(2));
      });
    });

    test('the channel closed: no cancel, nothing left', () {
      onClock((h) {
        h.ready();
        h.hold();

        h.peers.last.emitControlChannelState(WebRtcDataChannelState.closed);
        h.run();

        expect(h.cancels, isEmpty);
        expect(h.status.isTouchActive, isFalse);
        expect(h.status.lastTouch?.failure, RemoteCommandOutcome.channelClosed);
        h.wait(40000);
        expect(h.types, ['touch_hold']);
      });
    });

    test('the peer connection failed: no cancel, nothing left', () {
      onClock((h) {
        h.ready();
        h.hold();
        final session = h.peers.last;

        session.emitPeerState(WebRtcPeerConnectionState.failed);
        h.run();
        h.wait(40000);

        expect(session.sentRemoteControlCommands, hasLength(1));
        expect(h.bloc.state, isA<WebRtcFailed>());
      });
    });

    test('a new generation: the old touch is gone, its timers too', () {
      onClock((h) {
        h.ready();
        h.hold();
        final first = h.peers.last;

        h.ready(sessionId: _otherSessionId);
        h.wait(40000);

        expect(
          first.sentRemoteControlCommands.last,
          isA<RemoteTouchCancelCommand>(),
        );
        expect(first.sentRemoteControlCommands, hasLength(2));
        // Releasing a peer connection does not finish under this fake clock
        // (a broadcast subscription's cancel completes in the root zone), so
        // what is checked is what the old touch did and did not send.
        expect(first.sentRemoteControlCommands.map((c) => c.kind.logName), [
          'touch_hold',
          'touch_cancel',
        ]);
      });
    });

    test('a late answer from a replaced peer connection changes nothing', () {
      onClock((h) {
        h.ready();
        h.hold();
        final first = h.peers.last;
        h.ready(sessionId: _otherSessionId);

        first.emitRemoteControlAck('hold-2');
        h.run();

        expect(h.status.isTouchActive, isFalse);
        expect(h.status.lastTouch, isNull);
      });
    });
  });

  group('settle guard', () {
    test('the release settles: until its answer and at least 350 ms', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.ack('hold-2');
        h.release(0.5, 0.5);
        expect(h.status.isSettling, isTrue);

        h.wait(100);
        h.ack('rel-3');
        expect(h.status.isTouchActive, isFalse);
        expect(h.status.isSettling, isTrue);
        h.wait(249);
        expect(h.status.isSettling, isTrue);
        h.wait(1);
        expect(h.status.isSettling, isFalse);
      });
    });

    test('a release answered after 350 ms ends the settling there', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.release(0.5, 0.5);
        h.wait(1200);
        expect(h.status.isSettling, isTrue);

        h.ack('rel-3');

        expect(h.status.isSettling, isFalse);
        expect(h.phase, RemoteTouchPhase.released);
      });
    });

    test('keepalives and moves are never held back while the touch lasts', () {
      onClock((h) {
        h.ready();
        h.hold();
        h.ack('hold-2');
        h.wait(250);
        h.wait(40);
        h.move(0.7, 0.7);

        expect(h.moves, hasLength(2));
        expect(h.status.isSettling, isFalse);
      });
    });
  });

  group('what the technician reads', () {
    test('holding, held, dragging, releasing, released', () {
      onClock((h) {
        h.ready();
        h.hold();
        expect(h.phase, RemoteTouchPhase.holding);
        h.ack('hold-2');
        expect(h.phase, RemoteTouchPhase.held);
        h.wait(250);
        expect(
          h.phase,
          RemoteTouchPhase.held,
          reason: 'a keepalive is no drag',
        );
        h.wait(40);
        h.move(0.7, 0.7);
        expect(h.phase, RemoteTouchPhase.dragging);
        h.release(0.7, 0.7);
        expect(h.phase, RemoteTouchPhase.releasing);
        h.ack(h.releases.single.id);
        expect(
          h.status.lastTouch,
          const RemoteTouchFeedback(
            touchId: 't-1',
            phase: RemoteTouchPhase.released,
            hasMoved: true,
          ),
        );
      });
    });
  });
}
