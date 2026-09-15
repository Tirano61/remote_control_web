import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_web/features/signaling/domain/entities/signaling_limits.dart';
import 'package:remote_control_web/features/signaling/domain/entities/signaling_origin.dart';
import 'package:remote_control_web/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_web/features/signaling/domain/entities/webrtc_session_description.dart';

void main() {
  const sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';
  const secretSdp = 'v=0\r\no=- SECRET-SDP-PAYLOAD 2 IN IP4 127.0.0.1\r\n';
  const secretCandidate =
      'candidate:842163049 1 udp 1677729535 SECRET-CANDIDATE-HOST 54321 typ srflx';

  WebRtcOffer offerWith(String sdp) =>
      WebRtcOffer(remoteSessionId: sessionId, sdp: sdp);

  group('session description limits', () {
    test('an SDP inside 1–32768 characters is valid', () {
      expect(offerWith('v').validate(), isNull);
      expect(offerWith('x' * SignalingLimits.maxSdpLength).validate(), isNull);
    });

    test('an empty SDP is refused: the contract requires at least one', () {
      expect(
        offerWith('').validate(),
        SignalingPayloadViolation.emptySdp,
      );
    });

    test('one character over the limit is refused', () {
      expect(
        offerWith('x' * (SignalingLimits.maxSdpLength + 1)).validate(),
        SignalingPayloadViolation.sdpTooLong,
      );
    });

    test('an answer is validated exactly like an offer', () {
      const answer = WebRtcAnswer(remoteSessionId: sessionId, sdp: '');

      expect(answer.validate(), SignalingPayloadViolation.emptySdp);
      expect(
        WebRtcAnswer(
          remoteSessionId: sessionId,
          sdp: 'x' * SignalingLimits.maxSdpLength,
        ).validate(),
        isNull,
      );
    });

    test('a missing session id is refused before anything else', () {
      expect(
        const WebRtcOffer(remoteSessionId: '  ', sdp: 'v=0').validate(),
        SignalingPayloadViolation.missingRemoteSessionId,
      );
    });
  });

  group('ICE candidate limits', () {
    WebRtcIceCandidate candidateWith({
      String candidate = 'candidate:1 1 udp 1 192.0.2.10 1 typ host',
      String? sdpMid,
      int? sdpMLineIndex,
    }) => WebRtcIceCandidate(
      remoteSessionId: sessionId,
      candidate: candidate,
      sdpMid: sdpMid,
      sdpMLineIndex: sdpMLineIndex,
    );

    test('a candidate up to 1024 characters is valid', () {
      expect(
        candidateWith(
          candidate: 'c' * SignalingLimits.maxCandidateLength,
        ).validate(),
        isNull,
      );
    });

    test('the empty candidate is valid: it means end-of-candidates', () {
      final candidate = candidateWith(candidate: '');

      expect(candidate.validate(), isNull);
      expect(candidate.isEndOfCandidates, isTrue);
    });

    test('one character over the limit is refused', () {
      expect(
        candidateWith(
          candidate: 'c' * (SignalingLimits.maxCandidateLength + 1),
        ).validate(),
        SignalingPayloadViolation.candidateTooLong,
      );
    });

    test('sdpMid is optional and capped at 64 characters', () {
      expect(candidateWith().validate(), isNull);
      expect(
        candidateWith(
          sdpMid: 'm' * SignalingLimits.maxSdpMidLength,
        ).validate(),
        isNull,
      );
      expect(
        candidateWith(
          sdpMid: 'm' * (SignalingLimits.maxSdpMidLength + 1),
        ).validate(),
        SignalingPayloadViolation.sdpMidTooLong,
      );
    });

    test('sdpMLineIndex is optional and lives in 0–255', () {
      expect(candidateWith(sdpMLineIndex: 0).validate(), isNull);
      expect(candidateWith(sdpMLineIndex: 255).validate(), isNull);
      expect(
        candidateWith(sdpMLineIndex: -1).validate(),
        SignalingPayloadViolation.sdpMLineIndexOutOfRange,
      );
      expect(
        candidateWith(sdpMLineIndex: 256).validate(),
        SignalingPayloadViolation.sdpMLineIndexOutOfRange,
      );
    });

    test('both optional fields may be null at once', () {
      expect(candidateWith(sdpMid: null, sdpMLineIndex: null).validate(), isNull);
    });
  });

  group('toString never leaks SDP or candidates', () {
    test('an offer and an answer print a length, never the SDP', () {
      final offer = offerWith(secretSdp);
      const answer = WebRtcAnswer(
        remoteSessionId: sessionId,
        sdp: secretSdp,
      );

      for (final printed in [offer.toString(), answer.toString()]) {
        expect(printed, isNot(contains('SECRET-SDP-PAYLOAD')));
        expect(printed, contains(sessionId));
        expect(printed, contains('sdpLength: ${secretSdp.length}'));
      }
    });

    test('a candidate prints a length, never the candidate line', () {
      const candidate = WebRtcIceCandidate(
        remoteSessionId: sessionId,
        candidate: secretCandidate,
        sdpMid: '0',
        sdpMLineIndex: 0,
      );

      final printed = candidate.toString();
      expect(printed, isNot(contains('SECRET-CANDIDATE-HOST')));
      expect(printed, contains('candidateLength: ${secretCandidate.length}'));
    });

    test('an incoming message prints no payload either', () {
      final messages = <RemoteSignalingMessage>[
        OfferReceived(
          offer: offerWith(secretSdp),
          origin: SignalingOrigin.device,
        ),
        const AnswerReceived(
          answer: WebRtcAnswer(remoteSessionId: sessionId, sdp: secretSdp),
          origin: SignalingOrigin.device,
        ),
        const IceCandidateReceived(
          candidate: WebRtcIceCandidate(
            remoteSessionId: sessionId,
            candidate: secretCandidate,
          ),
          origin: SignalingOrigin.device,
        ),
      ];

      for (final message in messages) {
        final printed = message.toString();
        expect(printed, isNot(contains('SECRET-SDP-PAYLOAD')));
        expect(printed, isNot(contains('SECRET-CANDIDATE-HOST')));
        expect(printed, contains(sessionId));
      }
    });
  });

  group('identity', () {
    test('an offer and an answer with the same SDP are not the same thing', () {
      expect(
        offerWith(secretSdp),
        isNot(const WebRtcAnswer(remoteSessionId: sessionId, sdp: secretSdp)),
      );
    });

    test('every message exposes the session it belongs to', () {
      expect(
        OfferReceived(offer: offerWith('v=0')).remoteSessionId,
        sessionId,
      );
      expect(
        const AnswerReceived(
          answer: WebRtcAnswer(remoteSessionId: sessionId, sdp: 'v=0'),
        ).remoteSessionId,
        sessionId,
      );
      expect(
        const IceCandidateReceived(
          candidate: WebRtcIceCandidate(
            remoteSessionId: sessionId,
            candidate: '',
          ),
        ).remoteSessionId,
        sessionId,
      );
    });
  });
}
