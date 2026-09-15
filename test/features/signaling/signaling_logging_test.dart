import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/features/signaling/data/signaling_contract.dart';
import 'package:remote_control_web/features/signaling/data/technician_signaling_client_impl.dart';
import 'package:remote_control_web/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_web/features/signaling/domain/entities/webrtc_session_description.dart';
import 'package:remote_control_web/features/technician_realtime/data/technician_realtime_client_impl.dart';

import '../../support/console_test_doubles.dart';
import '../../support/realtime_test_doubles.dart';

/// `docs/backend/REALTIME.md` and `CLAUDE.md` both forbid it, and the backend
/// keeps the same rule: *"The SDP and the ICE candidates are never written to
/// the logs."*
void main() {
  const sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';
  const secretToken = 'eyJhbGciOiJIUzI1NiJ9.SUPER-SECRET-JWT.signature';
  const secretSdp = 'v=0 o=- SECRET-SDP-PAYLOAD 2 IN IP4 127.0.0.1';
  const secretCandidate =
      'candidate:842163049 1 udp 1677729535 SECRET-CANDIDATE-HOST 54321 typ srflx';

  test('a full signaling exchange never prints SDP or ICE', () async {
    final factory = RecordingGatewayFactory();
    final realtime = TechnicianRealtimeClientImpl(
      config: const AppConfig(backendBaseUrl: 'http://localhost:3000'),
      tokenProvider: InMemoryUserTokenProvider(secretToken),
      gatewayFactory: factory.call,
      ackTimeout: const Duration(milliseconds: 50),
    );
    final signaling = TechnicianSignalingClientImpl(
      transport: realtime,
      ackTimeout: const Duration(milliseconds: 50),
    );

    final printed = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) printed.add(message);
    };

    await runZoned(
      () async {
        await realtime.connect();
        final gateway = factory.last;
        gateway.completeHandshake();

        final join = realtime.joinRemoteSession(sessionId);
        gateway.answerAck({
          'joined': true,
          'remoteSessionId': sessionId,
          'peerJoined': true,
        });
        await join;

        // Outgoing: an offer, an answer and a candidate, all acknowledged.
        final offer = signaling.sendOffer(
          const WebRtcOffer(remoteSessionId: sessionId, sdp: secretSdp),
        );
        gateway.answerAck({'delivered': true, 'remoteSessionId': sessionId});
        await offer;

        final answer = signaling.sendAnswer(
          const WebRtcAnswer(remoteSessionId: sessionId, sdp: secretSdp),
        );
        gateway.answerAck({'delivered': true, 'remoteSessionId': sessionId});
        await answer;

        // Incoming: the same payloads on the way back.
        gateway.emitServerEvent(SignalingContract.offerEvent, {
          'remoteSessionId': sessionId,
          'from': 'DEVICE',
          'sdp': secretSdp,
        });
        gateway.emitServerEvent(SignalingContract.iceCandidateEvent, {
          'remoteSessionId': sessionId,
          'from': 'DEVICE',
          'candidate': secretCandidate,
        });
        await Future<void>.delayed(Duration.zero);

        // And a refused relay, whose code may be logged but whose payload may
        // not. It costs the membership, so it goes last.
        final candidate = signaling.sendIceCandidate(
          const WebRtcIceCandidate(
            remoteSessionId: sessionId,
            candidate: secretCandidate,
            sdpMid: '0',
            sdpMLineIndex: 0,
          ),
        );
        gateway.answerAck({'delivered': false, 'error': 'NOT_JOINED'});
        await candidate;

        await signaling.dispose();
        await realtime.dispose();
      },
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => printed.add(line),
      ),
    );

    debugPrint = originalDebugPrint;

    final output = printed.join('\n');
    expect(output, isNot(contains('SECRET-SDP-PAYLOAD')));
    expect(output, isNot(contains('SECRET-CANDIDATE-HOST')));
    expect(output, isNot(contains(secretToken)));
    expect(output, isNot(contains('Authorization')));
    expect(output, isNot(contains('token')));
    expect(output, isNot(contains('v=0')));
    expect(output, isNot(contains('candidate:')));

    // What may be logged: the event, and the safe session identifier.
    expect(output, contains('offer sent $sessionId'));
    expect(output, contains('answer sent $sessionId'));
    expect(output, contains('ICE candidate sent $sessionId'));
    expect(output, contains('relay refused: NOT_JOINED $sessionId'));
    expect(output, contains('offer received $sessionId'));
  });
}
