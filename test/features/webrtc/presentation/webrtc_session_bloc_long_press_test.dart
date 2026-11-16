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
const _point = NormalizedRemotePoint(0.5, 0.25);

/// A BLoC on a clock the test moves.
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

  void wait(int milliseconds) =>
      time.elapse(Duration(milliseconds: milliseconds));

  void negotiate() {
    bloc.add(const WebRtcNegotiationRequested(_sessionId));
    run();
  }

  /// Connected, `control` open and `ACTIVE`, and nothing about video.
  void readyWithoutVideo() {
    negotiate();
    peers.last
      ..emitControlChannelState(WebRtcDataChannelState.open)
      ..emitPeerState(WebRtcPeerConnectionState.connected);
    bloc.add(const WebRtcRemoteSessionActivityChanged(_sessionId));
    run();
  }

  void picture({bool isDisplayed = true}) {
    bloc.add(
      WebRtcRemotePictureChanged(
        remoteSessionId: _sessionId,
        isDisplayed: isDisplayed,
      ),
    );
    run();
  }

  /// Everything a long press asks for.
  void ready() {
    readyWithoutVideo();
    peers.last.emitRemoteVideoTrack();
    run();
    picture();
  }

  void longPress({String id = _sessionId}) {
    bloc.add(
      WebRtcRemoteLongPressRequested(remoteSessionId: id, point: _point),
    );
    run();
  }

  void tap() {
    bloc.add(
      const WebRtcRemoteTapRequested(
        remoteSessionId: _sessionId,
        point: _point,
      ),
    );
    run();
  }

  void swipe() {
    bloc.add(
      const WebRtcRemoteSwipeRequested(
        remoteSessionId: _sessionId,
        start: NormalizedRemotePoint(0.5, 0.8),
        end: NormalizedRemotePoint(0.5, 0.2),
        durationMs: 350,
      ),
    );
    run();
  }

  void back() {
    bloc.add(const WebRtcRemoteBackRequested(remoteSessionId: _sessionId));
    run();
  }

  void home() {
    bloc.add(const WebRtcRemoteHomeRequested(remoteSessionId: _sessionId));
    run();
  }

  void recents() {
    bloc.add(const WebRtcRemoteRecentsRequested(remoteSessionId: _sessionId));
    run();
  }

  void text(String text) {
    bloc.add(
      WebRtcRemoteTextRequested(remoteSessionId: _sessionId, text: text),
    );
    run();
  }

  void imeEnter() {
    bloc.add(const WebRtcRemoteImeEnterRequested(remoteSessionId: _sessionId));
    run();
  }

  void ack(String id, {RemoteControlError? error}) {
    peers.last.emitRemoteControlAck(id, error: error);
    run();
  }

  RemoteControlStatus get status => bloc.state.remoteControl;
  bool get canSend => bloc.state.canSendRemoteLongPress;
  RemoteCommandOutcome? get outcome => status.lastCommand?.outcome;
  List<String> get sent =>
      peers.last.sentRemoteControlCommands.map((c) => c.id).toList();
  List<RemoteLongPressCommand> get longPresses => peers
      .last
      .sentRemoteControlCommands
      .whereType<RemoteLongPressCommand>()
      .toList();

  void dispose() {
    bloc.close();
    signaling.dispose();
    run();
  }
}

