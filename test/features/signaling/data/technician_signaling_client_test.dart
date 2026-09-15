import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/signaling/data/signaling_contract.dart';
import 'package:remote_control_web/features/signaling/data/technician_signaling_client_impl.dart';
import 'package:remote_control_web/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_web/features/signaling/domain/entities/signaling_limits.dart';
import 'package:remote_control_web/features/signaling/domain/entities/signaling_origin.dart';
import 'package:remote_control_web/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_web/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_web/features/signaling/domain/entities/webrtc_session_description.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/signaling_error_code.dart';

import '../../../support/realtime_test_doubles.dart';

void main() {
  const sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';
  const otherSessionId = '9a0f3d1b-4c88-9e64-6f2a-5c7e8b103d1b';
  const sdp = 'v=0\r\no=- 46117 2 IN IP4 127.0.0.1\r\n';
  const candidateLine =
      'candidate:842163049 1 udp 1677729535 192.0.2.10 54321 typ srflx';

  const offer = WebRtcOffer(remoteSessionId: sessionId, sdp: sdp);
  const answer = WebRtcAnswer(remoteSessionId: sessionId, sdp: sdp);
  const iceCandidate = WebRtcIceCandidate(
    remoteSessionId: sessionId,
    candidate: candidateLine,
    sdpMid: '0',
    sdpMLineIndex: 0,
  );

  late FakeTechnicianRealtimeClient transport;
  late TechnicianSignalingClientImpl client;

  setUp(() {
    transport = FakeTechnicianRealtimeClient();
    client = TechnicianSignalingClientImpl(
      transport: transport,
      ackTimeout: const Duration(milliseconds: 50),
    );
  });

  tearDown(() async {
    await client.dispose();
    await transport.dispose();
  });

  /// The socket is connected and the room was joined.
  void joined([String id = sessionId]) => transport.joinRoom(id);

  /// Sends and acknowledges in one step.
  Future<SignalingRelayResult> send(
    Future<SignalingRelayResult> Function() relay,
    Object? ack,
  ) async {
    final pending = relay();
    transport.answerRelayAck(ack);
    return pending;
  }

  group('outgoing offer', () {
    test('a joined session emits the documented event and payload', () async {
      joined();

      final result = await send(
        () => client.sendOffer(offer),
        {'delivered': true, 'remoteSessionId': sessionId},
      );

      expect(transport.emittedSignaling.single.event, 'webrtc:offer');
      expect(transport.emittedSignaling.single.payload, {
        'remoteSessionId': sessionId,
        'sdp': sdp,
      });
      expect(result, const SignalingRelayDelivered(sessionId));
    });
  });

  group('outgoing answer', () {
    test('a joined session emits webrtc:answer', () async {
      joined();

      final result = await send(
        () => client.sendAnswer(answer),
        {'delivered': true, 'remoteSessionId': sessionId},
      );

      expect(transport.emittedSignaling.single.event, 'webrtc:answer');
      expect(transport.emittedSignaling.single.payload, {
        'remoteSessionId': sessionId,
        'sdp': sdp,
      });
      expect(result.isDelivered, isTrue);
    });
  });

  group('outgoing ICE candidate', () {
    test('a joined session emits webrtc:ice-candidate', () async {
      joined();

      final result = await send(
        () => client.sendIceCandidate(iceCandidate),
        {'delivered': true, 'remoteSessionId': sessionId},
      );

      expect(
        transport.emittedSignaling.single.event,
        'webrtc:ice-candidate',
      );
      expect(transport.emittedSignaling.single.payload, {
        'remoteSessionId': sessionId,
        'candidate': candidateLine,
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      });
      expect(result.isDelivered, isTrue);
    });

    test('absent optional fields travel as explicit nulls', () async {
      joined();

      await send(
        () => client.sendIceCandidate(
          const WebRtcIceCandidate(
            remoteSessionId: sessionId,
            candidate: candidateLine,
          ),
        ),
        {'delivered': true, 'remoteSessionId': sessionId},
      );

      final payload = transport.emittedSignaling.single.payload;
      expect(payload.keys, [
        'remoteSessionId',
        'candidate',
        'sdpMid',
        'sdpMLineIndex',
      ]);
      expect(payload['sdpMid'], isNull);
      expect(payload['sdpMLineIndex'], isNull);
    });

    test('the empty candidate is sent as the end-of-candidates it is', () async {
      joined();

      await send(
        () => client.sendIceCandidate(
          const WebRtcIceCandidate(remoteSessionId: sessionId, candidate: ''),
        ),
        {'delivered': true, 'remoteSessionId': sessionId},
      );

      expect(transport.emittedSignaling.single.payload['candidate'], '');
    });
  });

  group('without a joined session', () {
    test('an offer never reaches the wire', () async {
      final result = await client.sendOffer(offer);

      expect(transport.emittedSignaling, isEmpty);
      expect(
        result,
        const SignalingRelayNotSent(SignalingNotSentReason.notJoined),
      );
    });

    test('an answer never reaches the wire', () async {
      final result = await client.sendAnswer(answer);

      expect(transport.emittedSignaling, isEmpty);
      expect(
        result,
        const SignalingRelayNotSent(SignalingNotSentReason.notJoined),
      );
    });

    test('a candidate never reaches the wire', () async {
      final result = await client.sendIceCandidate(iceCandidate);

      expect(transport.emittedSignaling, isEmpty);
      expect(
        result,
        const SignalingRelayNotSent(SignalingNotSentReason.notJoined),
      );
    });

    test('a lost socket is reported apart from a lost room', () async {
      joined();
      transport.canEmitSignaling = false;

      final result = await client.sendOffer(offer);

      expect(transport.emittedSignaling, isEmpty);
      expect(
        result,
        const SignalingRelayNotSent(SignalingNotSentReason.notConnected),
      );
    });
  });

  group('wrong session', () {
    test('joined to A, sending for B emits nothing', () async {
      joined();

      final result = await client.sendOffer(
        const WebRtcOffer(remoteSessionId: otherSessionId, sdp: sdp),
      );

      expect(transport.emittedSignaling, isEmpty);
      expect(
        result,
        const SignalingRelayNotSent(SignalingNotSentReason.sessionMismatch),
      );
      // The joined session is not replaced by the one that was asked for.
      expect(client.joinedRemoteSessionId, sessionId);
    });

    test('the same rule applies to answers and candidates', () async {
      joined();

      final answerResult = await client.sendAnswer(
        const WebRtcAnswer(remoteSessionId: otherSessionId, sdp: sdp),
      );
      final candidateResult = await client.sendIceCandidate(
        const WebRtcIceCandidate(
          remoteSessionId: otherSessionId,
          candidate: candidateLine,
        ),
      );

      expect(transport.emittedSignaling, isEmpty);
      expect(
        answerResult,
        const SignalingRelayNotSent(SignalingNotSentReason.sessionMismatch),
      );
      expect(
        candidateResult,
        const SignalingRelayNotSent(SignalingNotSentReason.sessionMismatch),
      );
    });
  });

  group('local validation', () {
    test('an SDP at the limit is sent, one over it is not', () async {
      joined();

      await send(
        () => client.sendOffer(
          WebRtcOffer(
            remoteSessionId: sessionId,
            sdp: 'x' * SignalingLimits.maxSdpLength,
          ),
        ),
        {'delivered': true, 'remoteSessionId': sessionId},
      );
      expect(transport.emittedSignaling, hasLength(1));

      final result = await client.sendOffer(
        WebRtcOffer(
          remoteSessionId: sessionId,
          sdp: 'x' * (SignalingLimits.maxSdpLength + 1),
        ),
      );

      expect(transport.emittedSignaling, hasLength(1));
      expect(
        result,
        const SignalingRelayNotSent(
          SignalingNotSentReason.invalidPayload,
          violation: SignalingPayloadViolation.sdpTooLong,
        ),
      );
    });

    test('an empty SDP is never emitted', () async {
      joined();

      final result = await client.sendAnswer(
        const WebRtcAnswer(remoteSessionId: sessionId, sdp: ''),
      );

      expect(transport.emittedSignaling, isEmpty);
      expect(
        (result as SignalingRelayNotSent).violation,
        SignalingPayloadViolation.emptySdp,
      );
    });

    test('a candidate at the limit is sent, one over it is not', () async {
      joined();

      await send(
        () => client.sendIceCandidate(
          WebRtcIceCandidate(
            remoteSessionId: sessionId,
            candidate: 'c' * SignalingLimits.maxCandidateLength,
          ),
        ),
        {'delivered': true, 'remoteSessionId': sessionId},
      );
      expect(transport.emittedSignaling, hasLength(1));

      final result = await client.sendIceCandidate(
        WebRtcIceCandidate(
          remoteSessionId: sessionId,
          candidate: 'c' * (SignalingLimits.maxCandidateLength + 1),
        ),
      );

      expect(transport.emittedSignaling, hasLength(1));
      expect(
        (result as SignalingRelayNotSent).violation,
        SignalingPayloadViolation.candidateTooLong,
      );
    });

    test('sdpMid over 64 characters is never emitted', () async {
      joined();

      final result = await client.sendIceCandidate(
        WebRtcIceCandidate(
          remoteSessionId: sessionId,
          candidate: candidateLine,
          sdpMid: 'm' * (SignalingLimits.maxSdpMidLength + 1),
        ),
      );

      expect(transport.emittedSignaling, isEmpty);
      expect(
        (result as SignalingRelayNotSent).violation,
        SignalingPayloadViolation.sdpMidTooLong,
      );
    });

    test('sdpMLineIndex outside 0–255 is never emitted', () async {
      joined();

      for (final index in [-1, 256]) {
        final result = await client.sendIceCandidate(
          WebRtcIceCandidate(
            remoteSessionId: sessionId,
            candidate: candidateLine,
            sdpMLineIndex: index,
          ),
        );

        expect(
          (result as SignalingRelayNotSent).violation,
          SignalingPayloadViolation.sdpMLineIndexOutOfRange,
          reason: 'sdpMLineIndex $index',
        );
      }

      expect(transport.emittedSignaling, isEmpty);

      // The bounds themselves are valid.
      await send(
        () => client.sendIceCandidate(
          const WebRtcIceCandidate(
            remoteSessionId: sessionId,
            candidate: candidateLine,
            sdpMLineIndex: SignalingLimits.maxSdpMLineIndex,
          ),
        ),
        {'delivered': true, 'remoteSessionId': sessionId},
      );
      expect(transport.emittedSignaling, hasLength(1));
    });
  });

  group('relay ACK', () {
    test('delivered: true means the backend relayed it, nothing more', () async {
      joined();

      final result = await send(
        () => client.sendOffer(offer),
        {'delivered': true, 'remoteSessionId': sessionId},
      );

      expect(result, isA<SignalingRelayDelivered>());
      expect(
        (result as SignalingRelayDelivered).remoteSessionId,
        sessionId,
      );
      // Nothing here claims the peer applied anything: the room may even be
      // empty, and the message is then silently dropped by the backend.
      expect(client.joinedRemoteSessionId, sessionId);
    });

    test('INVALID_PAYLOAD is reported and changes nothing else', () async {
      joined();

      final result = await send(
        () => client.sendOffer(offer),
        {'delivered': false, 'error': 'INVALID_PAYLOAD'},
      );

      expect(
        (result as SignalingRelayRefused).error,
        SignalingErrorCode.invalidPayload,
      );
      // A contract bug does not cost the room membership.
      expect(client.joinedRemoteSessionId, sessionId);
      expect(transport.forgetJoinedCount, 0);
    });

    test('NOT_JOINED drops the membership and is published', () async {
      joined();
      final refusals = <SignalingRelayRefused>[];
      client.relayRefusals.listen(refusals.add);

      final result = await send(
        () => client.sendOffer(offer),
        {'delivered': false, 'error': 'NOT_JOINED'},
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        (result as SignalingRelayRefused).error,
        SignalingErrorCode.notJoined,
      );
      // The socket is not in the room, whatever the join ACK said earlier.
      expect(client.joinedRemoteSessionId, isNull);
      expect(transport.forgetJoinedCount, 1);
      expect(refusals.single.error, SignalingErrorCode.notJoined);
      expect(refusals.single.remoteSessionId, sessionId);
    });

    test('a further relay after NOT_JOINED never reaches the wire', () async {
      joined();
      await send(() => client.sendOffer(offer), {
        'delivered': false,
        'error': 'NOT_JOINED',
      });

      final result = await client.sendIceCandidate(iceCandidate);

      expect(transport.emittedSignaling, hasLength(1));
      expect(
        result,
        const SignalingRelayNotSent(SignalingNotSentReason.notJoined),
      );
    });

    test('UNAUTHORIZED is published and keeps the membership', () async {
      joined();
      final refusals = <SignalingRelayRefused>[];
      client.relayRefusals.listen(refusals.add);

      final result = await send(
        () => client.sendOffer(offer),
        {'delivered': false, 'error': 'UNAUTHORIZED'},
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        (result as SignalingRelayRefused).error,
        SignalingErrorCode.unauthorized,
      );
      expect(refusals.single.error, SignalingErrorCode.unauthorized);
      // The room is still joined; what changed is the session, and only REST
      // can say what it became.
      expect(client.joinedRemoteSessionId, sessionId);
    });

    test('UNAVAILABLE is published as the transient refusal it is', () async {
      joined();
      final refusals = <SignalingRelayRefused>[];
      client.relayRefusals.listen(refusals.add);

      final result = await send(
        () => client.sendAnswer(answer),
        {'delivered': false, 'error': 'UNAVAILABLE'},
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        (result as SignalingRelayRefused).error,
        SignalingErrorCode.unavailable,
      );
      expect(refusals.single.error, SignalingErrorCode.unavailable);
      expect(client.joinedRemoteSessionId, sessionId);
    });

    test('an unknown code is a refusal and triggers nothing', () async {
      joined();
      final refusals = <SignalingRelayRefused>[];
      client.relayRefusals.listen(refusals.add);

      final result = await send(
        () => client.sendOffer(offer),
        {'delivered': false, 'error': 'RATE_LIMITED'},
      );
      await Future<void>.delayed(Duration.zero);

      final refused = result as SignalingRelayRefused;
      expect(refused.error.wireValue, 'RATE_LIMITED');
      expect(refused.error.isKnown, isFalse);
      expect(refusals, hasLength(1));
      expect(client.joinedRemoteSessionId, sessionId);
    });

    test('a malformed ACK is unanswered, never a delivery', () async {
      joined();
      final refusals = <SignalingRelayRefused>[];
      client.relayRefusals.listen(refusals.add);

      final result = await send(() => client.sendOffer(offer), 'ok');
      await Future<void>.delayed(Duration.zero);

      expect(
        result,
        const SignalingRelayUnanswered(
          SignalingRelayUnansweredReason.malformedAck,
        ),
      );
      expect(refusals, isEmpty);
    });

    test('an acknowledgement that never arrives does not hang', () async {
      joined();

      final result = await client.sendOffer(offer);

      expect(transport.emittedSignaling, hasLength(1));
      expect(
        result,
        const SignalingRelayUnanswered(SignalingRelayUnansweredReason.timeout),
      );
    });

    test('an ACK arriving after the timeout changes nothing', () async {
      joined();
      final refusals = <SignalingRelayRefused>[];
      client.relayRefusals.listen(refusals.add);

      final result = await client.sendOffer(offer);
      expect(result, isA<SignalingRelayUnanswered>());

      // Too late: the operation it belongs to was given up on.
      transport.answerRelayAck({'delivered': false, 'error': 'NOT_JOINED'});
      await Future<void>.delayed(Duration.zero);

      expect(refusals, isEmpty);
      expect(client.joinedRemoteSessionId, sessionId);
      expect(transport.forgetJoinedCount, 0);
    });
  });

  group('incoming', () {
    test('a valid offer becomes OfferReceived', () async {
      joined();
      final received = client.incoming.first;

      transport.emitSignalingEvent(SignalingContract.offerEvent, {
        'remoteSessionId': sessionId,
        'from': 'DEVICE',
        'sdp': sdp,
      });

      final message = await received;
      expect(message, isA<OfferReceived>());
      final offerMessage = message as OfferReceived;
      expect(offerMessage.offer.sdp, sdp);
      expect(offerMessage.origin, SignalingOrigin.device);
      // Nothing was applied and nothing was answered: this stage transports.
      expect(transport.emittedSignaling, isEmpty);
    });

    test('a valid answer becomes AnswerReceived', () async {
      joined();
      final received = client.incoming.first;

      transport.emitSignalingEvent(SignalingContract.answerEvent, {
        'remoteSessionId': sessionId,
        'from': 'DEVICE',
        'sdp': sdp,
      });

      expect(await received, isA<AnswerReceived>());
      expect(transport.emittedSignaling, isEmpty);
    });

    test('a valid candidate becomes IceCandidateReceived', () async {
      joined();
      final received = client.incoming.first;

      transport.emitSignalingEvent(SignalingContract.iceCandidateEvent, {
        'remoteSessionId': sessionId,
        'from': 'DEVICE',
        'candidate': candidateLine,
        'sdpMid': '0',
        'sdpMLineIndex': 1,
      });

      final message = await received as IceCandidateReceived;
      expect(message.candidate.candidate, candidateLine);
      expect(message.candidate.sdpMid, '0');
      expect(message.candidate.sdpMLineIndex, 1);
      expect(transport.emittedSignaling, isEmpty);
    });

    test('a malformed payload is ignored without crashing', () async {
      joined();
      final messages = <RemoteSignalingMessage>[];
      client.incoming.listen(messages.add);

      for (final data in <Object?>[
        null,
        'offer',
        <Object?>[],
        <String, Object?>{},
        {'sdp': sdp},
        {'remoteSessionId': sessionId},
        {'remoteSessionId': sessionId, 'sdp': 42},
        {'remoteSessionId': 42, 'sdp': sdp},
      ]) {
        transport.emitSignalingEvent(SignalingContract.offerEvent, data);
      }
      await Future<void>.delayed(Duration.zero);

      expect(messages, isEmpty);
    });

    test('a message for another remote session is ignored', () async {
      joined();
      final messages = <RemoteSignalingMessage>[];
      client.incoming.listen(messages.add);

      transport.emitSignalingEvent(SignalingContract.offerEvent, {
        'remoteSessionId': otherSessionId,
        'from': 'DEVICE',
        'sdp': sdp,
      });
      await Future<void>.delayed(Duration.zero);

      expect(messages, isEmpty);
      // The received id is never adopted.
      expect(client.joinedRemoteSessionId, sessionId);
    });

    test('nothing is delivered while no session is joined', () async {
      final messages = <RemoteSignalingMessage>[];
      client.incoming.listen(messages.add);

      transport.emitSignalingEvent(SignalingContract.offerEvent, {
        'remoteSessionId': sessionId,
        'from': 'DEVICE',
        'sdp': sdp,
      });
      await Future<void>.delayed(Duration.zero);

      expect(messages, isEmpty);
    });

    test('a late event after the session was left is discarded', () async {
      joined();
      final messages = <RemoteSignalingMessage>[];
      client.incoming.listen(messages.add);

      transport.emitSignalingEvent(SignalingContract.iceCandidateEvent, {
        'remoteSessionId': sessionId,
        'from': 'DEVICE',
        'candidate': candidateLine,
      });
      await Future<void>.delayed(Duration.zero);
      expect(messages, hasLength(1));

      // The assistance ended: signaling is reset.
      transport.forgetJoinedRemoteSession();
      transport.emitSignalingEvent(SignalingContract.iceCandidateEvent, {
        'remoteSessionId': sessionId,
        'from': 'DEVICE',
        'candidate': candidateLine,
      });
      await Future<void>.delayed(Duration.zero);

      expect(messages, hasLength(1));
    });

    test('a reconnection stops delivery until the room is joined again', () async {
      joined();
      final messages = <RemoteSignalingMessage>[];
      client.incoming.listen(messages.add);

      transport.emitReconnecting();
      transport.emitSignalingEvent(SignalingContract.offerEvent, {
        'remoteSessionId': sessionId,
        'from': 'DEVICE',
        'sdp': sdp,
      });
      await Future<void>.delayed(Duration.zero);
      expect(messages, isEmpty);

      joined();
      transport.emitSignalingEvent(SignalingContract.offerEvent, {
        'remoteSessionId': sessionId,
        'from': 'DEVICE',
        'sdp': sdp,
      });
      await Future<void>.delayed(Duration.zero);

      expect(messages, hasLength(1));
    });
  });
}
