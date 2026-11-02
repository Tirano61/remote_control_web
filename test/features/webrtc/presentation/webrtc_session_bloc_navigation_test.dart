import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_status.dart';
import 'package:remote_control_web/features/remote_control/domain/services/remote_control_command_id_generator.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_web/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../../support/webrtc_test_doubles.dart';

const _sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';
const _otherSessionId = '9a0f3d1b-4c88-9e64-6f2a-5c7e8b103d1b';

/// Hands out exactly the ids it was given.
class _FixedCommandIds implements RemoteControlCommandIdGenerator {
  _FixedCommandIds(List<String> ids) : _ids = ids.iterator;

  final Iterator<String> _ids;

  @override
  String next(RemoteCommandKind kind) {
    _ids.moveNext();
    return _ids.current;
  }
}

/// A BLoC on a clock the test moves, because when the guard ends is the point.
class _Harness {
  _Harness(this.time, {RemoteControlCommandIdGenerator? ids})
    : peers = FakeWebRtcPeerClient(),
      signaling = FakeTechnicianSignalingClient()
        ..joinedRemoteSessionId = _sessionId {
    bloc = WebRtcSessionBloc(
      peerClient: peers,
      signalingClient: signaling,
      iceConfiguration: const WebRtcIceConfiguration(),
      commandIdGenerator: ids,
    );
  }

  final FakeAsync time;
  final FakeWebRtcPeerClient peers;
  final FakeTechnicianSignalingClient signaling;
  late final WebRtcSessionBloc bloc;

  /// Lets the BLoC process what was queued, with the clock standing still.
  /// Several steps chain across futures, hence more than one turn.
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

  /// Connected, `control` open, `ACTIVE`, and no picture at all.
  void readyWithoutVideo() {
    negotiate();
    peers.last
      ..emitControlChannelState(WebRtcDataChannelState.open)
      ..emitPeerState(WebRtcPeerConnectionState.connected);
    bloc.add(const WebRtcRemoteSessionActivityChanged(_sessionId));
    run();
  }

  void ready() {
    readyWithoutVideo();
    peers.last.emitRemoteVideoTrack();
    run();
  }

  void back({String id = _sessionId}) {
    bloc.add(WebRtcRemoteBackRequested(remoteSessionId: id));
    run();
  }

