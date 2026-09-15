import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/signaling/data/models/remote_signaling_message_dto.dart';
import 'package:remote_control_web/features/signaling/data/models/signaling_relay_ack_dto.dart';
import 'package:remote_control_web/features/signaling/data/signaling_contract.dart';
import 'package:remote_control_web/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_web/features/signaling/domain/entities/signaling_limits.dart';
import 'package:remote_control_web/features/signaling/domain/entities/signaling_origin.dart';
import 'package:remote_control_web/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/signaling_error_code.dart';

/// Everything asserted here comes from the *Signaling* section of
/// `docs/backend/REALTIME.md`. The file is never modified to fit the client:
/// if these tests and the document disagree, the client is wrong.
void main() {
  const sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';
  const sdp = 'v=0\r\no=- 46117 2 IN IP4 127.0.0.1\r\n';
  const candidateLine =
      'candidate:842163049 1 udp 1677729535 192.0.2.10 54321 typ srflx';

  group('event names', () {
    test('are the three documented ones', () {
      expect(SignalingContract.offerEvent, 'webrtc:offer');
      expect(SignalingContract.answerEvent, 'webrtc:answer');
      expect(SignalingContract.iceCandidateEvent, 'webrtc:ice-candidate');
    });

    test('the same names are used in both directions', () {
      // The backend relays under the event name it received; only `from` is
      // added on the way out.
      expect(SignalingContract.relayEvents, [
        'webrtc:offer',
        'webrtc:answer',
        'webrtc:ice-candidate',
      ]);
    });
  });

  group('outgoing webrtc:offer', () {
    test('the payload is exactly { remoteSessionId, sdp }', () {
      final payload = SignalingContract.sessionDescriptionPayload(
        remoteSessionId: sessionId,
        sdp: sdp,
      );

      expect(payload, {'remoteSessionId': sessionId, 'sdp': sdp});
      expect(payload.keys, ['remoteSessionId', 'sdp']);
    });

    test('nothing else rides along', () {
      final payload = SignalingContract.sessionDescriptionPayload(
        remoteSessionId: sessionId,
        sdp: sdp,
      );

      // `from` is added by the server; a client that sent it — or any other
      // unknown property — would earn INVALID_PAYLOAD.
      expect(payload.containsKey('from'), isFalse);
      expect(payload.containsKey('type'), isFalse);
      expect(payload.containsKey('technicianId'), isFalse);
      expect(payload.containsKey('participant'), isFalse);
    });
  });

  group('outgoing webrtc:answer', () {
    test('is identical in payload to webrtc:offer', () {
      // "Identical to webrtc:offer in payload, constraints, relayed shape and
      // ACK. Only the event name differs."
      final offer = SignalingContract.sessionDescriptionPayload(
        remoteSessionId: sessionId,
        sdp: sdp,
      );
      final answer = SignalingContract.sessionDescriptionPayload(
        remoteSessionId: sessionId,
        sdp: sdp,
      );

      expect(answer, offer);
    });
  });

  group('outgoing webrtc:ice-candidate', () {
    test('the payload carries the four documented fields', () {
      final payload = SignalingContract.iceCandidatePayload(
        remoteSessionId: sessionId,
        candidate: candidateLine,
        sdpMid: '0',
        sdpMLineIndex: 0,
      );

      expect(payload, {
        'remoteSessionId': sessionId,
        'candidate': candidateLine,
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      });
    });

    test('the optional fields are sent explicitly as null, never dropped', () {
      final payload = SignalingContract.iceCandidatePayload(
        remoteSessionId: sessionId,
        candidate: candidateLine,
        sdpMid: null,
        sdpMLineIndex: null,
      );

      // The contract accepts both forms — "may be omitted or sent explicitly
      // as null" — and the explicit one keeps a single payload shape.
      expect(payload.containsKey('sdpMid'), isTrue);
      expect(payload.containsKey('sdpMLineIndex'), isTrue);
      expect(payload['sdpMid'], isNull);
      expect(payload['sdpMLineIndex'], isNull);
    });

    test('the empty candidate is a payload like any other', () {
      // "The empty candidate string is accepted since some implementations use
      // it to signal end-of-candidates."
      final payload = SignalingContract.iceCandidatePayload(
        remoteSessionId: sessionId,
        candidate: '',
        sdpMid: null,
        sdpMLineIndex: null,
      );

      expect(payload['candidate'], '');
    });
  });

  group('documented limits', () {
    test('match the contract table', () {
      expect(SignalingLimits.minSdpLength, 1);
      expect(SignalingLimits.maxSdpLength, 32768);
      expect(SignalingLimits.maxCandidateLength, 1024);
      expect(SignalingLimits.maxSdpMidLength, 64);
      expect(SignalingLimits.minSdpMLineIndex, 0);
      expect(SignalingLimits.maxSdpMLineIndex, 255);
    });
  });

  group('incoming webrtc:offer', () {
    test('the relayed payload is { remoteSessionId, from, sdp }', () {
      final message = RemoteSignalingMessageDto.fromEvent(
        SignalingContract.offerEvent,
        {'remoteSessionId': sessionId, 'from': 'DEVICE', 'sdp': sdp},
      );

      expect(message, isA<OfferReceived>());
      final offer = message! as OfferReceived;
      expect(offer.remoteSessionId, sessionId);
      expect(offer.offer.sdp, sdp);
      expect(offer.origin, SignalingOrigin.device);
    });
  });

  group('incoming webrtc:answer', () {
    test('has the same shape as the offer', () {
      final message = RemoteSignalingMessageDto.fromEvent(
        SignalingContract.answerEvent,
        {'remoteSessionId': sessionId, 'from': 'DEVICE', 'sdp': sdp},
      );

      expect(message, isA<AnswerReceived>());
      expect((message! as AnswerReceived).answer.sdp, sdp);
    });
  });

  group('incoming webrtc:ice-candidate', () {
    test('carries both optional keys, normalized to null', () {
      // "Omitted optional fields are normalized to null on the way out, so the
      // receiver always gets both keys."
      final message = RemoteSignalingMessageDto.fromEvent(
        SignalingContract.iceCandidateEvent,
        {
          'remoteSessionId': sessionId,
          'from': 'DEVICE',
          'candidate': candidateLine,
          'sdpMid': null,
          'sdpMLineIndex': null,
        },
      );

      final candidate = (message! as IceCandidateReceived).candidate;
      expect(candidate.candidate, candidateLine);
      expect(candidate.sdpMid, isNull);
      expect(candidate.sdpMLineIndex, isNull);
    });

    test('the documented example is parsed as documented', () {
      final message = RemoteSignalingMessageDto.fromEvent(
        SignalingContract.iceCandidateEvent,
        {
          'remoteSessionId': sessionId,
          'from': 'TECHNICIAN',
          'candidate': candidateLine,
          'sdpMid': '0',
          'sdpMLineIndex': 0,
        },
      );

      final received = message! as IceCandidateReceived;
      expect(received.origin, SignalingOrigin.technician);
      expect(received.candidate.sdpMid, '0');
      expect(received.candidate.sdpMLineIndex, 0);
    });

    test('an empty candidate is accepted as end-of-candidates', () {
      final message = RemoteSignalingMessageDto.fromEvent(
        SignalingContract.iceCandidateEvent,
        {'remoteSessionId': sessionId, 'from': 'DEVICE', 'candidate': ''},
      );

      final candidate = (message! as IceCandidateReceived).candidate;
      expect(candidate.candidate, '');
      expect(candidate.isEndOfCandidates, isTrue);
    });
  });

  group('from / origin', () {
    test('only DEVICE and TECHNICIAN exist', () {
      expect(SignalingOrigin.values.map((origin) => origin.wireValue), [
        'DEVICE',
        'TECHNICIAN',
      ]);
      expect(SignalingOrigin.fromWire('DEVICE'), SignalingOrigin.device);
      expect(
        SignalingOrigin.fromWire('TECHNICIAN'),
        SignalingOrigin.technician,
      );
    });

    test('an absent or unknown origin never discards the message', () {
      // `from` is metadata, not authorization: the backend already decided
      // who may talk into the room.
      for (final from in <Object?>[null, 'SERVER', 42]) {
        final message = RemoteSignalingMessageDto.fromEvent(
          SignalingContract.offerEvent,
          {'remoteSessionId': sessionId, 'from': from, 'sdp': sdp},
        );

        expect(message, isA<OfferReceived>(), reason: 'from $from');
        expect(message!.origin, isNull);
      }
    });
  });

  group('relay ACK', () {
    test('accepted is { delivered: true, remoteSessionId }', () {
      final result = SignalingRelayAckDto.fromAck({
        'delivered': true,
        'remoteSessionId': sessionId,
      }, remoteSessionId: sessionId);

      expect(result, const SignalingRelayDelivered(sessionId));
      expect(result.isDelivered, isTrue);
    });

    test('rejected is { delivered: false, error }', () {
      final result = SignalingRelayAckDto.fromAck({
        'delivered': false,
        'error': 'NOT_JOINED',
      }, remoteSessionId: sessionId);

      expect(result, isA<SignalingRelayRefused>());
      expect(
        (result as SignalingRelayRefused).error,
        SignalingErrorCode.notJoined,
      );
      expect(result.isDelivered, isFalse);
    });

    test('the four documented error codes are understood', () {
      // "Possible error values: INVALID_PAYLOAD, NOT_JOINED, UNAUTHORIZED,
      // UNAVAILABLE."
      const codes = [
        'INVALID_PAYLOAD',
        'NOT_JOINED',
        'UNAUTHORIZED',
        'UNAVAILABLE',
      ];

      for (final code in codes) {
        final result = SignalingRelayAckDto.fromAck({
          'delivered': false,
          'error': code,
        }, remoteSessionId: sessionId);

        final refused = result as SignalingRelayRefused;
        expect(refused.error.wireValue, code);
        expect(refused.error.isKnown, isTrue);
        expect(refused.remoteSessionId, sessionId);
      }

      expect(SignalingErrorCode.known.map((code) => code.wireValue), codes);
    });

    test('an unknown future code is a refusal, not a success', () {
      final result = SignalingRelayAckDto.fromAck({
        'delivered': false,
        'error': 'RATE_LIMITED',
      }, remoteSessionId: sessionId);

      final refused = result as SignalingRelayRefused;
      expect(refused.error.wireValue, 'RATE_LIMITED');
      expect(refused.error.isKnown, isFalse);
    });

    test('an ACK for another session is never taken as delivered', () {
      final result = SignalingRelayAckDto.fromAck({
        'delivered': true,
        'remoteSessionId': 'another-session',
      }, remoteSessionId: sessionId);

      expect(result, isA<SignalingRelayUnanswered>());
      expect(
        (result as SignalingRelayUnanswered).reason,
        SignalingRelayUnansweredReason.malformedAck,
      );
    });

    test('a malformed ACK is never read as a delivery', () {
      for (final ack in <Object?>[
        null,
        'delivered',
        <Object?>[],
        {'delivered': 'true'},
        {'delivered': true},
        {'delivered': false},
        {'delivered': false, 'error': ''},
        {'remoteSessionId': sessionId},
      ]) {
        final result = SignalingRelayAckDto.fromAck(
          ack,
          remoteSessionId: sessionId,
        );

        expect(
          result,
          isA<SignalingRelayUnanswered>(),
          reason: 'ACK $ack must not be accepted',
        );
        expect(result.isDelivered, isFalse);
      }
    });
  });

  group('field names', () {
    test('match the contract exactly', () {
      expect(SignalingContract.remoteSessionIdField, 'remoteSessionId');
      expect(SignalingContract.sdpField, 'sdp');
      expect(SignalingContract.candidateField, 'candidate');
      expect(SignalingContract.sdpMidField, 'sdpMid');
      expect(SignalingContract.sdpMLineIndexField, 'sdpMLineIndex');
      expect(SignalingContract.fromField, 'from');
      expect(SignalingContract.deliveredField, 'delivered');
      expect(SignalingContract.errorField, 'error');
    });
  });

  group('defensive parsing', () {
    test('a payload that is not an object is ignored', () {
      for (final data in <Object?>[null, 'offer', 42, <Object?>[]]) {
        expect(
          RemoteSignalingMessageDto.fromEvent(
            SignalingContract.offerEvent,
            data,
          ),
          isNull,
        );
      }
    });

    test('an offer without a usable remoteSessionId or sdp is ignored', () {
      for (final data in <Map<String, Object?>>[
        {'sdp': sdp},
        {'remoteSessionId': '  ', 'sdp': sdp},
        {'remoteSessionId': sessionId},
        {'remoteSessionId': sessionId, 'sdp': ''},
        {'remoteSessionId': sessionId, 'sdp': 42},
      ]) {
        expect(
          RemoteSignalingMessageDto.fromEvent(
            SignalingContract.offerEvent,
            data,
          ),
          isNull,
          reason: '$data must be dropped',
        );
      }
    });

    test('a candidate with the wrong types is ignored', () {
      for (final data in <Map<String, Object?>>[
        {'remoteSessionId': sessionId},
        {'remoteSessionId': sessionId, 'candidate': 42},
        {'remoteSessionId': sessionId, 'candidate': candidateLine, 'sdpMid': 0},
        {
          'remoteSessionId': sessionId,
          'candidate': candidateLine,
          'sdpMLineIndex': '0',
        },
      ]) {
        expect(
          RemoteSignalingMessageDto.fromEvent(
            SignalingContract.iceCandidateEvent,
            data,
          ),
          isNull,
          reason: '$data must be dropped',
        );
      }
    });

    test('an event this client does not relay produces nothing', () {
      expect(
        RemoteSignalingMessageDto.fromEvent('webrtc:renegotiate', {
          'remoteSessionId': sessionId,
          'sdp': sdp,
        }),
        isNull,
      );
    });
  });
}
