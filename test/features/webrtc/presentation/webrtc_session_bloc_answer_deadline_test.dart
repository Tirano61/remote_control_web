import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_web/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../../support/webrtc_test_doubles.dart';

const _sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';
const _otherSessionId = '9a0f3d1b-4c88-9e64-6f2a-5c7e8b103d1b';
const _deadline = WebRtcSessionBloc.defaultAnswerDeadline;

/// A BLoC on a clock the test moves, with a backend that relays every offer.
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
    retries = bloc.connectionRetries.listen(retried.add);
  }

  final FakeAsync time;
  final FakeWebRtcPeerClient peers;
  final FakeTechnicianSignalingClient signaling;
  late final WebRtcSessionBloc bloc;
  late final StreamSubscription<String> retries;
  final List<String> retried = [];

  WebRtcSessionState get state => bloc.state;

  void run() {
    for (var i = 0; i < 12; i++) {
      time.elapse(Duration.zero);
    }
  }

  void wait(Duration duration) {
    time.elapse(duration);
    run();
  }

  void negotiate({bool replacing = false}) {
    bloc.add(
      WebRtcNegotiationRequested(
        _sessionId,
        replacesUnansweredOffer: replacing,
      ),
    );
    run();
  }

  void answer({String sdp = 'v=0 answer'}) {
    signaling.emitAnswer(_sessionId, sdp: sdp);
    run();
  }

  void retry([String id = _sessionId]) {
    bloc.add(WebRtcConnectionRetryRequested(id));
    run();
  }

  void dispose() {
    retries.cancel();
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

  group('the deadline', () {
    test('until it passes, an unanswered offer is only waiting', () {
      onClock((h) {
        h.negotiate();
        h.wait(_deadline - const Duration(milliseconds: 1));

        expect(h.state, isA<WebRtcConnecting>());
        expect(h.state.isAnswerOverdue, isFalse);
        expect(h.state.isTabletSilent, isFalse);
        expect(h.state.canRetryConnection, isFalse);
      });
    });

    test('once it passes it is said, and nothing is torn down', () {
      onClock((h) {
        h.negotiate();
        h.wait(_deadline);

        expect(h.state, isA<WebRtcConnecting>());
        expect(h.state.isAnswerOverdue, isTrue);
        expect(h.state.isTabletSilent, isTrue);
        expect(h.state.canRetryConnection, isTrue);
        expect(h.peers.last.isClosed, isFalse);
        expect(h.peers.sessions, hasLength(1));
        // Said once: the clock going on changes nothing more.
        h.wait(const Duration(minutes: 10));
        expect(h.peers.sessions, hasLength(1));
        expect(h.signaling.sentOffers, hasLength(1));
      });
    });

    test('it starts when the offer is relayed, not before', () {
      onClock((h) {
        final gate = Completer<void>();
        h.signaling.offerGate = gate.future;
        h.negotiate();
        h.wait(_deadline * 2);
        expect(h.state, isA<WebRtcOffering>());
        expect(h.state.isAnswerOverdue, isFalse);

        gate.complete();
        h.run();
        h.wait(_deadline - const Duration(seconds: 1));
        expect(h.state.isAnswerOverdue, isFalse);
        h.wait(const Duration(seconds: 1));
        expect(h.state.isAnswerOverdue, isTrue);
      });
    });

    test('an answer in time leaves nothing behind', () {
      onClock((h) {
        h.negotiate();
        h.wait(const Duration(seconds: 10));
        h.answer();
        h.wait(_deadline * 2);

        expect(h.peers.last.appliedAnswers, hasLength(1));
        expect(h.state.isAnswerOverdue, isFalse);
        expect(h.state.isTabletSilent, isFalse);
      });
    });

    test('a late answer is still applied to the same peer connection', () {
      onClock((h) {
        h.negotiate();
        h.wait(_deadline + const Duration(seconds: 20));
        expect(h.state.isAnswerOverdue, isTrue);

        h.answer();
        expect(h.peers.last.appliedAnswers, hasLength(1));
        expect(h.peers.sessions, hasLength(1));
        expect(h.state.isAnswerOverdue, isFalse);
        expect(h.state.isTabletSilent, isFalse);
        expect(h.state.canRetryConnection, isFalse);
      });
    });

    test('connected proves the answer: the deadline goes', () {
      onClock((h) {
        h.negotiate();
        h.peers.last.emitPeerState(WebRtcPeerConnectionState.connected);
        h.run();
        h.wait(_deadline * 2);
        expect(h.state, isA<WebRtcConnected>());
        expect(h.state.isAnswerOverdue, isFalse);
      });
    });

    test('a negotiation that ends takes its deadline with it', () {
      onClock((h) {
        h.negotiate();
        h.bloc.add(const WebRtcSignalingLost());
        h.run();
        h.wait(_deadline * 2);
        expect(h.state, isA<WebRtcIdle>());
        expect(h.state.isAnswerOverdue, isFalse);

        h.negotiate();
        h.bloc.add(const WebRtcSessionTerminated());
        h.run();
        h.wait(_deadline * 2);
        expect(h.state, isA<WebRtcIdle>());
      });
    });
  });

  group('replacing it', () {
    test('only on the console\'s word, and only once it is overdue', () {
      onClock((h) {
        h.negotiate();
        // Readiness again: never a second peer connection.
        h.negotiate();
        h.negotiate(replacing: true);
        expect(h.peers.sessions, hasLength(1));

        h.wait(_deadline);
        h.negotiate();
        expect(h.peers.sessions, hasLength(1));

        h.negotiate(replacing: true);
        expect(h.peers.sessions, hasLength(2));
        expect(h.peers.sessions.first.isClosed, isTrue);
        expect(h.peers.sessions.where((peer) => !peer.isClosed), hasLength(1));
        expect(h.signaling.sentOffers, hasLength(2));
        // A new negotiation, a new deadline: not overdue, the tablet still
        // silent.
        expect(h.state.isAnswerOverdue, isFalse);
        expect(h.state.isTabletSilent, isTrue);
      });
    });

    test('never a connected peer connection', () {
      onClock((h) {
        h.negotiate();
        h.answer();
        h.peers.last
          ..emitPeerState(WebRtcPeerConnectionState.connected)
          ..emitControlChannelState(WebRtcDataChannelState.open);
        h.run();
        h.wait(_deadline * 2);

        h.negotiate(replacing: true);
        expect(h.peers.sessions, hasLength(1));
        expect(h.state, isA<WebRtcConnected>());
      });
    });

    test('the old one\'s answer and callbacks never reach the new one', () {
      onClock((h) {
        h.negotiate();
        final old = h.peers.last;
        h.wait(_deadline);
        h.negotiate(replacing: true);
        final replacement = h.peers.last;

        old
          ..emitPeerState(WebRtcPeerConnectionState.connected)
          ..emitControlChannelState(WebRtcDataChannelState.open)
          ..emitRemoteVideoTrack('old-screen');
        h.run();
        expect(h.state, isA<WebRtcConnecting>());
        expect(h.state.hasRemoteVideo, isFalse);
        expect(h.state.isControlChannelOpen, isFalse);

        h.answer();
        expect(old.appliedAnswers, isEmpty);
        expect(replacement.appliedAnswers, hasLength(1));
      });
    });
  });

  group('REINTENTAR', () {
    test('is handed on for an unanswered offer of that session', () {
      onClock((h) {
        h.negotiate();
        h.retry();
        expect(h.retried, isEmpty);

        h.wait(_deadline);
        h.retry(_otherSessionId);
        expect(h.retried, isEmpty);
        h.retry();
        expect(h.retried, [_sessionId]);
        // It negotiates nothing by itself.
        expect(h.peers.sessions, hasLength(1));
      });
    });

    test('is handed on for a failure, never for a working connection', () {
      onClock((h) {
        h.negotiate();
        h.answer();
        h.peers.last.emitPeerState(WebRtcPeerConnectionState.connected);
        h.run();
        h.retry();
        expect(h.retried, isEmpty);

        h.peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
        h.run();
        expect(h.state, isA<WebRtcFailed>());
        h.retry();
        expect(h.retried, [_sessionId]);
      });
    });
  });

  test('the console\'s schedule is carried, including on a failure', () {
    onClock((h) {
      h.negotiate();
      h.peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      h.run();
      expect(h.state.isRecoveryScheduled, isFalse);

      h.bloc.add(const WebRtcAutomaticRecoveryChanged(isScheduled: true));
      h.run();
      expect(h.state, isA<WebRtcFailed>());
      expect(h.state.isRecoveryScheduled, isTrue);

      // Carried into the next negotiation, until the console says otherwise.
      h.negotiate();
      expect(h.state.isRecoveryScheduled, isTrue);
      h.bloc.add(const WebRtcAutomaticRecoveryChanged(isScheduled: false));
      h.run();
      expect(h.state.isRecoveryScheduled, isFalse);

      // The end of the assistance forgets it.
      h.bloc
        ..add(const WebRtcAutomaticRecoveryChanged(isScheduled: true))
        ..add(const WebRtcSessionTerminated());
      h.run();
      h.negotiate();
      expect(h.state.isRecoveryScheduled, isFalse);
    });
  });
}