  void home({String id = _sessionId}) {
    bloc.add(WebRtcRemoteHomeRequested(remoteSessionId: id));
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

  void ack(String id, {RemoteControlError? error}) {
    peers.last.emitRemoteControlAck(id, error: error);
    run();
  }

  RemoteControlStatus get status => bloc.state.remoteControl;
  bool get isSettling => status.isNavigationSettling;
  RemoteCommandOutcome? get outcome => status.lastCommand?.outcome;
  List<String> get sent =>
      peers.last.sentRemoteControlCommands.map((c) => c.id).toList();

  void dispose() {
    bloc.close();
    signaling.dispose();
    run();
  }
}

void main() {
  // `debugPrint` throttles with a timer of its own, which would land on the clock
  // of whichever test happened to print enough.
  setUpAll(() => debugPrint = (String? message, {int? wrapWidth}) {});
  tearDownAll(() => debugPrint = debugPrintThrottled);

  /// Closing the BLoC is only started here: releasing a peer connection awaits a
  /// `cancel()` that resumes outside this clock. What must not outlive it is
  /// cleared before that, and whatever needs the release to finish is tested in
  /// real time, in `webrtc_session_bloc_test.dart`.
  void onClock(
    void Function(_Harness harness) body, {
    RemoteControlCommandIdGenerator? ids,
  }) {
    fakeAsync((time) {
      final harness = _Harness(time, ids: ids);
      body(harness);
      harness.dispose();
      expect(time.pendingTimers, isEmpty);
    });
  }

  group('what it takes to send', () {
    test('ACTIVE, connected and control open: Back and Home go out', () {
      onClock((h) {
        h.ready();
        expect(h.bloc.state.canSendRemoteNavigation, isTrue);

        h.back();
        h.ack('back-1');
        h.wait(350);
        h.home();

        expect(h.peers.last.sentRemoteControlCommands, const [
          RemoteBackCommand(id: 'back-1'),
          RemoteHomeCommand(id: 'home-2'),
        ]);
      });
    });

    test('a session still CONNECTING', () {
      onClock((h) {
        h.negotiate();
        h.peers.last
          ..emitControlChannelState(WebRtcDataChannelState.open)
          ..emitPeerState(WebRtcPeerConnectionState.connected);
        h.run();

        expect(h.bloc.state.canSendRemoteNavigation, isFalse);
        h.back();
        h.home();

        expect(h.sent, isEmpty);
      });
    });

    test('another session being ACTIVE', () {
      onClock((h) {
        h.negotiate();
        h.peers.last
          ..emitControlChannelState(WebRtcDataChannelState.open)
          ..emitPeerState(WebRtcPeerConnectionState.connected);
        h.bloc.add(const WebRtcRemoteSessionActivityChanged(_otherSessionId));
        h.run();

        expect(h.bloc.state.canSendRemoteNavigation, isFalse);
        h.home();

        expect(h.sent, isEmpty);
      });
    });

    test('a peer connection not connected', () {
      onClock((h) {
        h.negotiate();
        h.peers.last.emitControlChannelState(WebRtcDataChannelState.open);
        h.bloc.add(const WebRtcRemoteSessionActivityChanged(_sessionId));
        h.run();

        expect(h.bloc.state.canSendRemoteNavigation, isFalse);
        h.back();

        expect(h.sent, isEmpty);
      });
    });

    test('a connection interrupted', () {
      onClock((h) {
        h.ready();
        h.peers.last.emitPeerState(WebRtcPeerConnectionState.disconnected);
        h.run();

        expect(h.bloc.state, isA<WebRtcInterrupted>());
        h.back();

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

          expect(h.bloc.state.canSendRemoteNavigation, isFalse);
          h.back();
          h.home();

          expect(h.sent, isEmpty);
        });
      });
    }

    test('the session being closed', () {
      onClock((h) {
        h.ready();
        h.bloc.add(const WebRtcRemoteSessionActivityChanged(null));
        h.run();

        expect(h.bloc.state.canSendRemoteNavigation, isFalse);
        h.back();

        expect(h.sent, isEmpty);
      });
    });

    test('aimed at another session', () {
      onClock((h) {
        h.ready();

        h.back(id: _otherSessionId);
        h.home(id: _otherSessionId);

        expect(h.sent, isEmpty);
        expect(h.isSettling, isFalse);
      });
    });

    test('no negotiation at all', () {
      onClock((h) {
        h.back();
        h.home();

        expect(h.peers.sessions, isEmpty);
        expect(h.bloc.state, isA<WebRtcIdle>());
      });
    });
  });

  group('without a picture', () {
    test('Back and Home are available, a tap and a swipe are not', () {
      onClock((h) {
        h.readyWithoutVideo();

        expect(h.bloc.state.remoteVideoTrack, isNull);
        expect(h.bloc.state.canSendRemoteNavigation, isTrue);
        expect(h.bloc.state.canSendRemoteControl, isFalse);

        h.tap();
        h.swipe();
        expect(h.sent, isEmpty);

        h.back();
        h.ack('back-1');
        h.wait(350);
        h.home();
        expect(h.sent, ['back-1', 'home-2']);
      });
    });

    test('the guard and the answer work the same', () {
      onClock((h) {
        h.readyWithoutVideo();

        h.home();
        expect(h.isSettling, isTrue);
        expect(h.outcome, RemoteCommandOutcome.pending);

        h.ack('home-1');
        h.wait(350);

        expect(h.isSettling, isFalse);
        expect(h.outcome, RemoteCommandOutcome.confirmed);
      });
    });
  });

