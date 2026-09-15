import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/signaling_error_code.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_web/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../../support/webrtc_test_doubles.dart';

/// Lets the event loop drain, so the BLoC processes what was queued. Several
/// steps chain across futures, hence more than one turn.
Future<void> settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  const sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';
  const otherSessionId = '9a0f3d1b-4c88-9e64-6f2a-5c7e8b103d1b';

  late FakeWebRtcPeerClient peers;
  late FakeTechnicianSignalingClient signaling;
  late WebRtcSessionBloc bloc;

  void build({WebRtcIceConfiguration? iceConfiguration}) {
    bloc = WebRtcSessionBloc(
      peerClient: peers,
      signalingClient: signaling,
      iceConfiguration: iceConfiguration ?? const WebRtcIceConfiguration(),
    );
  }

  setUp(() {
    peers = FakeWebRtcPeerClient();
    signaling = FakeTechnicianSignalingClient()
      ..joinedRemoteSessionId = sessionId;
    build();
  });

  tearDown(() async {
    await bloc.close();
    await signaling.dispose();
  });

  /// Everything the console checks before negotiating is true.
  Future<void> negotiate([String id = sessionId]) async {
    bloc.add(WebRtcNegotiationRequested(id));
    await settle();
  }

  /// A negotiation that reached `connected` with its channel open.
  Future<void> connect() async {
    await negotiate();
    peers.last
      ..emitControlChannelState(WebRtcDataChannelState.open)
      ..emitPeerState(WebRtcPeerConnectionState.connected);
    await settle();
  }

  group('starting a negotiation', () {
    test('nothing is created until the console asks for it', () async {
      expect(bloc.state, isA<WebRtcIdle>());
      expect(peers.sessions, isEmpty);
      expect(signaling.sentOffers, isEmpty);
    });

    test('the offerer creates the peer, the channel and the offer', () async {
      await negotiate();

      expect(peers.sessions, hasLength(1));
      // The control channel comes first: it is what puts the SCTP m-section
      // into the SDP that is about to be created.
      expect(peers.last.calls, ['channel', 'offer']);
      expect(signaling.sentOffers.single.remoteSessionId, sessionId);
      expect(signaling.sentOffers.single.sdp, peers.last.offerSdp);
      expect(bloc.state, isA<WebRtcConnecting>());
    });

    test('the ICE configuration is the one the application was built with', () async {
      await bloc.close();
      build(
        iceConfiguration: WebRtcIceConfiguration.fromStunUrl(
          'stun:stun.example.org:19302',
        ),
      );

      await negotiate();

      expect(peers.configurations.single.iceServers.single.urls,
          'stun:stun.example.org:19302');
    });

    test('an empty ICE configuration is valid and is the default', () async {
      await negotiate();

      expect(peers.configurations.single.isLanOnly, isTrue);
    });

    test('repeated readiness never creates a second peer connection', () async {
      await negotiate();
      // Another `peer-joined`, a refreshed RemoteSession, a rejoin.
      await negotiate();
      await negotiate();

      expect(peers.sessions, hasLength(1));
      expect(signaling.sentOffers, hasLength(1));
    });

    test('a request while the peer connection is being created is dropped', () async {
      final gate = Completer<void>();
      peers.createGate = gate.future;
      bloc.add(const WebRtcNegotiationRequested(sessionId));
      await settle();
      expect(bloc.state, isA<WebRtcPreparing>());

      bloc.add(const WebRtcNegotiationRequested(sessionId));
      gate.complete();
      await settle();

      expect(peers.sessions, hasLength(1));
      expect(signaling.sentOffers, hasLength(1));
    });

    test('a different session replaces the negotiation', () async {
      await negotiate();
      final first = peers.last;

      await negotiate(otherSessionId);

      expect(first.isClosed, isTrue);
      expect(peers.sessions, hasLength(2));
      expect(bloc.state.remoteSessionId, otherSessionId);
    });

    test('a peer connection that could not be created is a failure', () async {
      peers.createError = StateError('no browser');

      await negotiate();

      expect(bloc.state, isA<WebRtcFailed>());
      expect(
        (bloc.state as WebRtcFailed).reason,
        WebRtcFailureReason.negotiationFailed,
      );
      expect(signaling.sentOffers, isEmpty);
    });
  });

  group('relaying the offer', () {
    test('a refused relay ends the negotiation and releases the peer', () async {
      signaling.offerResult = const SignalingRelayRefused(
        remoteSessionId: sessionId,
        error: SignalingErrorCode.notJoined,
      );

      await negotiate();

      expect(bloc.state, isA<WebRtcFailed>());
      expect(
        (bloc.state as WebRtcFailed).reason,
        WebRtcFailureReason.offerNotDelivered,
      );
      expect(peers.last.isClosed, isTrue);
      // Never resent: no retry loop of the same offer.
      expect(signaling.sentOffers, hasLength(1));
    });

    test('an offer that never reached the wire is not a negotiation', () async {
      signaling.offerResult = const SignalingRelayNotSent(
        SignalingNotSentReason.notConnected,
      );

      await negotiate();

      expect(bloc.state, isA<WebRtcFailed>());
      expect(peers.last.isClosed, isTrue);
    });

    test('an unanswered relay is not a negotiation either', () async {
      signaling.offerResult = const SignalingRelayUnanswered(
        SignalingRelayUnansweredReason.timeout,
      );

      await negotiate();

      expect(bloc.state, isA<WebRtcFailed>());
    });

    test('a delivered offer does not mean a connection', () async {
      await negotiate();

      expect(bloc.state, isA<WebRtcConnecting>());
      expect(bloc.state.isConnected, isFalse);
    });
  });

  group('local ICE candidates', () {
    test('none is relayed before the offer was acknowledged', () async {
      final gate = Completer<void>();
      signaling.offerGate = gate.future;
      await negotiate();
      expect(bloc.state, isA<WebRtcOffering>());

      // setLocalDescription already started the gathering.
      peers.last
        ..emitLocalCandidate('A')
        ..emitLocalCandidate('B');
      await settle();

      expect(signaling.sentIceCandidates, isEmpty);

      gate.complete();
      await settle();

      // Flushed in the order WebRTC produced them, after the offer.
      expect(signaling.relayLog, ['offer', 'ice:A', 'ice:B']);
    });

    test('candidates gathered afterwards go out as they come', () async {
      await negotiate();

      peers.last.emitLocalCandidate('C');
      await settle();
      peers.last.emitLocalCandidate('D');
      await settle();

      expect(
        signaling.sentIceCandidates.map((candidate) => candidate.candidate),
        ['C', 'D'],
      );
    });

    test('candidates are relayed with their sdpMid and sdpMLineIndex', () async {
      await negotiate();

      peers.last.emitLocalCandidate('candidate:1 1 udp 1 192.0.2.10 1 typ host');
      await settle();

      final relayed = signaling.sentIceCandidates.single;
      expect(relayed.remoteSessionId, sessionId);
      expect(relayed.sdpMid, '0');
      expect(relayed.sdpMLineIndex, 0);
    });

    test('a refused candidate never closes a connected session', () async {
      await connect();
      signaling.iceCandidateResult = const SignalingRelayRefused(
        remoteSessionId: sessionId,
        error: SignalingErrorCode.unavailable,
      );

      peers.last.emitLocalCandidate('E');
      await settle();

      expect(bloc.state, isA<WebRtcConnected>());
      expect(peers.last.isClosed, isFalse);
    });
  });

  group('incoming answer', () {
    test('it is applied once', () async {
      await negotiate();

      signaling.emitAnswer(sessionId);
      await settle();

      expect(peers.last.appliedAnswers, hasLength(1));
      expect(peers.last.appliedAnswers.single.remoteSessionId, sessionId);
    });

    test('a duplicate answer is ignored', () async {
      await negotiate();

      signaling.emitAnswer(sessionId);
      await settle();
      signaling.emitAnswer(sessionId);
      await settle();

      expect(peers.last.appliedAnswers, hasLength(1));
      expect(bloc.state, isA<WebRtcConnecting>());
    });

    test('an answer for another session is ignored', () async {
      await negotiate();

      signaling.emitAnswer(otherSessionId);
      await settle();

      expect(peers.last.appliedAnswers, isEmpty);
    });

    test('an answer without a negotiation creates nothing', () async {
      signaling.emitAnswer(sessionId);
      await settle();

      expect(peers.sessions, isEmpty);
      expect(bloc.state, isA<WebRtcIdle>());
    });

    test('an answer the browser rejected fails the negotiation', () async {
      await negotiate();
      peers.last.applyAnswerError = StateError('bad sdp');

      signaling.emitAnswer(sessionId);
      await settle();

      expect(bloc.state, isA<WebRtcFailed>());
      expect(peers.last.isClosed, isTrue);
    });
  });

  group('incoming offer', () {
    test('the console is the offerer and never answers one', () async {
      await negotiate();

      signaling.emitOffer(sessionId);
      await settle();

      expect(signaling.sentAnswers, isEmpty);
      // And it does not tear the current negotiation down either.
      expect(bloc.state, isA<WebRtcConnecting>());
      expect(peers.last.isClosed, isFalse);
    });

    test('an offer without a negotiation creates no peer connection', () async {
      signaling.emitOffer(sessionId);
      await settle();

      expect(peers.sessions, isEmpty);
      expect(signaling.sentAnswers, isEmpty);
    });
  });

  group('remote ICE candidates', () {
    test('none is applied before the answer', () async {
      await negotiate();

      signaling
        ..emitIceCandidate(sessionId, 'A')
        ..emitIceCandidate(sessionId, 'B');
      await settle();

      expect(peers.last.addedIceCandidates, isEmpty);

      signaling.emitAnswer(sessionId);
      await settle();

      // The remote description first, then the queue, in order.
      expect(peers.last.calls, ['channel', 'offer', 'answer', 'candidate', 'candidate']);
      expect(
        peers.last.addedIceCandidates.map((candidate) => candidate.candidate),
        ['A', 'B'],
      );
    });

    test('candidates arriving after the answer are applied directly', () async {
      await negotiate();
      signaling.emitAnswer(sessionId);
      await settle();

      signaling.emitIceCandidate(sessionId, 'C');
      await settle();

      expect(
        peers.last.addedIceCandidates.map((candidate) => candidate.candidate),
        ['C'],
      );
    });

    test('an end-of-candidates marker is not discarded', () async {
      await negotiate();
      signaling.emitAnswer(sessionId);
      await settle();

      // The contract allows the empty candidate string.
      signaling.emitIceCandidate(sessionId, '');
      await settle();

      expect(peers.last.addedIceCandidates.single.isEndOfCandidates, isTrue);
    });

    test('a candidate for another session is ignored', () async {
      await negotiate();
      signaling.emitAnswer(sessionId);
      await settle();

      signaling.emitIceCandidate(otherSessionId, 'X');
      await settle();

      expect(peers.last.addedIceCandidates, isEmpty);
    });

    test('a candidate the browser refused does not break anything', () async {
      await connect();
      signaling.emitAnswer(sessionId);
      await settle();
      peers.last.addIceCandidateError = StateError('bad candidate');

      signaling.emitIceCandidate(sessionId, 'Y');
      await settle();

      expect(bloc.state, isA<WebRtcConnected>());
      expect(peers.last.isClosed, isFalse);
    });
  });

  group('peer connection states', () {
    test('connecting is reported while the offer is still out', () async {
      final gate = Completer<void>();
      signaling.offerGate = gate.future;
      await negotiate();

      peers.last.emitPeerState(WebRtcPeerConnectionState.connecting);
      await settle();

      expect(bloc.state, isA<WebRtcConnecting>());
      gate.complete();
      await settle();
    });

    test('connected is the moment the peers can talk', () async {
      await negotiate();

      peers.last.emitPeerState(WebRtcPeerConnectionState.connected);
      await settle();

      expect(bloc.state, isA<WebRtcConnected>());
      expect(bloc.state.isConnected, isTrue);
      // The RemoteSession is not touched: no CONNECTING -> ACTIVE is invented.
      expect(bloc.state.remoteSessionId, sessionId);
    });

    test('disconnected is transient and destroys nothing', () async {
      await connect();

      peers.last.emitPeerState(WebRtcPeerConnectionState.disconnected);
      await settle();

      expect(bloc.state, isA<WebRtcInterrupted>());
      expect(peers.last.isClosed, isFalse);

      // And it may come back on its own.
      peers.last.emitPeerState(WebRtcPeerConnectionState.connected);
      await settle();
      expect(bloc.state, isA<WebRtcConnected>());
    });

    test('failed releases the negotiation without retrying', () async {
      await negotiate();

      peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      await settle();

      expect(bloc.state, isA<WebRtcFailed>());
      expect(
        (bloc.state as WebRtcFailed).reason,
        WebRtcFailureReason.connectionFailed,
      );
      expect(peers.last.isClosed, isTrue);
      expect(signaling.sentOffers, hasLength(1));
    });

    test('closed is reported and releases the resources', () async {
      await negotiate();

      peers.last.emitPeerState(WebRtcPeerConnectionState.closed);
      await settle();

      expect(bloc.state, isA<WebRtcClosed>());
      expect(peers.last.isClosed, isTrue);
    });

    test('new changes nothing on its own', () async {
      await negotiate();

      peers.last.emitPeerState(WebRtcPeerConnectionState.fresh);
      await settle();

      expect(bloc.state, isA<WebRtcConnecting>());
    });
  });

  group('control channel', () {
    test('its state is tracked apart from the peer connection', () async {
      await negotiate();

      peers.last.emitControlChannelState(WebRtcDataChannelState.connecting);
      await settle();
      expect(bloc.state.controlChannelState, WebRtcDataChannelState.connecting);
      expect(bloc.state.isControlChannelOpen, isFalse);

      peers.last.emitControlChannelState(WebRtcDataChannelState.open);
      await settle();
      expect(bloc.state.isControlChannelOpen, isTrue);
      // Open channel, peer connection not connected yet: two different facts.
      expect(bloc.state.isConnected, isFalse);

      peers.last.emitControlChannelState(WebRtcDataChannelState.closing);
      await settle();
      expect(bloc.state.controlChannelState, WebRtcDataChannelState.closing);

      peers.last.emitControlChannelState(WebRtcDataChannelState.closed);
      await settle();
      expect(bloc.state.isControlChannelOpen, isFalse);
    });

    test('a connected peer keeps its channel state', () async {
      await connect();

      expect(bloc.state, isA<WebRtcConnected>());
      expect(bloc.state.isControlChannelOpen, isTrue);
    });

    test('a message on the channel is not acted upon yet', () async {
      await connect();
      final before = bloc.state;

      peers.last.emitControlChannelMessage('anything');
      await settle();

      expect(bloc.state, before);
    });
  });

  group('signaling loss', () {
    test('an incomplete negotiation is cleaned up', () async {
      await negotiate();

      bloc.add(const WebRtcSignalingLost());
      await settle();

      expect(bloc.state, isA<WebRtcIdle>());
      expect(peers.last.isClosed, isTrue);
    });

    test('a connected peer connection is preserved', () async {
      await connect();

      bloc.add(const WebRtcSignalingLost());
      await settle();

      expect(bloc.state, isA<WebRtcConnected>());
      expect(peers.last.isClosed, isFalse);
    });

    test('an interrupted one is preserved too', () async {
      await connect();
      peers.last.emitPeerState(WebRtcPeerConnectionState.disconnected);
      await settle();

      bloc.add(const WebRtcSignalingLost());
      await settle();

      expect(bloc.state, isA<WebRtcInterrupted>());
      expect(peers.last.isClosed, isFalse);
    });

    test('no second offer is created once signaling comes back', () async {
      await connect();
      bloc.add(const WebRtcSignalingLost());
      await settle();

      // Reconnected, rejoined, the tablet is still in the room.
      await negotiate();

      expect(signaling.sentOffers, hasLength(1));
      expect(peers.sessions, hasLength(1));
      expect(bloc.state, isA<WebRtcConnected>());
    });

    test('a new negotiation starts after an incomplete one was dropped', () async {
      await negotiate();
      bloc.add(const WebRtcSignalingLost());
      await settle();

      await negotiate();

      expect(peers.sessions, hasLength(2));
      expect(signaling.sentOffers, hasLength(2));
    });
  });

  group('the assistance ends', () {
    test('everything is closed and both queues are cleared', () async {
      await negotiate();
      // A remote candidate waiting for an answer that will never come.
      signaling.emitIceCandidate(sessionId, 'A');
      await settle();

      bloc.add(const WebRtcSessionTerminated());
      await settle();

      expect(bloc.state, isA<WebRtcIdle>());
      expect(peers.last.isClosed, isTrue);

      // Nothing of the previous negotiation is left to be applied.
      signaling.emitAnswer(sessionId);
      await settle();
      expect(peers.last.appliedAnswers, isEmpty);
      expect(peers.last.addedIceCandidates, isEmpty);
    });

    test('terminating without a negotiation is harmless', () async {
      bloc.add(const WebRtcSessionTerminated());
      await settle();

      expect(bloc.state, isA<WebRtcIdle>());
      expect(peers.sessions, isEmpty);
    });

    test('closing the BLoC releases the peer connection', () async {
      await negotiate();
      final session = peers.last;

      await bloc.close();

      expect(session.isClosed, isTrue);
      // Rebuilt so the tearDown has something to close.
      build();
    });
  });

  group('generations', () {
    test('a negotiation abandoned mid-flight never touches the state', () async {
      final gate = Completer<void>();
      signaling.offerGate = gate.future;
      await negotiate();
      expect(bloc.state, isA<WebRtcOffering>());

      bloc.add(const WebRtcSessionTerminated());
      await settle();
      expect(bloc.state, isA<WebRtcIdle>());
      expect(peers.last.isClosed, isTrue);

      // The relay finally answers, for a negotiation nobody waits for.
      gate.complete();
      await settle();

      expect(bloc.state, isA<WebRtcIdle>());
      expect(signaling.sentIceCandidates, isEmpty);
    });

    test('a peer connection created too late is closed at once', () async {
      final gate = Completer<void>();
      peers.createGate = gate.future;
      bloc.add(const WebRtcNegotiationRequested(sessionId));
      await settle();

      bloc.add(const WebRtcSessionTerminated());
      await settle();
      gate.complete();
      await settle();

      expect(peers.sessions.single.isClosed, isTrue);
      expect(signaling.sentOffers, isEmpty);
      expect(bloc.state, isA<WebRtcIdle>());
    });

    test('a callback of a replaced peer connection is dropped', () async {
      await negotiate();
      final first = peers.last;

      await negotiate(otherSessionId);
      // The old peer connection is closed, and anything it still had to say
      // belongs to a generation nobody listens to.
      first.emitLocalCandidate('OLD');
      await settle();

      expect(
        signaling.sentIceCandidates.map((candidate) => candidate.candidate),
        isNot(contains('OLD')),
      );
      expect(bloc.state.remoteSessionId, otherSessionId);
    });
  });
}
