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

  void picture({bool isDisplayed = true, String id = _sessionId}) {
    bloc.add(
      WebRtcRemotePictureChanged(remoteSessionId: id, isDisplayed: isDisplayed),
    );
    run();
  }

  /// Everything the IME action asks for.
  void ready() {
    readyWithoutVideo();
    peers.last.emitRemoteVideoTrack();
    run();
    picture();
  }

  void imeEnter({String id = _sessionId}) {
    bloc.add(WebRtcRemoteImeEnterRequested(remoteSessionId: id));
    run();
  }

  void text(String text) {
    bloc.add(
      WebRtcRemoteTextRequested(remoteSessionId: _sessionId, text: text),
    );
    run();
  }

  void tap() {
    bloc.add(
      const WebRtcRemoteTapRequested(
        remoteSessionId: _sessionId,
        point: NormalizedRemotePoint(0.5, 0.5),
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

  void ack(String id, {RemoteControlError? error}) {
    peers.last.emitRemoteControlAck(id, error: error);
    run();
  }

  RemoteControlStatus get status => bloc.state.remoteControl;
  bool get canSend => bloc.state.canSendRemoteImeEnter;
  RemoteCommandOutcome? get outcome => status.lastCommand?.outcome;
  List<String> get sent =>
      peers.last.sentRemoteControlCommands.map((c) => c.id).toList();
  List<RemoteControlCommand> get imeEnters => peers
      .last
      .sentRemoteControlCommands
      .whereType<RemoteImeEnterCommand>()
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
    test('all of it: the action goes out, with its id and nothing else', () {
      onClock((h) {
        h.ready();
        expect(h.canSend, isTrue);

        h.imeEnter();

        expect(h.peers.last.sentRemoteControlCommands, const [
          RemoteImeEnterCommand(id: 'enter-1'),
        ]);
        expect(
          h.status.lastCommand,
          const RemoteCommandFeedback(
            commandId: 'enter-1',
            kind: RemoteCommandKind.imeEnter,
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
        h.imeEnter();
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
        h.imeEnter();
        expect(h.sent, isEmpty);
      });
    });

    test('a connection interrupted', () {
      onClock((h) {
        h.ready();
        h.peers.last.emitPeerState(WebRtcPeerConnectionState.disconnected);
        h.run();

        expect(h.canSend, isFalse);
        h.imeEnter();
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
          h.imeEnter();
          expect(h.sent, isEmpty);
        });
      });
    }

    test('the session being closed', () {
      onClock((h) {
        h.ready();
        h.bloc.add(const WebRtcRemoteSessionActivityChanged(null));
        h.run();

        expect(h.canSend, isFalse);
        h.imeEnter();
        expect(h.sent, isEmpty);
      });
    });

    test('aimed at another session', () {
      onClock((h) {
        h.ready();

        h.imeEnter(id: _otherSessionId);

        expect(h.sent, isEmpty);
        expect(h.status.lastCommand, isNull);
      });
    });

    test('no negotiation at all', () {
      onClock((h) {
        h.imeEnter();

        expect(h.peers.sessions, isEmpty);
        expect(h.bloc.state, isA<WebRtcIdle>());
      });
    });
  });

  group('the picture', () {
    test('no video at all: Back goes out, the action does not', () {
      // Android would run it: refusing is the web's decision, because the picture
      // is the only way the technician has to check which field has focus.
      onClock((h) {
        h.readyWithoutVideo();

        expect(h.bloc.state.canSendRemoteNavigation, isTrue);
        expect(h.canSend, isFalse);

        h.imeEnter();
        expect(h.sent, isEmpty);

        // A refused request takes no id.
        h.back();
        expect(h.sent, ['back-1']);
        h.ack('back-1');
        h.wait(350);
        h.recents();
        expect(h.sent, ['back-1', 'recents-2']);
      });
    });

    test('a track with no frames yet is not a picture', () {
      onClock((h) {
        h.readyWithoutVideo();
        h.peers.last.emitRemoteVideoTrack();
        h.run();

        expect(h.bloc.state.canSendRemoteControl, isTrue);
        expect(h.canSend, isFalse);

        h.imeEnter();
        expect(h.sent, isEmpty);
      });
    });

    test('frames with no track are not a picture either', () {
      onClock((h) {
        h.readyWithoutVideo();
        h.picture();

        expect(h.canSend, isFalse);
      });
    });

    test('a picture going away stops it', () {
      onClock((h) {
        h.ready();
        expect(h.canSend, isTrue);

        h.picture(isDisplayed: false);

        expect(h.canSend, isFalse);
        h.imeEnter();
        expect(h.sent, isEmpty);
      });
    });
  });

  group('nothing ahead of it', () {
    for (final (name, send, id) in <(String, void Function(_Harness), String)>[
      ('a tap', (h) => h.tap(), 'tap-1'),
      ('a swipe', (h) => h.swipe(), 'swipe-1'),
      ('a text', (h) => h.text('wifi'), 'text-1'),
    ]) {
      test('$name pending: not until it is answered', () {
        onClock((h) {
          h.ready();
          send(h);

          expect(h.canSend, isFalse);
          h.imeEnter();
          expect(h.sent, [id]);

          h.ack(id);

          expect(h.canSend, isTrue);
          h.imeEnter();
          expect(h.sent, [id, 'enter-2']);
        });
      });
    }

    for (final (name, press, id) in <(String, void Function(_Harness), String)>[
      ('Back', (h) => h.back(), 'back-1'),
      ('Home', (h) => h.home(), 'home-1'),
      ('Recents', (h) => h.recents(), 'recents-1'),
    ]) {
      test('$name: not until it has settled', () {
        onClock((h) {
          h.ready();
          press(h);
          expect(h.canSend, isFalse);

          h.ack(id);
          expect(h.status.pendingCommands, 0);
          expect(h.status.isSettling, isTrue);
          expect(h.canSend, isFalse);
          h.imeEnter();
          expect(h.sent, [id]);

          h.wait(350);
          expect(h.canSend, isTrue);
        });
      });
    }

    test('a tap that timed out is not ahead of it any more', () {
      onClock((h) {
        h.ready();
        h.tap();

        h.wait(3050);

        expect(h.canSend, isTrue);
      });
    });
  });

  group('only ever on purpose', () {
    test('a tap sends no action after it, however long it takes', () {
      onClock((h) {
        h.ready();

        h.tap();
        h.ack('tap-1');
        h.wait(60000);

        expect(h.imeEnters, isEmpty);
        expect(h.sent, ['tap-1']);
      });
    });

    test('a text that went out sends no action after it', () {
      onClock((h) {
        h.ready();

        h.text('wifi');
        h.ack('text-1');
        h.wait(60000);

        expect(h.imeEnters, isEmpty);
        expect(h.sent, ['text-1']);

        h.imeEnter();
        expect(h.sent, ['text-1', 'enter-2']);
      });
    });

    test('nor does a text that was refused', () {
      onClock((h) {
        h.ready();

        h.text('wifi');
        h.ack('text-1', error: RemoteControlError.textTargetUnavailable);
        h.wait(60000);

        expect(h.imeEnters, isEmpty);
      });
    });
  });

  group('ids', () {
    test('it shares one sequence with everything else', () {
      onClock((h) {
        h.ready();

        h.tap();
        h.ack('tap-1');
        h.text('wifi');
        h.ack('text-2');
        h.imeEnter();
        h.ack('enter-3');
        h.wait(350);
        h.home();

        expect(h.sent, ['tap-1', 'text-2', 'enter-3', 'home-4']);
      });
    });

    test('only its own answer resolves it', () {
      onClock((h) {
        h.ready();
        h.imeEnter();

        h.ack('enter-999');
        expect(h.outcome, RemoteCommandOutcome.pending);
        expect(h.status.isSettling, isTrue);

        h.ack('enter-1');
        expect(h.outcome, RemoteCommandOutcome.confirmed);

        h.ack('enter-1', error: RemoteControlError.imeActionRejected);
        expect(h.outcome, RemoteCommandOutcome.confirmed);
      });
    });
  });

  group('the guard', () {
    void expectNothingElseGoesOut(_Harness h) {
      h.tap();
      h.swipe();
      h.back();
      h.home();
      h.recents();
      h.text('Otro');
      h.imeEnter();

      expect(h.sent, ['enter-1']);
    }

    test('nothing else goes out while it is unanswered', () {
      onClock((h) {
        h.ready();
        h.imeEnter();

        expect(h.status.isSettling, isTrue);
        expect(h.status.isTextPending, isFalse);
        expectNothingElseGoesOut(h);
      });
    });

    test('an answer at 50 ms holds everything until 350 ms', () {
      onClock((h) {
        h.ready();
        h.imeEnter();

        h.wait(50);
        h.ack('enter-1');
        expect(h.outcome, RemoteCommandOutcome.confirmed);
        expect(h.status.pendingCommands, 0);
        expect(h.status.isSettling, isTrue);
        expectNothingElseGoesOut(h);

        h.wait(299);
        expect(h.status.isSettling, isTrue);
        expect(h.canSend, isFalse);

        h.wait(1);
        expect(h.status.isSettling, isFalse);
        expect(h.canSend, isTrue);
        h.tap();
        expect(h.sent.last, startsWith('tap-'));
      });
    });

    test('an answer at 500 ms gives control back there and then', () {
      onClock((h) {
        h.ready();
        h.imeEnter();

        h.wait(499);
        expect(h.status.isSettling, isTrue);
        expectNothingElseGoesOut(h);

        h.wait(1);
        h.ack('enter-1');

        expect(h.status.isSettling, isFalse);
        expect(h.canSend, isTrue);
        expect(h.time.pendingTimers, isEmpty);
      });
    });

    test('nothing dropped comes back afterwards', () {
      onClock((h) {
        h.ready();
        h.imeEnter();
        expectNothingElseGoesOut(h);

        h.ack('enter-1');
        h.wait(20000);

        expect(h.peers.last.sentRemoteControlCommands, hasLength(1));
      });
    });

    test('it stops nothing else: the video keeps coming', () {
      onClock((h) {
        h.ready();
        h.imeEnter();
        final session = h.peers.last;

        final track = session.emitRemoteVideoTrack('another');
        h.run();

        expect(h.bloc.state.remoteVideoTrack, track);
        expect(h.bloc.state, isA<WebRtcConnected>());
        expect(session.isClosed, isFalse);
      });
    });

    const refusals = {
      RemoteControlError.imeActionUnavailable:
          RemoteCommandOutcome.imeActionUnavailable,
      RemoteControlError.imeActionRejected:
          RemoteCommandOutcome.imeActionRejected,
      RemoteControlError.textTargetUnavailable:
          RemoteCommandOutcome.textTargetUnavailable,
      RemoteControlError.accessibilityUnavailable:
          RemoteCommandOutcome.accessibilityUnavailable,
      RemoteControlError.sessionNotActive:
          RemoteCommandOutcome.sessionNotActive,
      RemoteControlError.gestureRejected: RemoteCommandOutcome.gestureRejected,
      RemoteControlError.invalidCommand: RemoteCommandOutcome.incompatible,
      RemoteControlError.unsupportedCommand: RemoteCommandOutcome.incompatible,
      RemoteControlError.unknown: RemoteCommandOutcome.incompatible,
    };

    refusals.forEach((error, outcome) {
      test('${error.code} frees the control at once and repeats nothing', () {
        onClock((h) {
          h.ready();
          h.imeEnter();
          h.wait(40);

          h.ack('enter-1', error: error);

          expect(h.outcome, outcome);
          // No settle time: Android did not take the action.
          expect(h.status.isSettling, isFalse);
          expect(h.canSend, isTrue);
          expect(h.peers.last.isClosed, isFalse);
          expect(h.bloc.state, isA<WebRtcConnected>());

          h.tap();
          expect(h.sent, ['enter-1', 'tap-2']);

          h.wait(60000);
          expect(h.imeEnters, hasLength(1));
        });
      });
    });

    test('a channel that refuses the message frees it at once', () {
      onClock((h) {
        h.ready();
        h.peers.last.acceptsRemoteControlCommands = false;

        h.imeEnter();

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
          h.imeEnter();

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
        h.imeEnter();

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
        h.imeEnter();

        h.bloc.add(const WebRtcRemoteSessionActivityChanged(null));
        h.run();

        expect(h.status.pendingCommands, 0);
        expect(h.status.isSettling, isFalse);
        expect(h.status.lastCommand, isNull);
        expect(h.time.pendingTimers, isEmpty);
      });
    });

    test('the assistance ending frees it, and sends nothing later', () {
      // Only what happens before the peer connection is awaited: closing it waits
      // on a future of the root zone, which this clock does not drive. The widget
      // tests of FINALIZAR cover the rest.
      onClock((h) {
        h.ready();
        h.imeEnter();
        final session = h.peers.last;

        h.bloc.add(const WebRtcSessionTerminated());
        h.run();

        // The guard's settle time and the command's deadline, both gone.
        expect(h.time.pendingTimers, isEmpty);

        session.emitRemoteControlAck('enter-1');
        h.run();
        h.imeEnter();
        h.tap();
        h.wait(60000);
        expect(session.sentRemoteControlCommands, hasLength(1));
      });
    });

    test('a replaced peer connection cannot answer the new one', () {
      onClock((h) {
        h.ready();
        final replaced = h.peers.last;
        h.imeEnter();
        h.peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
        h.run();

        h.ready();
        h.imeEnter();
        expect(h.sent, ['enter-2']);

        replaced.emitRemoteControlAck('enter-2');
        h.run();
        h.wait(400);

        expect(h.outcome, RemoteCommandOutcome.pending);
        expect(h.status.isSettling, isTrue);
      });
    });

    test('the settle time of a replaced one does not free the new one', () {
      onClock((h) {
        h.ready();
        h.imeEnter();
        h.ack('enter-1');
        h.peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
        h.run();

        h.ready();
        h.imeEnter();
        h.wait(349);

        expect(h.status.isSettling, isTrue);
        expect(h.outcome, RemoteCommandOutcome.pending);
      });
    });
  });

  group('timeout', () {
    test('five seconds of work and the margin', () {
      onClock((h) {
        h.ready();
        h.imeEnter();

        h.wait(7999);
        expect(h.outcome, RemoteCommandOutcome.pending);
        expect(h.status.isSettling, isTrue);

        h.wait(1);
        expect(h.outcome, RemoteCommandOutcome.timedOut);
        expect(h.status.isSettling, isFalse);
        expect(h.status.pendingCommands, 0);
        expect(h.canSend, isTrue);
      });
    });

    test('an answer after it changes nothing', () {
      onClock((h) {
        h.ready();
        h.imeEnter();
        h.wait(8000);

        h.ack('enter-1');

        expect(h.outcome, RemoteCommandOutcome.timedOut);
        expect(h.status.isSettling, isFalse);
      });
    });

    test('it is never sent again: the action may have run', () {
      onClock((h) {
        h.ready();
        h.imeEnter();

        h.wait(60000);

        expect(h.sent, ['enter-1']);
      });
    });
  });

  group('the log', () {
    test('has the ids and the codes', () {
      final printed = <String>[];
      debugPrint = (String? message, {int? wrapWidth}) {
        printed.add(message ?? '');
      };
      addTearDown(() => debugPrint = (String? message, {int? wrapWidth}) {});

      onClock((h) {
        h.ready();

        h.imeEnter();
        h.ack('enter-1');
        h.wait(350);
        h.imeEnter();
        h.ack('enter-2', error: RemoteControlError.imeActionUnavailable);
        h.imeEnter();
        h.ack('enter-3', error: RemoteControlError.imeActionRejected);
        h.imeEnter();
        h.wait(8000);
      });

      expect(
        printed,
        containsAll([
          contains('ime_enter command sent enter-1'),
          contains('ime_enter confirmed enter-1'),
          contains('ime_enter rejected enter-2: ime_action_unavailable'),
          contains('ime_enter rejected enter-3: ime_action_rejected'),
          contains('ime_enter timed out enter-4'),
        ]),
      );
    });
  });
}