  group('pending', () {
    test('Back: sent, pending, answered', () {
      onClock((h) {
        h.ready();

        h.back();
        expect(h.status.pendingCommands, 1);
        expect(
          h.status.lastCommand,
          const RemoteCommandFeedback(
            commandId: 'back-1',
            kind: RemoteCommandKind.back,
            outcome: RemoteCommandOutcome.pending,
          ),
        );

        h.ack('back-1');
        expect(h.status.pendingCommands, 0);
        expect(
          h.status.lastCommand,
          const RemoteCommandFeedback(
            commandId: 'back-1',
            kind: RemoteCommandKind.back,
            outcome: RemoteCommandOutcome.confirmed,
          ),
        );
      });
    });

    test('Home: sent, pending, answered', () {
      onClock((h) {
        h.ready();

        h.home();
        expect(h.status.pendingCommands, 1);
        expect(
          h.status.lastCommand,
          const RemoteCommandFeedback(
            commandId: 'home-1',
            kind: RemoteCommandKind.home,
            outcome: RemoteCommandOutcome.pending,
          ),
        );

        h.ack('home-1');
        expect(h.status.pendingCommands, 0);
        expect(h.outcome, RemoteCommandOutcome.confirmed);
      });
    });

    test('they share one sequence of ids with the gestures', () {
      onClock((h) {
        h.ready();

        h.tap();
        h.ack('tap-1');
        h.back();
        h.ack('back-2');
        h.wait(350);
        h.swipe();
        h.ack('swipe-3');
        h.home();

        expect(h.sent, ['tap-1', 'back-2', 'swipe-3', 'home-4']);
      });
    });

    test('a channel that refuses the message is reported at once', () {
      onClock((h) {
        h.ready();
        h.peers.last.acceptsRemoteControlCommands = false;

        h.back();

        expect(h.status.pendingCommands, 0);
        expect(h.outcome, RemoteCommandOutcome.notSent);
        expect(h.isSettling, isFalse);
      });
    });
  });

  group('timeout', () {
    test('50 ms of work and the margin, not a timeout of its own', () {
      onClock((h) {
        h.ready();
        h.home();

        h.wait(3049);
        expect(h.outcome, RemoteCommandOutcome.pending);

        h.wait(1);
        expect(h.outcome, RemoteCommandOutcome.timedOut);
        expect(h.status.pendingCommands, 0);
      });
    });

    test('what is pending ahead of it counts', () {
      onClock((h) {
        h.ready();
        h.swipe();
        h.back();

        // The swipe's 350 ms, its own 50 ms and the margin.
        h.wait(3399);
        expect(h.outcome, RemoteCommandOutcome.pending);

        h.wait(1);
        expect(h.outcome, RemoteCommandOutcome.timedOut);
      });
    });

    test('it frees the control and is not sent again', () {
      onClock((h) {
        h.ready();
        h.back();

        h.wait(3050);
        expect(h.isSettling, isFalse);
        h.wait(60000);

        expect(h.sent, ['back-1']);
      });
    });

    test('an answer after it changes nothing', () {
      onClock((h) {
        h.ready();
        h.home();
        h.wait(3050);

        h.ack('home-1');

        expect(h.outcome, RemoteCommandOutcome.timedOut);
        expect(h.isSettling, isFalse);
      });
    });
  });

