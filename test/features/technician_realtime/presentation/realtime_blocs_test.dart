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

      bloc.add(const SignalingJoinReset());
      await bloc.stream.firstWhere((state) => state is SignalingIdle);

      expect(bloc.state.isJoined, isFalse);
      expect(bloc.state.remoteSessionId, isNull);
      await bloc.close();
    });
  });
}
