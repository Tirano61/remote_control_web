import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/features/signaling/data/signaling_contract.dart';
import 'package:remote_control_web/features/signaling/data/signaling_transport.dart';
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
      gateway.answerAck({
        'joined': true,
        'remoteSessionId': sessionId,
        'peerJoined': false,
      });

      expect(gateway.emitted.single.event, 'remote-session:join');
      expect(gateway.emitted.single.payload, {'remoteSessionId': sessionId});
      expect(await pending, isA<JoinRemoteSessionAccepted>());
    });

    test('the ACK reports whether the tablet is already in the room', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();

      final pending = client.joinRemoteSession(sessionId);
      gateway.answerAck({
        'joined': true,
        'remoteSessionId': sessionId,
        'peerJoined': true,
      });

      final result = await pending;
      expect((result as JoinRemoteSessionAccepted).peerJoined, isTrue);
    });

    test('an accepted ACK without peerJoined is not usable', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();

      final pending = client.joinRemoteSession(sessionId);
      gateway.answerAck({'joined': true, 'remoteSessionId': sessionId});

      expect(await pending, isA<JoinRemoteSessionFailed>());
      // Readiness that was never reported is never assumed.
      expect(client.joinedRemoteSessionId, isNull);
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

  group('signaling transport', () {
    const sdp = 'v=0 o=- 46117 2 IN IP4 127.0.0.1';

    /// Connects and joins, which is the only way into a signaling room.
    Future<FakeRealtimeSocketGateway> connectAndJoin([
      String id = sessionId,
    ]) async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();
      final pending = client.joinRemoteSession(id);
      gateway.answerAck({
        'joined': true,
        'remoteSessionId': id,
        'peerJoined': false,
      });
      await pending;
      return gateway;
    }

    test('an accepted join is what opens signaling', () async {
      expect(client.joinedRemoteSessionId, isNull);

      await connectAndJoin();

      expect(client.joinedRemoteSessionId, sessionId);
    });

    test('a denied join leaves the socket in no room at all', () async {
      final gateway = await connectAndJoin();

      final pending = client.joinRemoteSession('another-session');
      gateway.answerAck({'joined': false, 'error': 'UNAUTHORIZED'});
      await pending;

      // The contract is explicit: a valid payload that is denied has ALREADY
      // left the old session.
      expect(client.joinedRemoteSessionId, isNull);
    });

    test('INVALID_PAYLOAD keeps the session the socket already had', () async {
      final gateway = await connectAndJoin();

      final pending = client.joinRemoteSession('another-session');
      gateway.answerAck({'joined': false, 'error': 'INVALID_PAYLOAD'});
      await pending;

      // "The payload is validated before anything is torn down."
      expect(client.joinedRemoteSessionId, sessionId);
    });

    test('a join nobody answered claims no membership', () async {
      await client.connect();
      factory.last.completeHandshake();

      await client.joinRemoteSession(sessionId);

      expect(client.joinedRemoteSessionId, isNull);
    });

    test('a lost connection loses the room with it', () async {
      final gateway = await connectAndJoin();

      gateway.dropConnection();

      expect(client.joinedRemoteSessionId, isNull);
    });

    test('disconnecting and disposing leave no room behind', () async {
      await connectAndJoin();

      await client.disconnect();

      expect(client.joinedRemoteSessionId, isNull);
    });

    test('the console can forget the room without dropping the socket', () async {
      final gateway = await connectAndJoin();

      client.forgetJoinedRemoteSession();

      expect(client.joinedRemoteSessionId, isNull);
      expect(gateway.disposeCount, 0);
      expect(client.status.isConnected, isTrue);
    });

    test('a relay travels over the very same socket as the join', () async {
      final gateway = await connectAndJoin();

      final sent = client.emitSignaling(SignalingContract.offerEvent, {
        'remoteSessionId': sessionId,
        'sdp': sdp,
      }, (_) {});

      expect(sent, isTrue);
      // One gateway, one socket: the join and the offer are on the same wire.
      expect(factory.gateways, hasLength(1));
      expect(gateway.emitted.map((emission) => emission.event), [
        'remote-session:join',
        'webrtc:offer',
      ]);
    });

    test('there is nothing to emit over without a socket', () async {
      var acknowledged = false;

      final sent = client.emitSignaling(
        SignalingContract.offerEvent,
        {'remoteSessionId': sessionId, 'sdp': sdp},
        (_) => acknowledged = true,
      );

      expect(sent, isFalse);
      expect(acknowledged, isFalse);
    });

    test('the three relayed events are forwarded raw', () async {
      final gateway = await connectAndJoin();
      final wire = <SignalingWireEvent>[];
      client.signalingEvents.listen(wire.add);

      gateway.emitServerEvent(SignalingContract.offerEvent, {
        'remoteSessionId': sessionId,
        'from': 'DEVICE',
        'sdp': sdp,
      });
      gateway.emitServerEvent(SignalingContract.answerEvent, {
        'remoteSessionId': sessionId,
        'from': 'DEVICE',
        'sdp': sdp,
      });
      gateway.emitServerEvent(SignalingContract.iceCandidateEvent, {
        'remoteSessionId': sessionId,
        'from': 'DEVICE',
        'candidate': 'candidate:1 1 udp 1 192.0.2.10 1 typ host',
      });
      await Future<void>.delayed(Duration.zero);

      expect(wire.map((event) => event.event), [
        'webrtc:offer',
        'webrtc:answer',
        'webrtc:ice-candidate',
      ]);
      // Forwarded untouched: this class does not parse SDP or candidates.
      expect((wire.first.data! as Map)['sdp'], sdp);
    });

    test('events from a socket that was replaced are dropped', () async {
      final gateway = await connectAndJoin();
      final wire = <SignalingWireEvent>[];
      client.signalingEvents.listen(wire.add);

      await client.disconnect();
      gateway.emitServerEvent(SignalingContract.offerEvent, {
        'remoteSessionId': sessionId,
        'from': 'DEVICE',
        'sdp': sdp,
      });
      await Future<void>.delayed(Duration.zero);

      expect(wire, isEmpty);
    });
  });

  group('remote-session:peer-joined', () {
    test('is published as a typed readiness notice', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();

      final received = client.peerJoined.first;
      gateway.emitServerEvent(
        TechnicianRealtimeContract.remoteSessionPeerJoinedEvent,
        {'remoteSessionId': sessionId},
      );

      expect((await received).remoteSessionId, sessionId);
    });

    test('a malformed payload is ignored', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();

      var received = 0;
      client.peerJoined.listen((_) => received++);
      gateway.emitServerEvent(
        TechnicianRealtimeContract.remoteSessionPeerJoinedEvent,
        {'peer': true},
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, 0);
    });

    test('an event from a socket that was replaced is dropped', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();
      var received = 0;
      client.peerJoined.listen((_) => received++);

      await client.disconnect();
      gateway.emitServerEvent(
        TechnicianRealtimeContract.remoteSessionPeerJoinedEvent,
        {'remoteSessionId': sessionId},
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, 0);
    });
  });

  group('remote-session:active', () {
    test('is published as a typed notice, without having joined', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();

      final received = client.remoteSessionActivated.first;
      gateway.emitServerEvent(
        TechnicianRealtimeContract.remoteSessionActiveEvent,
        {'remoteSessionId': sessionId},
      );

      expect((await received).remoteSessionId, sessionId);
      // The event is addressed to the technician: no join was needed.
      expect(gateway.emitted, isEmpty);
    });

    test('an invalid payload is ignored', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();

      var received = 0;
      client.remoteSessionActivated.listen((_) => received++);
      for (final data in <Object?>[
        null,
        'active',
        <String, Object?>{},
        {'status': 'ACTIVE'},
        {'remoteSessionId': 42},
      ]) {
        gateway.emitServerEvent(
          TechnicianRealtimeContract.remoteSessionActiveEvent,
          data,
        );
      }
      await Future<void>.delayed(Duration.zero);

      expect(received, 0);
    });

    test('an event from a socket that was replaced is dropped', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();
      var received = 0;
      client.remoteSessionActivated.listen((_) => received++);

      await client.disconnect();
      gateway.emitServerEvent(
        TechnicianRealtimeContract.remoteSessionActiveEvent,
        {'remoteSessionId': sessionId},
      );
      await Future<void>.delayed(Duration.zero);

      expect(received, 0);
    });

    test('it does not touch the joined room', () async {
      await client.connect();
      final gateway = factory.last;
      gateway.completeHandshake();
      final join = client.joinRemoteSession(sessionId);
      gateway.answerAck({
        'joined': true,
        'remoteSessionId': sessionId,
        'peerJoined': false,
      });
      await join;

      gateway.emitServerEvent(
        TechnicianRealtimeContract.remoteSessionActiveEvent,
        {'remoteSessionId': 'another-session'},
      );
      await Future<void>.delayed(Duration.zero);

      // A domain notification is not membership, whatever id it names.
      expect(client.joinedRemoteSessionId, sessionId);
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
