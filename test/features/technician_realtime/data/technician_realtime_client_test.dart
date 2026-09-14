import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/features/technician_realtime/data/realtime_contract.dart';
import 'package:remote_control_web/features/technician_realtime/data/technician_realtime_client_impl.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/signaling_error_code.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/technician_realtime_status.dart';

import '../../../support/console_test_doubles.dart';
import '../../../support/realtime_test_doubles.dart';

void main() {
  const sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';

  late InMemoryUserTokenProvider tokenProvider;
  late RecordingGatewayFactory factory;
  late TechnicianRealtimeClientImpl client;

  setUp(() {
    tokenProvider = InMemoryUserTokenProvider('user-jwt');
    factory = RecordingGatewayFactory();
    client = TechnicianRealtimeClientImpl(
      config: const AppConfig(backendBaseUrl: 'http://localhost:3000'),
      tokenProvider: tokenProvider,
      gatewayFactory: factory.call,
      ackTimeout: const Duration(milliseconds: 50),
    );
  });

  tearDown(() => client.dispose());

  group('connect', () {
    test('opens /technicians with the current User JWT', () async {
      await client.connect();

      final gateway = factory.last;
      expect(gateway.url, 'http://localhost:3000/technicians');
      expect(gateway.connectCount, 1);
      expect(await gateway.currentAuth(), {'token': 'user-jwt'});
      expect(client.status, isA<TechnicianRealtimeConnecting>());
    });

    test('a successful handshake reports Connected', () async {
      await client.connect();
      factory.last.completeHandshake();

      expect(client.status, isA<TechnicianRealtimeConnected>());
      expect(client.status.isConnected, isTrue);
      expect(client.status.connectionId, 1);
    });

    test('the token is read again for every attempt', () async {
      await client.connect();
      final gateway = factory.last;
      expect(await gateway.currentAuth(), {'token': 'user-jwt'});

      // GET /auth/check-status replaced the stored token.
      tokenProvider.token = 'renewed-jwt';

      expect(await gateway.currentAuth(), {'token': 'renewed-jwt'});
    });

    test('connecting twice does not open a second socket', () async {
      await client.connect();
      factory.last.completeHandshake();
      await client.connect();

      expect(factory.gateways, hasLength(1));
      expect(factory.last.connectCount, 1);
    });

    test('no stored token is reported as an authentication problem', () async {
      tokenProvider.token = null;

      await client.connect();

      expect(factory.gateways, isEmpty);
      final status = client.status;
      expect(status, isA<TechnicianRealtimeConnectionError>());
      expect(
        (status as TechnicianRealtimeConnectionError).isAuthenticationError,
        isTrue,
      );
    });
  });

  group('disconnect', () {
    test('closes the socket and stops reconnecting', () async {
      await client.connect();
      factory.last.completeHandshake();

      await client.disconnect();

      expect(factory.last.disposeCount, 1);
      expect(client.status, isA<TechnicianRealtimeDisconnected>());
    });

    test('a disconnection asked for is not reported as a reconnection', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();

      await client.disconnect();
      // Whatever the transport says afterwards belongs to a socket nobody
      // listens to any more.
      gateway.dropConnection();

      expect(client.status, isA<TechnicianRealtimeDisconnected>());
    });

    test('a later connect opens a fresh socket', () async {
      await client.connect();
      await client.disconnect();

      await client.connect();

      expect(factory.gateways, hasLength(2));
      expect(factory.last.connectCount, 1);
    });
  });

  group('network problems', () {
    test('a lost connection is a reconnection, not an error', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();

      gateway.dropConnection();

      expect(client.status, isA<TechnicianRealtimeReconnecting>());
      // The socket is left alone: Socket.IO owns the backoff.
      expect(gateway.disposeCount, 0);
    });

    test('a transport error keeps the socket retrying', () async {
      await client.connect();
      final gateway = factory.last;

      gateway.reportConnectError('xhr poll error');

      final status = client.status;
      expect(status, isA<TechnicianRealtimeConnectionError>());
      expect(
        (status as TechnicianRealtimeConnectionError).isAuthenticationError,
        isFalse,
      );
      expect(gateway.disposeCount, 0);

      gateway.reportReconnectAttempt();
      expect(client.status, isA<TechnicianRealtimeReconnecting>());
    });

    test('a reconnection is a new connection for the consumers', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();
      expect(client.status.connectionId, 1);

      gateway.dropConnection();
      gateway.completeHandshake();

      // A different id: whatever was joined over the old socket is gone.
      expect(client.status.connectionId, 2);
    });
  });

  group('rejected handshake', () {
    test('stops reconnecting instead of looping forever', () async {
      await client.connect();
      final gateway = factory.last;

      gateway.reportConnectError({'message': 'Unauthorized'});

      final status = client.status;
      expect(status, isA<TechnicianRealtimeConnectionError>());
      expect(
        (status as TechnicianRealtimeConnectionError).isAuthenticationError,
        isTrue,
      );
      // The socket is torn down: a User JWT that was refused will be refused
      // again, and there is no refresh token.
      expect(gateway.disposeCount, 1);
    });
  });

  group('remote-session:join', () {
    test('sends the documented event and payload', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();

      final pending = client.joinRemoteSession(sessionId);
      gateway.answerAck({'joined': true, 'remoteSessionId': sessionId});

      expect(gateway.emitted.single.event, 'remote-session:join');
      expect(gateway.emitted.single.payload, {'remoteSessionId': sessionId});
      expect(await pending, isA<JoinRemoteSessionAccepted>());
    });

    test('a refusal is reported with its stable code', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();

      final pending = client.joinRemoteSession(sessionId);
      gateway.answerAck({'joined': false, 'error': 'UNAUTHORIZED'});

      final result = await pending;
      expect(result, isA<JoinRemoteSessionRejected>());
      expect(
        (result as JoinRemoteSessionRejected).error,
        SignalingErrorCode.unauthorized,
      );
    });

    test('joining without a connection never reaches the wire', () async {
      final result = await client.joinRemoteSession(sessionId);

      expect(result, isA<JoinRemoteSessionFailed>());
      expect(
        (result as JoinRemoteSessionFailed).reason,
        JoinRemoteSessionFailureReason.notConnected,
      );
    });

    test('an acknowledgement that never arrives does not hang', () async {
      await client.connect();
      factory.last.completeHandshake();

      final result = await client.joinRemoteSession(sessionId);

      expect(
        (result as JoinRemoteSessionFailed).reason,
        JoinRemoteSessionFailureReason.timeout,
      );
    });
  });

  group('remote-session:closed', () {
    test('is delivered without having joined anything', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();

      final received = client.remoteSessionClosed.first;
      gateway.emitServerEvent(
        TechnicianRealtimeContract.remoteSessionClosedEvent,
        {'remoteSessionId': sessionId, 'endedBy': 'DEVICE'},
      );

      final notice = await received;
      expect(notice.remoteSessionId, sessionId);
      expect(notice.endedBy, 'DEVICE');
      // No join was needed: the event is addressed to the technician.
      expect(gateway.emitted, isEmpty);
    });

    test('a malformed payload is ignored', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();

      var received = 0;
      client.remoteSessionClosed.listen((_) => received++);
      gateway.emitServerEvent(
        TechnicianRealtimeContract.remoteSessionClosedEvent,
        {'endedBy': 'DEVICE'},
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, 0);
    });
  });
}
