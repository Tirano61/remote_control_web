import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/signaling_error_code.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/technician_realtime_status.dart';
import 'package:remote_control_web/features/technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import 'package:remote_control_web/features/technician_realtime/presentation/bloc/technician_realtime/technician_realtime_bloc.dart';

import '../../../support/realtime_test_doubles.dart';

void main() {
  const sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';

  late FakeTechnicianRealtimeClient client;

  setUp(() => client = FakeTechnicianRealtimeClient());

  group('TechnicianRealtimeBloc', () {
    test('connecting is asked of the client, not performed here', () async {
      final bloc = TechnicianRealtimeBloc(client: client);

      bloc.add(const TechnicianRealtimeConnectRequested());
      await bloc.stream.firstWhere(
        (status) => status is TechnicianRealtimeConnecting,
      );

      expect(client.connectCount, 1);
      await bloc.close();
    });

    test('the transport state is mirrored as it changes', () async {
      final bloc = TechnicianRealtimeBloc(client: client);
      final seen = <TechnicianRealtimeStatus>[];
      final subscription = bloc.stream.listen(seen.add);

      bloc.add(const TechnicianRealtimeConnectRequested());
      await Future<void>.delayed(Duration.zero);
      client.emitConnected();
      await Future<void>.delayed(Duration.zero);
      client.emitReconnecting();
      await Future<void>.delayed(Duration.zero);

      expect(seen.map((status) => status.runtimeType).toList(), [
        TechnicianRealtimeConnecting,
        TechnicianRealtimeConnected,
        TechnicianRealtimeReconnecting,
      ]);
      expect(bloc.state.isConnected, isFalse);

      await subscription.cancel();
      await bloc.close();
    });

    test('signing out disconnects', () async {
      final bloc = TechnicianRealtimeBloc(client: client);

      bloc.add(const TechnicianRealtimeDisconnectRequested());
      await bloc.stream.firstWhere(
        (status) => status is TechnicianRealtimeDisconnected,
      );

      expect(client.disconnectCount, 1);
      await bloc.close();
    });
  });

  group('SignalingJoinBloc', () {
    test('a join sends the event and reports the room as joined', () async {
      final bloc = SignalingJoinBloc(client: client);

      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoined);

      expect(client.joinedSessionIds, [sessionId]);
      expect(bloc.state.isJoined, isTrue);
      expect(bloc.state.remoteSessionId, sessionId);
      // Joined, but the tablet is not in the room: being joined and being
      // able to negotiate are two different facts.
      expect((bloc.state as SignalingJoined).peerJoined, isFalse);
      await bloc.close();
    });

    test('an ACK that already reports the peer needs no event', () async {
      client.peerJoinedOnJoin = true;
      final bloc = SignalingJoinBloc(client: client);

      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoined);

      expect((bloc.state as SignalingJoined).peerJoined, isTrue);
      await bloc.close();
    });

    test('remote-session:peer-joined completes the readiness', () async {
      final bloc = SignalingJoinBloc(client: client);
      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoined);

      client.emitPeerJoined(sessionId);
      await bloc.stream.firstWhere(
        (state) => state is SignalingJoined && state.peerJoined,
      );

      expect((bloc.state as SignalingJoined).peerJoined, isTrue);
      await bloc.close();
    });

    test('the event is idempotent', () async {
      final bloc = SignalingJoinBloc(client: client);
      final seen = <SignalingJoinState>[];
      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoined);
      final subscription = bloc.stream.listen(seen.add);

      client
        ..emitPeerJoined(sessionId)
        ..emitPeerJoined(sessionId)
        ..emitPeerJoined(sessionId);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // One change of state, whatever the number of events.
      expect(seen, hasLength(1));
      expect((bloc.state as SignalingJoined).peerJoined, isTrue);
      await subscription.cancel();
      await bloc.close();
    });

    test('readiness for another session is never adopted', () async {
      final bloc = SignalingJoinBloc(client: client);
      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoined);

      client.emitPeerJoined('9a0f3d1b-4c88-9e64-6f2a-5c7e8b103d1b');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect((bloc.state as SignalingJoined).peerJoined, isFalse);
      expect(bloc.state.remoteSessionId, sessionId);
      await bloc.close();
    });

    test('an event that overtook its acknowledgement still counts', () async {
      // The tablet joined between this socket's join and its ACK, so the ACK
      // legitimately says false and the event arrived first.
      final gate = Completer<void>();
      client.joinGate = gate.future;
      final bloc = SignalingJoinBloc(client: client);

      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoining);
      client.emitPeerJoined(sessionId);
      await Future<void>.delayed(Duration.zero);
      gate.complete();
      await bloc.stream.firstWhere((state) => state is SignalingJoined);

      expect((bloc.state as SignalingJoined).peerJoined, isTrue);
      await bloc.close();
    });

    test('readiness never survives a reset', () async {
      final bloc = SignalingJoinBloc(client: client);
      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoined);
      client.emitPeerJoined(sessionId);
      await bloc.stream.firstWhere(
        (state) => state is SignalingJoined && state.peerJoined,
      );

      // The socket dropped: rooms and readiness die with it.
      bloc.add(const SignalingJoinReset());
      await bloc.stream.firstWhere((state) => state is SignalingIdle);
      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 2,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoined);

      // The new socket has to be told again, by its own ACK or by a new event.
      expect((bloc.state as SignalingJoined).peerJoined, isFalse);
      await bloc.close();
    });

    test('the same session over the same connection is joined once', () async {
      final bloc = SignalingJoinBloc(client: client);

      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoined);
      // A support refresh, a repeated "connected" event, a reload of the
      // current session: all of them trigger this again.
      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(client.joinedSessionIds, [sessionId]);
      await bloc.close();
    });

    test('a request arriving while one is in flight is dropped', () async {
      final gate = Completer<void>();
      client.joinGate = gate.future;
      final bloc = SignalingJoinBloc(client: client);

      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoining);
      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(client.joinedSessionIds, [sessionId]);

      gate.complete();
      await bloc.stream.firstWhere((state) => state is SignalingJoined);
      await bloc.close();
    });

    test('the same session over a new connection is joined again', () async {
      final bloc = SignalingJoinBloc(client: client);

      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoined);

      // The socket dropped: rooms do not survive it.
      bloc.add(const SignalingJoinReset());
      await bloc.stream.firstWhere((state) => state is SignalingIdle);

      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 2,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoined);

      expect(client.joinedSessionIds, [sessionId, sessionId]);
      await bloc.close();
    });

    test('a refused join is reported and not retried by itself', () async {
      client.joinResult = const JoinRemoteSessionRejected(
        SignalingErrorCode.unauthorized,
      );
      final bloc = SignalingJoinBloc(client: client);

      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingUnavailable);

      final state = bloc.state as SignalingUnavailable;
      expect(state.error, SignalingErrorCode.unauthorized);
      expect(state.remoteSessionId, sessionId);

      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.joinedSessionIds, hasLength(1));
      await bloc.close();
    });

    test('an explicit retry insists on the same connection', () async {
      client.joinResult = const JoinRemoteSessionRejected(
        SignalingErrorCode.unavailable,
      );
      final bloc = SignalingJoinBloc(client: client);

      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingUnavailable);

      client.joinResult = null;
      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
          force: true,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoined);

      expect(client.joinedSessionIds, hasLength(2));
      await bloc.close();
    });

    test('an unanswered join leaves the channel unavailable', () async {
      client.joinResult = const JoinRemoteSessionFailed(
        JoinRemoteSessionFailureReason.timeout,
      );
      final bloc = SignalingJoinBloc(client: client);

      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingUnavailable);

      expect((bloc.state as SignalingUnavailable).error, isNull);
      expect(bloc.state.isJoined, isFalse);
      await bloc.close();
    });

    test('a reset forgets the joined room', () async {
      final bloc = SignalingJoinBloc(client: client);
      bloc.add(
        const SignalingJoinRequested(
          remoteSessionId: sessionId,
          connectionId: 1,
        ),
      );
      await bloc.stream.firstWhere((state) => state is SignalingJoined);
      // An accepted join is what opens signaling.
      expect(client.joinedRemoteSessionId, sessionId);

      bloc.add(const SignalingJoinReset());
      await bloc.stream.firstWhere((state) => state is SignalingIdle);

      expect(bloc.state.isJoined, isFalse);
      expect(bloc.state.remoteSessionId, isNull);
      // And the client stops relaying at the same moment, so late signaling
      // for that session is discarded instead of being acted upon.
      expect(client.joinedRemoteSessionId, isNull);
      expect(client.forgetJoinedCount, 1);
      await bloc.close();
    });
  });
}