  group('the guard', () {
    test('an answer at 50 ms holds until 350 ms', () {
      onClock((h) {
        h.ready();

        h.home();
        expect(h.isSettling, isTrue);

        h.wait(50);
        h.ack('home-1');
        expect(h.outcome, RemoteCommandOutcome.confirmed);
        expect(h.isSettling, isTrue);

        h.wait(299);
        expect(h.isSettling, isTrue);

        h.wait(1);
        expect(h.isSettling, isFalse);
      });
    });

    test('an answer at 500 ms frees at 500 ms, with nothing added', () {
      onClock((h) {
        h.ready();

        h.back();
        h.wait(350);
        expect(h.isSettling, isTrue);

        h.wait(150);
        expect(h.isSettling, isTrue);

        h.ack('back-1');
        expect(h.isSettling, isFalse);
      });
    });

    test('a tap at 200 ms is dropped, and works after 350 ms', () {
      onClock((h) {
        h.ready();
        h.home();
        h.wait(50);
        h.ack('home-1');

        h.wait(150);
        h.tap();
        expect(h.sent, ['home-1']);

        h.wait(150);
        h.tap();
        expect(h.sent, ['home-1', 'tap-2']);
      });
    });

    test('a swipe at 200 ms is dropped, and works after 350 ms', () {
      onClock((h) {
        h.ready();
        h.back();
        h.wait(50);
        h.ack('back-1');

        h.wait(150);
        h.swipe();
        expect(h.sent, ['back-1']);

        h.wait(150);
        h.swipe();
        expect(h.sent, ['back-1', 'swipe-2']);
      });
    });

    test('nothing goes out while the answer is missing, however long', () {
      onClock((h) {
        h.ready();
        h.home();

        h.wait(1000);
        h.tap();
        h.swipe();
        h.back();
        h.home();

        expect(h.sent, ['home-1']);
      });
    });

    test('a second Back is not sent', () {
      onClock((h) {
        h.ready();

        h.back();
        h.back();
        h.wait(100);
        h.back();

        expect(h.sent, ['back-1']);
        expect(h.status.pendingCommands, 1);
      });
    });

    test('Home during a Back is not sent, and the other way round', () {
      onClock((h) {
        h.ready();

        h.back();
        h.home();
        expect(h.sent, ['back-1']);

        h.ack('back-1');
        h.wait(350);

        h.home();
        h.back();
        expect(h.sent, ['back-1', 'home-2']);
      });
    });

    test('a double click in the same turn is one action', () {
      onClock((h) {
        h.ready();

        h.bloc
          ..add(const WebRtcRemoteHomeRequested(remoteSessionId: _sessionId))
          ..add(const WebRtcRemoteHomeRequested(remoteSessionId: _sessionId));
        h.run();

        expect(h.sent, ['home-1']);
      });
    });

    test('nothing dropped comes back afterwards', () {
      onClock((h) {
        h.ready();
        h.home();
        h.tap();
        h.swipe();

        h.ack('home-1');
        h.wait(5000);

        expect(h.sent, ['home-1']);
      });
    });

    test('a tap or a swipe does not start it', () {
      onClock((h) {
        h.ready();

        h.tap();
        expect(h.isSettling, isFalse);

        h.swipe();
        expect(h.isSettling, isFalse);
      });
    });

    test('the answer to an older tap does not end it', () {
      onClock((h) {
        h.ready();
        h.tap();
        h.back();
        h.wait(350);

        h.ack('tap-1');
        expect(h.isSettling, isTrue);
        expect(h.outcome, RemoteCommandOutcome.pending);

        h.ack('back-2');
        expect(h.isSettling, isFalse);
      });
    });

    test('the refusal of an older tap does not end it', () {
      onClock((h) {
        h.ready();
        h.tap();
        h.home();

        h.ack('tap-1', error: RemoteControlError.gestureRejected);

        expect(h.isSettling, isTrue);
        expect(h.outcome, RemoteCommandOutcome.pending);
      });
    });

    test('it stops nothing else: the video track still comes through', () {
      onClock((h) {
        h.readyWithoutVideo();
        h.home();
        final session = h.peers.last;

        final track = session.emitRemoteVideoTrack();
        h.run();

        expect(h.bloc.state.remoteVideoTrack, track);
        expect(h.bloc.state, isA<WebRtcConnected>());
        expect(h.bloc.state.isControlChannelOpen, isTrue);
        expect(session.isClosed, isFalse);
      });
    });
  });

  group('a refused action frees the control at once', () {
    const refusals = {
      RemoteControlError.accessibilityUnavailable:
          RemoteCommandOutcome.accessibilityUnavailable,
      RemoteControlError.gestureRejected: RemoteCommandOutcome.gestureRejected,
      RemoteControlError.sessionNotActive:
          RemoteCommandOutcome.sessionNotActive,
      RemoteControlError.invalidCommand: RemoteCommandOutcome.incompatible,
      RemoteControlError.unsupportedCommand: RemoteCommandOutcome.incompatible,
    };

    refusals.forEach((error, outcome) {
      test('${error.code} on a Home', () {
        onClock((h) {
          h.ready();
          h.home();

          h.wait(40);
          h.ack('home-1', error: error);

          expect(h.outcome, outcome);
          expect(h.isSettling, isFalse);

          h.tap();
          expect(h.sent, ['home-1', 'tap-2']);
        });
      });

      test('${error.code} on a Back ends nothing and repeats nothing', () {
        onClock((h) {
          h.ready();
          h.back();
          h.ack('back-1', error: error);
          h.wait(60000);

          expect(h.outcome, outcome);
          expect(h.sent, ['back-1']);
          expect(h.peers.last.isClosed, isFalse);
          expect(h.bloc.state, isA<WebRtcConnected>());
        });
      });
    });
  });

