import 'dart:developer' as developer;

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
const _sentinel = 'SUPER_SECRET_REMOTE_TEXT_123';

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

  /// Everything a text asks for.
  void ready() {
    readyWithoutVideo();
    peers.last.emitRemoteVideoTrack();
    run();
    picture();
  }

  void text(String text, {String id = _sessionId}) {
    bloc.add(WebRtcRemoteTextRequested(remoteSessionId: id, text: text));
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
  bool get canSendText => bloc.state.canSendRemoteText;
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
  // Replaced by a test that wants to read it. `debugPrint` throttles with a timer
  // of its own, which would land on the clock of whichever test printed enough.
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
    test('all of it: the text goes out', () {
      onClock((h) {
        h.ready();
        expect(h.canSendText, isTrue);

        h.text('Hola');

        expect(h.peers.last.sentRemoteControlCommands, const [
          RemoteSetTextCommand(id: 'text-1', text: 'Hola'),
        ]);
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

        expect(h.canSendText, isFalse);
        h.text('Hola');
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

        expect(h.canSendText, isFalse);
        h.text('Hola');
        expect(h.sent, isEmpty);
      });
    });

    test('a connection interrupted', () {
      onClock((h) {
        h.ready();
        h.peers.last.emitPeerState(WebRtcPeerConnectionState.disconnected);
        h.run();

        expect(h.canSendText, isFalse);
        h.text('Hola');
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

          expect(h.canSendText, isFalse);
          h.text('Hola');
          expect(h.sent, isEmpty);
        });
      });
    }

    test('the session being closed', () {
      onClock((h) {
        h.ready();
        h.bloc.add(const WebRtcRemoteSessionActivityChanged(null));
        h.run();

        expect(h.canSendText, isFalse);
        h.text('Hola');
        expect(h.sent, isEmpty);
      });
    });

    test('aimed at another session', () {
      onClock((h) {
        h.ready();

        h.text('Hola', id: _otherSessionId);

        expect(h.sent, isEmpty);
        expect(h.status.lastCommand, isNull);
      });
    });

    test('no negotiation at all', () {
      onClock((h) {
        h.text('Hola');

        expect(h.peers.sessions, isEmpty);
        expect(h.bloc.state, isA<WebRtcIdle>());
      });
    });

    test('over the limit: refused, never cut', () {
      onClock((h) {
        h.ready();

        h.text('a' * 4097);

        expect(h.sent, isEmpty);
        expect(h.outcome, RemoteCommandOutcome.notSent);
      });
    });

    test('at the limit, emoji included', () {
      onClock((h) {
        h.ready();
        final text = '${'a' * 4094}👋';

        h.text(text);

        final sent = h.peers.last.sentRemoteControlCommands.single;
        expect((sent as RemoteSetTextCommand).text, text);
      });
    });

    test('a request that cannot go out says so', () {
      onClock((h) {
        h.ready();
        h.tap();

        h.text('Hola');

        expect(h.sent, ['tap-1']);
        expect(
          h.status.lastCommand,
          const RemoteCommandFeedback(
            commandId: 'text-2',
            kind: RemoteCommandKind.setText,
            outcome: RemoteCommandOutcome.notSent,
          ),
        );
      });
    });
  });

  group('the picture', () {
    test('no video at all: Back goes out, a text does not', () {
      // Android would run it: refusing is the web's decision, because the picture
      // is the only way the technician has to check the target.
      onClock((h) {
        h.readyWithoutVideo();

        expect(h.bloc.state.canSendRemoteNavigation, isTrue);
        expect(h.canSendText, isFalse);

        h.text('Hola');
        expect(h.sent, isEmpty);

        h.back();
        expect(h.sent, ['back-2']);
      });
    });

    test('a track with no frames yet is not a picture', () {
      onClock((h) {
        h.readyWithoutVideo();
        h.peers.last.emitRemoteVideoTrack();
        h.run();

        expect(h.bloc.state.canSendRemoteControl, isTrue);
        expect(h.bloc.state.canOfferRemoteText, isFalse);
        expect(h.canSendText, isFalse);

        h.text('Hola');
        expect(h.sent, isEmpty);
      });
    });

    test('frames with no track are not a picture either', () {
      onClock((h) {
        h.readyWithoutVideo();
        h.picture();

        expect(h.canSendText, isFalse);
      });
    });

    test('a picture going away stops it', () {
      onClock((h) {
        h.ready();
        expect(h.canSendText, isTrue);

        h.picture(isDisplayed: false);

        expect(h.canSendText, isFalse);
        h.text('Hola');
        expect(h.sent, isEmpty);
      });
    });

    test('what a surface of another session says changes nothing', () {
      onClock((h) {
        h.ready();

        h.picture(isDisplayed: false, id: _otherSessionId);

        expect(h.canSendText, isTrue);
      });
    });

    test('it belongs to the negotiation, not to the next one', () {
      onClock((h) {
        h.ready();
        h.peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
        h.run();
        expect(h.status.isPictureDisplayed, isFalse);

        h.readyWithoutVideo();
        h.peers.last.emitRemoteVideoTrack();
        h.run();

        expect(h.canSendText, isFalse);
      });
    });

    test('a gesture needs the track and nothing more, as before', () {
      onClock((h) {
        h.readyWithoutVideo();
        h.peers.last.emitRemoteVideoTrack();
        h.run();

        h.tap();

        expect(h.sent, ['tap-1']);
      });
    });
  });

  group('nothing ahead of it', () {
    test('a swipe pending: not until it is answered', () {
      onClock((h) {
        h.ready();
        h.swipe();

        expect(h.canSendText, isFalse);
        h.text('Hola');
        expect(h.sent, ['swipe-1']);

        h.ack('swipe-1');

        expect(h.canSendText, isTrue);
        h.text('Hola');
        expect(h.sent, ['swipe-1', 'text-3']);
      });
    });

    test('a tap pending: not until it is answered', () {
      onClock((h) {
        h.ready();
        h.tap();

        expect(h.canSendText, isFalse);

        h.ack('tap-1');

        expect(h.canSendText, isTrue);
      });
    });

    test('a tap that timed out is not ahead of it any more', () {
      onClock((h) {
        h.ready();
        h.tap();

        h.wait(3050);

        expect(h.canSendText, isTrue);
      });
    });

    for (final (name, press, id) in <(String, void Function(_Harness), String)>[
      ('Back', (h) => h.back(), 'back-1'),
      ('Home', (h) => h.home(), 'home-1'),
      ('Recents', (h) => h.recents(), 'recents-1'),
    ]) {
      test('$name: not until it has settled', () {
        onClock((h) {
          h.ready();
          press(h);
          expect(h.canSendText, isFalse);

          h.ack(id);
          expect(h.status.pendingCommands, 0);
          expect(h.status.isNavigationSettling, isTrue);
          expect(h.canSendText, isFalse);
          h.text('Hola');
          expect(h.sent, [id]);

          h.wait(350);
          expect(h.canSendText, isTrue);
        });
      });
    }

    test('sending a tap sends no text after it, however long it takes', () {
      onClock((h) {
        h.ready();

        h.tap();
        h.ack('tap-1');
        h.wait(60000);

        expect(h.peers.last.sentRemoteControlCommands, hasLength(1));
        expect(
          h.peers.last.sentRemoteControlCommands.single,
          isA<RemoteTapCommand>(),
        );
      });
    });
  });

  group('the feedback', () {
    test('sent, pending, answered, and no text anywhere', () {
      onClock((h) {
        h.ready();

        h.text(_sentinel);
        expect(h.status.pendingCommands, 1);
        expect(h.status.isTextPending, isTrue);
        expect(
          h.status.lastCommand,
          const RemoteCommandFeedback(
            commandId: 'text-1',
            kind: RemoteCommandKind.setText,
            outcome: RemoteCommandOutcome.pending,
          ),
        );
        expect('${h.bloc.state}', isNot(contains(_sentinel)));
        expect('${h.status.props}', isNot(contains(_sentinel)));

        h.ack('text-1');
        expect(h.status.pendingCommands, 0);
        expect(h.status.isTextPending, isFalse);
        expect(h.outcome, RemoteCommandOutcome.confirmed);
        expect('${h.status.props}', isNot(contains(_sentinel)));
      });
    });

    test('it shares one sequence of ids with everything else', () {
      onClock((h) {
        h.ready();

        h.tap();
        h.ack('tap-1');
        h.text('Hola');
        h.ack('text-2');
        h.home();

        expect(h.sent, ['tap-1', 'text-2', 'home-3']);
      });
    });

    test('an empty text goes out as what it is', () {
      onClock((h) {
        h.ready();

        h.text('');

        expect(h.peers.last.sentRemoteControlCommands, const [
          RemoteSetTextCommand(id: 'text-1', text: ''),
        ]);
      });
    });

    test('only its own answer resolves it', () {
      onClock((h) {
        h.ready();
        h.text('Hola');

        h.ack('text-999');

        expect(h.outcome, RemoteCommandOutcome.pending);
        expect(h.status.isTextPending, isTrue);

        h.ack('text-1');
        expect(h.outcome, RemoteCommandOutcome.confirmed);

        h.ack('text-1', error: RemoteControlError.textRejected);
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

      expect(h.sent, ['text-1']);
      expect(h.status.isNavigationSettling, isFalse);
    }

    test('nothing else goes out while it is unanswered', () {
      onClock((h) {
        h.ready();
        h.text('Hola');

        expectNothingElseGoesOut(h);
      });
    });

    test('nothing dropped comes back afterwards', () {
      onClock((h) {
        h.ready();
        h.text('Hola');
        expectNothingElseGoesOut(h);

        h.ack('text-1');
        h.wait(20000);

        expect(h.peers.last.sentRemoteControlCommands, hasLength(1));
      });
    });

    test('it stops nothing else: the video keeps coming', () {
      onClock((h) {
        h.ready();
        h.text('Hola');
        final session = h.peers.last;

        final track = session.emitRemoteVideoTrack('another');
        h.run();

        expect(h.bloc.state.remoteVideoTrack, track);
        expect(h.bloc.state, isA<WebRtcConnected>());
        expect(session.isClosed, isFalse);
      });
    });

    test('an answer gives control back at once, with no settle time', () {
      onClock((h) {
        h.ready();
        h.text('Hola');

        h.ack('text-1');

        expect(h.status.isNavigationSettling, isFalse);
        expect(h.canSendText, isTrue);
        expect(h.time.pendingTimers, isEmpty);

        h.tap();
        expect(h.sent.last, 'tap-2');
      });
    });

    const refusals = {
      RemoteControlError.textTargetUnavailable:
          RemoteCommandOutcome.textTargetUnavailable,
      RemoteControlError.textRejected: RemoteCommandOutcome.textRejected,
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
      test('${error.code} frees the control and repeats nothing', () {
        onClock((h) {
          h.ready();
          h.text('Hola');

          h.ack('text-1', error: error);

          expect(h.outcome, outcome);
          expect(h.status.isTextPending, isFalse);
          expect(h.peers.last.isClosed, isFalse);
          expect(h.bloc.state, isA<WebRtcConnected>());

          h.wait(60000);
          expect(h.sent, ['text-1']);

          h.tap();
          expect(h.sent, ['text-1', 'tap-2']);
        });
      });
    });

    test('a channel that refuses the message frees it at once', () {
      onClock((h) {
        h.ready();
        h.peers.last.acceptsRemoteControlCommands = false;

        h.text('Hola');

        expect(h.status.pendingCommands, 0);
        expect(h.status.isTextPending, isFalse);
        expect(h.outcome, RemoteCommandOutcome.notSent);
      });
    });

    test(
      'the channel closing frees it, and nothing waits for the deadline',
      () {
        onClock((h) {
          h.ready();
          h.text('Hola');

          h.peers.last.emitControlChannelState(WebRtcDataChannelState.closed);
          h.run();

          expect(h.status.isTextPending, isFalse);
          expect(h.outcome, RemoteCommandOutcome.channelClosed);
          expect(h.time.pendingTimers, isEmpty);
        });
      },
    );

    test('the peer connection failing frees it', () {
      onClock((h) {
        h.ready();
        h.text('Hola');

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
        h.text('Hola');

        h.bloc.add(const WebRtcRemoteSessionActivityChanged(null));
        h.run();

        expect(h.status.pendingCommands, 0);
        expect(h.status.isTextPending, isFalse);
        expect(h.status.lastCommand, isNull);
        expect(h.time.pendingTimers, isEmpty);

        h.text('Hola');
        expect(h.sent, ['text-1']);
      });
    });

    test('a replaced peer connection cannot answer the new one', () {
      onClock((h) {
        h.ready();
        final replaced = h.peers.last;
        h.text('Hola');
        h.peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
        h.run();

        h.ready();
        h.text('Otro');
        expect(h.sent, ['text-2']);

        replaced.emitRemoteControlAck('text-2');
        h.run();

        expect(h.outcome, RemoteCommandOutcome.pending);
        expect(h.status.isTextPending, isTrue);
      });
    });
  });

  group('timeout', () {
    test('five seconds of work and the margin', () {
      onClock((h) {
        h.ready();
        h.text('Hola');

        h.wait(7999);
        expect(h.outcome, RemoteCommandOutcome.pending);
        expect(h.status.isTextPending, isTrue);

        h.wait(1);
        expect(h.outcome, RemoteCommandOutcome.timedOut);
        expect(h.status.isTextPending, isFalse);
        expect(h.status.pendingCommands, 0);
      });
    });

    test('an answer in time is a success', () {
      onClock((h) {
        h.ready();
        h.text('Hola');

        h.wait(7999);
        h.ack('text-1');

        expect(h.outcome, RemoteCommandOutcome.confirmed);

        h.wait(60000);
        expect(h.outcome, RemoteCommandOutcome.confirmed);
      });
    });

    test('an answer after it changes nothing', () {
      onClock((h) {
        h.ready();
        h.text('Hola');
        h.wait(8000);

        h.ack('text-1');

        expect(h.outcome, RemoteCommandOutcome.timedOut);
      });
    });

    test('it is never sent again: the text may have landed', () {
      onClock((h) {
        h.ready();
        h.text('Hola');

        h.wait(60000);

        expect(h.sent, ['text-1']);
      });
    });

    test('it gives control back', () {
      onClock((h) {
        h.ready();
        h.text('Hola');
        h.wait(8000);

        expect(h.canSendText, isTrue);
        h.tap();
        expect(h.sent, ['text-1', 'tap-2']);
      });
    });
  });

  group('privacy', () {
    test('the log has the ids and the codes, never the text', () {
      final printed = <String>[];
      debugPrint = (String? message, {int? wrapWidth}) {
        printed.add(message ?? '');
      };
      addTearDown(() => debugPrint = (String? message, {int? wrapWidth}) {});

      onClock((h) {
        h.ready();

        h.text(_sentinel);
        h.ack('text-1');
        h.text(_sentinel);
        h.ack('text-2', error: RemoteControlError.textTargetUnavailable);
        h.text(_sentinel);
        h.ack('text-3', error: RemoteControlError.invalidCommand);
        h.text(_sentinel);
        h.wait(8000);
        h.tap();
        // Dropped: a tap is pending.
        h.text(_sentinel);
      });

      expect(printed.join('\n'), isNot(contains(_sentinel)));
      expect(
        printed,
        containsAll([
          contains('set_text command sent text-1'),
          contains('set_text confirmed text-1'),
          contains('set_text rejected text-2: text_target_unavailable'),
          contains('set_text rejected text-3: invalid_command'),
          contains('set_text timed out text-4'),
        ]),
      );
    });

    test('a channel that refuses it logs no text either', () {
      final printed = <String>[];
      debugPrint = (String? message, {int? wrapWidth}) {
        printed.add(message ?? '');
      };
      addTearDown(() => debugPrint = (String? message, {int? wrapWidth}) {});

      onClock((h) {
        h.ready();
        h.peers.last.acceptsRemoteControlCommands = false;
        h.text(_sentinel);
      });

      expect(printed.join('\n'), isNot(contains(_sentinel)));
    });

    test('what waits for the answer does not keep the command alive', () async {
      final peers = FakeWebRtcPeerClient();
      final signaling = FakeTechnicianSignalingClient()
        ..joinedRemoteSessionId = _sessionId;
      final bloc = WebRtcSessionBloc(
        peerClient: peers,
        signalingClient: signaling,
        iceConfiguration: const WebRtcIceConfiguration(),
      );
      addTearDown(() async {
        await bloc.close();
        await signaling.dispose();
      });

      Future<void> settle() => pumpEventQueue();

      bloc.add(const WebRtcNegotiationRequested(_sessionId));
      await settle();
      peers.last
        ..emitControlChannelState(WebRtcDataChannelState.open)
        ..emitPeerState(WebRtcPeerConnectionState.connected)
        ..emitRemoteVideoTrack();
      bloc
        ..add(const WebRtcRemoteSessionActivityChanged(_sessionId))
        ..add(
          const WebRtcRemotePictureChanged(
            remoteSessionId: _sessionId,
            isDisplayed: true,
          ),
        );
      await settle();

      bloc.add(
        WebRtcRemoteTextRequested(
          remoteSessionId: _sessionId,
          // Not a constant: those are never collected.
          text: String.fromCharCodes(_sentinel.codeUnits),
        ),
      );
      await settle();

      // The fake is what remembers what was sent, so it has to let go first.
      final sent = peers.last.sentRemoteControlCommands;
      final reference = WeakReference(sent.single);
      sent.clear();
      await _collectGarbage();

      expect(bloc.state.remoteControl.isTextPending, isTrue);
      expect(reference.target, isNull);
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