void main() {
  setUpAll(() => debugPrint = (String? message, {int? wrapWidth}) {});
  tearDownAll(() => debugPrint = debugPrintThrottled);

  void onClock(void Function(_Harness harness) body) {
    fakeAsync((time) {
      final harness = _Harness(time);
      body(harness);
      harness.dispose();
      expect(time.pendingTimers, isEmpty);
    });
  }

  group('what it takes to send', () {
    test('all of it: the long press goes out, where it started', () {
      onClock((h) {
        h.ready();
        expect(h.canSend, isTrue);

        h.longPress();

        expect(h.peers.last.sentRemoteControlCommands, const [
          RemoteLongPressCommand(id: 'long-1', point: _point),
        ]);
        expect(
          h.status.lastCommand,
          const RemoteCommandFeedback(
            commandId: 'long-1',
            kind: RemoteCommandKind.longPress,
            outcome: RemoteCommandOutcome.pending,
          ),
        );
      });
    });

    test('a session still CONNECTING', () {
      onClock((h) {
        h.negotiate();
        h.peers.last
          ..emitControlChannelState(WebRtcDataChannelState.open)
          ..emitPeerState(WebRtcPeerConnectionState.connected)
          ..emitRemoteVideoTrack();
        h.run();
        h.picture();

        expect(h.canSend, isFalse);
        h.longPress();
        expect(h.sent, isEmpty);
      });
    });

    test('a peer connection not connected', () {
      onClock((h) {
        h.negotiate();
        h.peers.last
          ..emitControlChannelState(WebRtcDataChannelState.open)
          ..emitRemoteVideoTrack();
        h.bloc.add(const WebRtcRemoteSessionActivityChanged(_sessionId));
        h.run();
        h.picture();

        expect(h.canSend, isFalse);
        h.longPress();
        expect(h.sent, isEmpty);
      });
    });

    test('a connection interrupted', () {
      onClock((h) {
        h.ready();
        h.peers.last.emitPeerState(WebRtcPeerConnectionState.disconnected);
        h.run();

        expect(h.canSend, isFalse);
        h.longPress();
        expect(h.sent, isEmpty);
      });
    });

    for (final channelState in const [
      WebRtcDataChannelState.connecting,
      WebRtcDataChannelState.closing,
      WebRtcDataChannelState.closed,
    ]) {
      test('a channel ${channelState.name}', () {
        onClock((h) {
          h.ready();
          h.peers.last.emitControlChannelState(channelState);
          h.run();

          expect(h.canSend, isFalse);
          h.longPress();
          expect(h.sent, isEmpty);
        });
      });
    }

    test('aimed at another session', () {
      onClock((h) {
        h.ready();

        h.longPress(id: _otherSessionId);

        expect(h.sent, isEmpty);
        expect(h.status.lastCommand, isNull);
      });
    });

    test('no negotiation at all', () {
      onClock((h) {
        h.longPress();

        expect(h.peers.sessions, isEmpty);
        expect(h.bloc.state, isA<WebRtcIdle>());
      });
    });
  });

  group('checked again when the hold is recognised', () {
    // The surface starts recognising when the pointer goes down and asks when the
    // timeout ends. Whatever changed in between decides.

    test('the session stopped being ACTIVE', () {
      onClock((h) {
        h.ready();
        h.bloc.add(const WebRtcRemoteSessionActivityChanged(null));
        h.run();

        expect(h.canSend, isFalse);
        h.longPress();
        expect(h.sent, isEmpty);
      });
    });

    test('the channel closed', () {
      onClock((h) {
        h.ready();
        h.peers.last.emitControlChannelState(WebRtcDataChannelState.closed);
        h.run();

        h.longPress();
        expect(h.sent, isEmpty);
      });
    });

    test('the peer connection failed', () {
      onClock((h) {
        h.ready();
        final failed = h.peers.last;
        failed.emitPeerState(WebRtcPeerConnectionState.failed);
        h.run();

        h.longPress();
        expect(failed.sentRemoteControlCommands, isEmpty);
      });
    });

    test('the picture went away', () {
      onClock((h) {
        h.ready();
        h.picture(isDisplayed: false);

        expect(h.bloc.state.canSendRemoteControl, isTrue);
        expect(h.canSend, isFalse);
        h.longPress();
        expect(h.sent, isEmpty);
      });
    });

    test('a track with no frames yet is not a picture', () {
      onClock((h) {
        h.readyWithoutVideo();
        h.peers.last.emitRemoteVideoTrack();
        h.run();

        expect(h.bloc.state.canSendRemoteControl, isTrue);
        expect(h.canSend, isFalse);
        h.longPress();
        expect(h.sent, isEmpty);
      });
    });

    test('the assistance ended (FINALIZAR)', () {
      onClock((h) {
        h.ready();
        final session = h.peers.last;
        h.bloc.add(const WebRtcSessionTerminated());
        h.run();

        h.longPress();
        h.wait(60000);
        expect(session.sentRemoteControlCommands, isEmpty);
      });
    });

    test('a newer negotiation replaced the one it was aimed at', () {
      onClock((h) {
        h.ready();
        final replaced = h.peers.last;
        replaced.emitPeerState(WebRtcPeerConnectionState.failed);
        h.run();
        h.negotiate();

        h.longPress();

        expect(replaced.sentRemoteControlCommands, isEmpty);
        expect(h.sent, isEmpty);
      });
    });

    for (final (name, send, id) in <(String, void Function(_Harness), String)>[
      ('a tap', (h) => h.tap(), 'tap-1'),
      ('a swipe', (h) => h.swipe(), 'swipe-1'),
      ('a text', (h) => h.text('wifi'), 'text-1'),
    ]) {
      test('$name became pending: dropped, not kept for later', () {
        onClock((h) {
          h.ready();
          send(h);

          expect(h.canSend, isFalse);
          h.longPress();
          expect(h.sent, [id]);

          h.ack(id);
          h.wait(60000);
          expect(h.longPresses, isEmpty);

          // The next hold, once nothing is ahead.
          h.longPress();
          expect(h.sent, [id, 'long-2']);
        });
      });
    }

    for (final (name, press, id) in <(String, void Function(_Harness), String)>[
      ('Back', (h) => h.back(), 'back-1'),
      ('Home', (h) => h.home(), 'home-1'),
      ('Recents', (h) => h.recents(), 'recents-1'),
      ('Acción', (h) => h.imeEnter(), 'enter-1'),
    ]) {
      test('the guard of $name became active: dropped', () {
        onClock((h) {
          h.ready();
          press(h);
          h.ack(id);
          expect(h.status.isSettling, isTrue);

          expect(h.canSend, isFalse);
          h.longPress();
          expect(h.sent, [id]);

          h.wait(350);
          expect(h.canSend, isTrue);
          h.wait(60000);
          expect(h.longPresses, isEmpty);
        });
      });
    }
  });

  group('once sent', () {
    void expectNothingElseGoesOut(_Harness h) {
      h.tap();
      h.swipe();
      h.longPress();
      h.back();
      h.home();
      h.recents();
      h.text('Otro');
      h.imeEnter();

      expect(h.sent, ['long-1']);
    }

    test('nothing else goes out while it is unanswered', () {
      onClock((h) {
        h.ready();
        h.longPress();

        expect(h.status.pendingCommands, 1);
        expect(h.status.isSettling, isTrue);
        expect(h.canSend, isFalse);
        expect(h.bloc.state.canSendRemoteNavigation, isTrue);
        expectNothingElseGoesOut(h);
      });
    });

    test('FINALIZAR still works, and nothing goes out later', () {
      // Only what happens before the peer connection is awaited: closing it waits
      // on a future of the root zone, which this clock does not drive. The widget
      // tests of FINALIZAR cover the rest.
      onClock((h) {
        h.ready();
        h.longPress();
        final session = h.peers.last;

        h.bloc.add(const WebRtcSessionTerminated());
        h.run();

        expect(h.time.pendingTimers, isEmpty);
        session.emitRemoteControlAck('long-1');
        h.run();
        h.longPress();
        h.tap();
        h.wait(60000);
        expect(session.sentRemoteControlCommands, hasLength(1));
      });
    });

    test('an answer at 700 ms gives control back there and then', () {
      // The guard keeps its own semantics: answered AND 350 ms after it was sent.
      // A long press is answered once Android completed it, well after that.
      onClock((h) {
        h.ready();
        h.longPress();

        h.wait(699);
        expect(h.status.isSettling, isTrue);
        expectNothingElseGoesOut(h);

        h.wait(1);
        h.ack('long-1');

        // The text tried while it was held back reported itself as not sent, and
        // took text-2 with it.
        expect(h.status.lastCommand?.kind, RemoteCommandKind.setText);
        expect(h.status.pendingCommands, 0);
        expect(h.status.isSettling, isFalse);
        expect(h.canSend, isTrue);
        expect(h.time.pendingTimers, isEmpty);

        h.tap();
        expect(h.sent, ['long-1', 'tap-3']);
      });
    });

    test('an answer before 350 ms still waits for it, like any settle', () {
      onClock((h) {
        h.ready();
        h.longPress();

        h.wait(100);
        h.ack('long-1');
        expect(h.outcome, RemoteCommandOutcome.confirmed);
        expect(h.status.isSettling, isTrue);
        expectNothingElseGoesOut(h);

        h.wait(250);
        expect(h.status.isSettling, isFalse);
        expect(h.canSend, isTrue);
      });
    });

    test('nothing dropped comes back afterwards', () {
      onClock((h) {
        h.ready();
        h.longPress();
        expectNothingElseGoesOut(h);

        h.ack('long-1');
        h.wait(20000);

        expect(h.peers.last.sentRemoteControlCommands, hasLength(1));
      });
    });

    test('it stops nothing else: the video keeps coming', () {
      onClock((h) {
        h.ready();
        h.longPress();
        final session = h.peers.last;

        final track = session.emitRemoteVideoTrack('another');
        h.run();

        expect(h.bloc.state.remoteVideoTrack, track);
        expect(h.bloc.state, isA<WebRtcConnected>());
        expect(session.isClosed, isFalse);
      });
    });
  });

  group('the answer', () {
    test('only its own answer resolves it', () {
      onClock((h) {
        h.ready();
        h.longPress();

        h.ack('long-999');
        expect(h.outcome, RemoteCommandOutcome.pending);
        expect(h.status.isSettling, isTrue);

        h.ack('long-1');
        expect(h.outcome, RemoteCommandOutcome.confirmed);

        h.ack('long-1', error: RemoteControlError.gestureRejected);
        expect(h.outcome, RemoteCommandOutcome.confirmed);
      });
    });

    const refusals = {
      RemoteControlError.gestureRejected: RemoteCommandOutcome.gestureRejected,
      RemoteControlError.accessibilityUnavailable:
          RemoteCommandOutcome.accessibilityUnavailable,
      RemoteControlError.sessionNotActive:
          RemoteCommandOutcome.sessionNotActive,
      RemoteControlError.invalidCommand: RemoteCommandOutcome.incompatible,
      RemoteControlError.unsupportedCommand: RemoteCommandOutcome.incompatible,
      RemoteControlError.unknown: RemoteCommandOutcome.incompatible,
    };

    refusals.forEach((error, outcome) {
      test('${error.code} frees the control at once and repeats nothing', () {
        onClock((h) {
          h.ready();
          h.longPress();
          h.wait(600);

          h.ack('long-1', error: error);

          expect(h.outcome, outcome);
          expect(h.status.isSettling, isFalse);
          expect(h.canSend, isTrue);
          expect(h.peers.last.isClosed, isFalse);
          expect(h.bloc.state, isA<WebRtcConnected>());

          h.tap();
          expect(h.sent, ['long-1', 'tap-2']);

          h.wait(60000);
          expect(h.longPresses, hasLength(1));
        });
      });
    });

    test('a channel that refuses the message frees it at once', () {
      onClock((h) {
        h.ready();
        h.peers.last.acceptsRemoteControlCommands = false;

        h.longPress();

        expect(h.status.pendingCommands, 0);
        expect(h.status.isSettling, isFalse);
        expect(h.outcome, RemoteCommandOutcome.notSent);
        expect(h.canSend, isTrue);
        expect(h.time.pendingTimers, isEmpty);
      });
    });

    test(
      'the channel closing frees it, and nothing waits for the deadline',
      () {
        onClock((h) {
          h.ready();
          h.longPress();

          h.peers.last.emitControlChannelState(WebRtcDataChannelState.closed);
          h.run();

          expect(h.status.isSettling, isFalse);
          expect(h.status.pendingCommands, 0);
          expect(h.outcome, RemoteCommandOutcome.channelClosed);
          expect(h.time.pendingTimers, isEmpty);
        });
      },
    );

    test('the peer connection failing frees it', () {
      onClock((h) {
        h.ready();
        h.longPress();

        h.peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
        h.run();

        expect(h.bloc.state, isA<WebRtcFailed>());
        expect(h.bloc.state.remoteControl, const RemoteControlStatus());
        expect(h.time.pendingTimers, isEmpty);
      });
    });

    test('the session closing frees it', () {
      onClock((h) {
        h.ready();
        h.longPress();

        h.bloc.add(const WebRtcRemoteSessionActivityChanged(null));
        h.run();

        expect(h.status.pendingCommands, 0);
        expect(h.status.isSettling, isFalse);
        expect(h.status.lastCommand, isNull);
        expect(h.time.pendingTimers, isEmpty);
      });
    });

    test('a replaced peer connection cannot answer the new one', () {
      onClock((h) {
        h.ready();
        final replaced = h.peers.last;
        h.longPress();
        replaced.emitPeerState(WebRtcPeerConnectionState.failed);
        h.run();

        h.ready();
        h.longPress();
        expect(h.sent, ['long-2']);

        replaced.emitRemoteControlAck('long-2');
        h.run();
        h.wait(400);

        expect(h.outcome, RemoteCommandOutcome.pending);
        expect(h.status.isSettling, isTrue);
      });
    });
  });

  group('timeout', () {
    test('five seconds of work and the margin: eight seconds', () {
      onClock((h) {
        h.ready();
        h.longPress();

        h.wait(7999);
        expect(h.outcome, RemoteCommandOutcome.pending);
        expect(h.status.isSettling, isTrue);

        h.wait(1);
        expect(h.outcome, RemoteCommandOutcome.timedOut);
        expect(h.status.isSettling, isFalse);
        expect(h.status.pendingCommands, 0);
        expect(h.canSend, isTrue);
        expect(h.time.pendingTimers, isEmpty);
      });
    });

    test('an answer after it changes nothing', () {
      onClock((h) {
        h.ready();
        h.longPress();
        h.wait(8000);

        h.ack('long-1');

        expect(h.outcome, RemoteCommandOutcome.timedOut);
        expect(h.status.isSettling, isFalse);
      });
    });

    test('it is never sent again: the gesture may have run', () {
      onClock((h) {
        h.ready();
        h.longPress();

        h.wait(60000);

        expect(h.sent, ['long-1']);
      });
    });
  });

  group('ids', () {
    test('it shares one sequence with everything else', () {
      onClock((h) {
        h.ready();

        h.tap();
        h.ack('tap-1');
        h.swipe();
        h.ack('swipe-2');
        h.longPress();
        h.wait(600);
        h.ack('long-3');
        h.home();

        expect(h.sent, ['tap-1', 'swipe-2', 'long-3', 'home-4']);
      });
    });
  });

  group('the log', () {
    test('has the ids and the codes, never the point', () {
      final printed = <String>[];
      debugPrint = (String? message, {int? wrapWidth}) {
        printed.add(message ?? '');
      };
      addTearDown(() => debugPrint = (String? message, {int? wrapWidth}) {});

      onClock((h) {
        h.ready();

        h.longPress();
        h.wait(600);
        h.ack('long-1');
        h.longPress();
        h.ack('long-2', error: RemoteControlError.gestureRejected);
        h.longPress();
        h.wait(8000);
      });

      expect(
        printed,
        containsAll([
          contains('long_press command sent long-1'),
          contains('long_press confirmed long-1'),
          contains('long_press rejected long-2: gesture_rejected'),
          contains('long_press timed out long-3'),
        ]),
      );
      expect(printed.where((line) => line.contains('0.25')), isEmpty);
    });
  });
}