  group('cleanup', () {
    test('the session closing, with a Back pending', () {
      onClock((h) {
        h.ready();
        h.back();

        h.bloc.add(const WebRtcRemoteSessionActivityChanged(null));
        h.run();

        expect(h.status.pendingCommands, 0);
        expect(h.status.lastCommand, isNull);
        expect(h.isSettling, isFalse);
        expect(h.time.pendingTimers, isEmpty);
      });
    });

    test('the session closing, with a Home answered and settling', () {
      onClock((h) {
        h.ready();
        h.home();
        h.ack('home-1');
        expect(h.isSettling, isTrue);

        h.bloc.add(const WebRtcRemoteSessionActivityChanged(null));
        h.run();

        expect(h.isSettling, isFalse);
        expect(h.status.lastCommand, isNull);
        expect(h.time.pendingTimers, isEmpty);
      });
    });

    test('a close that failed starts clean', () {
      onClock((h) {
        h.ready();
        h.home();
        h.bloc.add(const WebRtcRemoteSessionActivityChanged(null));
        h.run();

        h.bloc.add(const WebRtcRemoteSessionActivityChanged(_sessionId));
        h.run();

        expect(h.isSettling, isFalse);
        h.tap();
        expect(h.sent, ['home-1', 'tap-2']);
      });
    });

    for (final channelState in const [
      WebRtcDataChannelState.closing,
      WebRtcDataChannelState.closed,
    ]) {
      test('the channel ${channelState.name}, with a Home answered', () {
        onClock((h) {
          h.ready();
          h.home();
          h.ack('home-1');

          h.peers.last.emitControlChannelState(channelState);
          h.run();

          expect(h.isSettling, isFalse);
          expect(h.time.pendingTimers, isEmpty);
        });
      });
    }

    test('the channel coming back holds nothing', () {
      onClock((h) {
        h.ready();
        h.home();

        h.peers.last.emitControlChannelState(WebRtcDataChannelState.closed);
        h.run();
        h.peers.last.emitControlChannelState(WebRtcDataChannelState.open);
        h.run();

        expect(h.isSettling, isFalse);
        h.back();
        expect(h.sent, ['home-1', 'back-2']);
      });
    });

    test('the peer connection failing', () {
      onClock((h) {
        h.ready();
        h.back();

        h.peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
        h.run();

        expect(h.bloc.state, isA<WebRtcFailed>());
        expect(h.bloc.state.remoteControl, const RemoteControlStatus());
        expect(h.time.pendingTimers, isEmpty);
      });
    });
  });

  group('generations', () {
    /// A second negotiation, where the first one held a Back at t = 100.
    FakeWebRtcPeerSession replacedByNewPeer(_Harness h) {
      h.ready();
      final replaced = h.peers.last;
      h.back();
      h.wait(100);

      h.peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      h.run();
      h.ready();
      return replaced;
    }

    test('the answer of a replaced channel does not end the new guard', () {
      onClock((h) {
        final replaced = replacedByNewPeer(h);
        h.back();

        replaced.emitRemoteControlAck('back-1');
        h.run();
        h.wait(350);

        expect(h.isSettling, isTrue);
        expect(h.outcome, RemoteCommandOutcome.pending);

        h.ack('back-1');
        expect(h.isSettling, isFalse);
        expect(h.outcome, RemoteCommandOutcome.confirmed);
      }, ids: _FixedCommandIds(['back-1', 'back-1']));
    });

    test('the settle time of a replaced channel does not end the new guard', () {
      onClock((h) {
        replacedByNewPeer(h);
        h.wait(200);
        h.home();
        h.ack('home-2');

        // Where the first Back would have settled, this Home has only had 50 ms.
        h.wait(50);
        expect(h.isSettling, isTrue);

        h.wait(300);
        expect(h.isSettling, isFalse);
      });
    });

    test('the new peer connection starts with nothing held back', () {
      onClock((h) {
        replacedByNewPeer(h);

        expect(h.isSettling, isFalse);
        expect(h.status.pendingCommands, 0);
        h.tap();
        expect(h.sent, ['tap-2']);
      });
    });

    test('a repeated id still belongs to its own negotiation', () {
      onClock((h) {
        final replaced = replacedByNewPeer(h);
        h.home();

        replaced.emitRemoteControlAck(
          'back-1',
          error: RemoteControlError.gestureRejected,
        );
        h.run();

        expect(h.isSettling, isTrue);
        expect(h.outcome, RemoteCommandOutcome.pending);
      }, ids: _FixedCommandIds(['back-1', 'back-1']));
    });
  });
}
