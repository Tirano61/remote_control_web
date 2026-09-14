import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/features/technician_realtime/data/models/join_remote_session_ack_dto.dart';
import 'package:remote_control_web/features/technician_realtime/data/models/remote_session_closed_notice_dto.dart';
import 'package:remote_control_web/features/technician_realtime/data/gateway/realtime_connect_error.dart';
import 'package:remote_control_web/features/technician_realtime/data/realtime_contract.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/signaling_error_code.dart';

/// Everything asserted here comes from `docs/backend/REALTIME.md`. The file is
/// never modified to fit the client: if these tests and the document disagree,
/// the client is wrong.
void main() {
  const sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';

  group('namespace and handshake', () {
    test('the technician namespace is /technicians', () {
      expect(TechnicianRealtimeContract.namespace, '/technicians');
      // `/devices` belongs to the tablet and needs a Device JWT.
      expect(TechnicianRealtimeContract.namespace, isNot('/devices'));
    });

    test('the User JWT travels in auth.token and nothing else', () {
      final auth = TechnicianRealtimeContract.authPayload('user-jwt');

      expect(auth, {'token': 'user-jwt'});
      expect(auth.keys, ['token']);
      // Identity is never taken from a payload: these would authenticate
      // nothing and are not sent.
      expect(auth.containsKey('email'), isFalse);
      expect(auth.containsKey('userId'), isFalse);
      expect(auth.containsKey('technicianId'), isFalse);
      expect(auth.containsKey('roles'), isFalse);
    });

    test('the namespace URL is derived from BACKEND_BASE_URL', () {
      const local = AppConfig(backendBaseUrl: 'http://localhost:3000');
      const tunnel = AppConfig(
        backendBaseUrl: 'https://w4qb7jsw-3000.brs.devtunnels.ms',
      );
      const trailingSlash = AppConfig(
        backendBaseUrl: 'https://w4qb7jsw-3000.brs.devtunnels.ms/',
      );

      expect(
        local.socketNamespaceUrl(TechnicianRealtimeContract.namespace),
        'http://localhost:3000/technicians',
      );
      expect(
        tunnel.socketNamespaceUrl(TechnicianRealtimeContract.namespace),
        'https://w4qb7jsw-3000.brs.devtunnels.ms/technicians',
      );
      expect(
        trailingSlash.socketNamespaceUrl(TechnicianRealtimeContract.namespace),
        'https://w4qb7jsw-3000.brs.devtunnels.ms/technicians',
      );
    });

    test('a rejected handshake is told apart by its documented message', () {
      // The middleware answers the single generic string `Unauthorized`.
      expect(
        RealtimeConnectError.isAuthenticationFailure({
          'message': 'Unauthorized',
        }),
        isTrue,
      );
      // Transport problems must never sign the user out.
      expect(
        RealtimeConnectError.isAuthenticationFailure('websocket error'),
        isFalse,
      );
      expect(
        RealtimeConnectError.isAuthenticationFailure({
          'message': 'xhr poll error',
        }),
        isFalse,
      );
      expect(RealtimeConnectError.isAuthenticationFailure(null), isFalse);
      expect(
        RealtimeConnectError.isAuthenticationFailure(
          Exception('Connection refused'),
        ),
        isFalse,
      );
    });
  });

  group('remote-session:join', () {
    test('the event name is the documented one', () {
      expect(TechnicianRealtimeContract.joinEvent, 'remote-session:join');
    });

    test('the payload carries only remoteSessionId', () {
      final payload = TechnicianRealtimeContract.joinPayload(sessionId);

      expect(payload, {'remoteSessionId': sessionId});
      expect(payload.keys, ['remoteSessionId']);
      // The participant comes from the namespace; any extra property would be
      // INVALID_PAYLOAD.
      expect(payload.containsKey('participant'), isFalse);
      expect(payload.containsKey('technicianId'), isFalse);
      expect(payload.containsKey('deviceId'), isFalse);
    });

    test('an accepted ACK is { joined: true, remoteSessionId }', () {
      final result = JoinRemoteSessionAckDto.fromAck(
        {'joined': true, 'remoteSessionId': sessionId},
        requestedRemoteSessionId: sessionId,
      );

      expect(result, isA<JoinRemoteSessionAccepted>());
      expect(
        (result as JoinRemoteSessionAccepted).remoteSessionId,
        sessionId,
      );
    });

    test('a rejected ACK is { joined: false, error }', () {
      final result = JoinRemoteSessionAckDto.fromAck(
        {'joined': false, 'error': 'UNAUTHORIZED'},
        requestedRemoteSessionId: sessionId,
      );

      expect(result, isA<JoinRemoteSessionRejected>());
      expect(
        (result as JoinRemoteSessionRejected).error,
        SignalingErrorCode.unauthorized,
      );
    });

    test('the documented join error codes are understood', () {
      for (final code in ['INVALID_PAYLOAD', 'UNAUTHORIZED']) {
        final result = JoinRemoteSessionAckDto.fromAck(
          {'joined': false, 'error': code},
          requestedRemoteSessionId: sessionId,
        );

        expect(
          (result as JoinRemoteSessionRejected).error.wireValue,
          code,
        );
        expect(result.error.isKnown, isTrue);
      }
    });

    test('every stable signaling code is modelled', () {
      expect(
        SignalingErrorCode.known.map((code) => code.wireValue),
        ['INVALID_PAYLOAD', 'NOT_JOINED', 'UNAUTHORIZED', 'UNAVAILABLE'],
      );
    });

    test('an unknown future code is a refusal, not a success', () {
      final result = JoinRemoteSessionAckDto.fromAck(
        {'joined': false, 'error': 'RATE_LIMITED'},
        requestedRemoteSessionId: sessionId,
      );

      expect(result, isA<JoinRemoteSessionRejected>());
      final error = (result as JoinRemoteSessionRejected).error;
      expect(error.wireValue, 'RATE_LIMITED');
      expect(error.isKnown, isFalse);
    });

    test('an ACK for a different session is never taken as joined', () {
      final result = JoinRemoteSessionAckDto.fromAck(
        {'joined': true, 'remoteSessionId': 'another-session'},
        requestedRemoteSessionId: sessionId,
      );

      expect(result, isA<JoinRemoteSessionFailed>());
      expect(
        (result as JoinRemoteSessionFailed).reason,
        JoinRemoteSessionFailureReason.malformedAck,
      );
    });

    test('a malformed ACK is never read as a success', () {
      for (final ack in <Object?>[
        null,
        'joined',
        <Object?>[],
        {'joined': 'true'},
        {'joined': false},
        {'joined': false, 'error': ''},
        {'remoteSessionId': sessionId},
      ]) {
        final result = JoinRemoteSessionAckDto.fromAck(
          ack,
          requestedRemoteSessionId: sessionId,
        );

        expect(
          result,
          isA<JoinRemoteSessionFailed>(),
          reason: 'ACK $ack must not be accepted',
        );
      }
    });
  });

  group('remote-session:closed', () {
    test('the event name is the documented one', () {
      expect(
        TechnicianRealtimeContract.remoteSessionClosedEvent,
        'remote-session:closed',
      );
    });

    test('the payload is { remoteSessionId, endedBy }', () {
      final notice = RemoteSessionClosedNoticeDto.fromEvent({
        'remoteSessionId': sessionId,
        'endedBy': 'DEVICE',
      });

      expect(notice, isNotNull);
      expect(notice!.remoteSessionId, sessionId);
      expect(notice.endedBy, 'DEVICE');
    });

    test('it carries no session object: it is a trigger, not the state', () {
      final notice = RemoteSessionClosedNoticeDto.fromEvent({
        'remoteSessionId': sessionId,
        'endedBy': 'DEVICE',
        // Even if the backend ever added more, the console would still read
        // the state over REST.
        'status': 'CLOSED',
      });

      expect(notice!.remoteSessionId, sessionId);
    });

    test('a payload without a usable id is dropped', () {
      for (final data in <Object?>[
        null,
        'closed',
        <String, Object?>{},
        {'endedBy': 'DEVICE'},
        {'remoteSessionId': 42},
        {'remoteSessionId': '  '},
      ]) {
        expect(RemoteSessionClosedNoticeDto.fromEvent(data), isNull);
      }
    });

    test('an absent endedBy does not invalidate the notice', () {
      final notice = RemoteSessionClosedNoticeDto.fromEvent({
        'remoteSessionId': sessionId,
      });

      expect(notice!.remoteSessionId, sessionId);
      expect(notice.endedBy, isNull);
    });
  });

  group('field names', () {
    test('match the contract exactly', () {
      expect(TechnicianRealtimeContract.authTokenField, 'token');
      expect(
        TechnicianRealtimeContract.remoteSessionIdField,
        'remoteSessionId',
      );
      expect(TechnicianRealtimeContract.joinedField, 'joined');
      expect(TechnicianRealtimeContract.errorField, 'error');
      expect(TechnicianRealtimeContract.endedByField, 'endedBy');
      expect(
        TechnicianRealtimeContract.unauthorizedConnectErrorMessage,
        'Unauthorized',
      );
    });
  });
}
