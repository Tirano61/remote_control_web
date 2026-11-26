import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/app/console/technician_console_coordinator.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/auth/domain/usecases/log_out.dart';
import 'package:remote_control_web/features/auth/domain/usecases/restore_session.dart';
import 'package:remote_control_web/features/auth/presentation/bloc/user_session/user_session_bloc.dart';
import 'package:remote_control_web/features/devices/domain/usecases/load_devices.dart';
import 'package:remote_control_web/features/devices/presentation/bloc/devices/devices_bloc.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/activate_remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/close_remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/create_remote_session.dart';
import 'package:remote_control_web/features/remote_session/domain/usecases/load_current_remote_session.dart';
import 'package:remote_control_web/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_web/features/signaling/data/technician_signaling_client_impl.dart';
import 'package:remote_control_web/features/support/domain/usecases/assign_support_request.dart';
import 'package:remote_control_web/features/support/domain/usecases/load_support_requests.dart';
import 'package:remote_control_web/features/support/presentation/bloc/support_requests/support_requests_bloc.dart';
import 'package:remote_control_web/features/technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import 'package:remote_control_web/features/technician_realtime/presentation/bloc/technician_realtime/technician_realtime_bloc.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_web/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../support/auth_test_doubles.dart';
import '../../support/console_test_doubles.dart';
import '../../support/realtime_test_doubles.dart';
import '../../support/remote_session_test_doubles.dart';
import '../../support/webrtc_test_doubles.dart';

Future<void> settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// How fast the console offers again once the tablet is back in the signaling
/// room (Prompt 27).
///
/// Everything is real but the transports, as in
/// `technician_console_session_recovery_test.dart`. Times are scaled down: the
/// production answer deadline (30 s) and recovery step (5 s) become
/// [answerDeadline] and [step].
void main() {
  late FakeRemoteSessionRepository remoteSessions;
  late InMemoryPendingRemoteSessionCloseStore pendingCloses;
  late FakeSupportRequestRepository supportRequests;
  late FakeDeviceRepository devices;
  late FakeTechnicianRealtimeClient realtime;
  late TechnicianSignalingClientImpl signaling;
  late FakeWebRtcPeerClient peers;

  late UserSessionBloc userSessionBloc;
  late RemoteSessionBloc remoteSessionBloc;
  late TechnicianRealtimeBloc realtimeBloc;
  late SignalingJoinBloc signalingJoinBloc;
  late SupportRequestsBloc supportRequestsBloc;
  late DevicesBloc devicesBloc;
  late WebRtcSessionBloc webRtcSessionBloc;
  late TechnicianConsoleCoordinator coordinator;

  const answerDeadline = Duration(milliseconds: 600);
  const step = Duration(milliseconds: 100);

  final activeSession = buildRemoteSession(
    status: RemoteSessionStatus.active,
    connectedAt: DateTime.utc(2026, 3, 11, 9, 35, 12),
  );

  setUp(() {
    final auth = FakeAuthRemoteDataSource()
      ..checkStatusResponse = technicianSession;
    final storage = InMemoryUserTokenStorage()..token = 'stored-user-jwt';
    remoteSessions = FakeRemoteSessionRepository();
    pendingCloses = InMemoryPendingRemoteSessionCloseStore();
    supportRequests = FakeSupportRequestRepository();
    devices = FakeDeviceRepository();
    realtime = FakeTechnicianRealtimeClient();
    signaling = TechnicianSignalingClientImpl(
      transport: realtime,
      ackTimeout: const Duration(milliseconds: 50),
    );
    peers = FakeWebRtcPeerClient();

    final authRepository = AuthRepositoryImpl(
      remoteDataSource: auth,
      tokenStorage: storage,
    );
    userSessionBloc = UserSessionBloc(
      restoreSession: RestoreSession(repository: authRepository),
      logOut: LogOut(repository: authRepository),
    );
    remoteSessionBloc = RemoteSessionBloc(
      loadCurrentRemoteSession: LoadCurrentRemoteSession(
        repository: remoteSessions,
      ),
      createRemoteSession: CreateRemoteSession(repository: remoteSessions),
      activateRemoteSession: ActivateRemoteSession(repository: remoteSessions),
      closeRemoteSession: CloseRemoteSession(repository: remoteSessions),
      pendingCloseStore: pendingCloses,
      closeRetryDelays: const [
        Duration(milliseconds: 5),
        Duration(milliseconds: 5),
      ],
    );
    realtimeBloc = TechnicianRealtimeBloc(client: realtime);
    signalingJoinBloc = SignalingJoinBloc(client: realtime);
    supportRequestsBloc = SupportRequestsBloc(
      loadSupportRequests: LoadSupportRequests(repository: supportRequests),
      assignSupportRequest: AssignSupportRequest(repository: supportRequests),
    );
    devicesBloc = DevicesBloc(loadDevices: LoadDevices(repository: devices));
    webRtcSessionBloc = WebRtcSessionBloc(
      peerClient: peers,
      signalingClient: signaling,
      iceConfiguration: const WebRtcIceConfiguration(),
      answerDeadline: answerDeadline,
    );
    coordinator = TechnicianConsoleCoordinator(
      userSessionBloc: userSessionBloc,
      remoteSessionBloc: remoteSessionBloc,
      technicianRealtimeBloc: realtimeBloc,
      signalingJoinBloc: signalingJoinBloc,
      supportRequestsBloc: supportRequestsBloc,
      devicesBloc: devicesBloc,
      webRtcSessionBloc: webRtcSessionBloc,
      realtimeClient: realtime,
      signalingClient: signaling,
      webRtcRecoveryDelays: const [Duration.zero, step, step, step],
    );
  });

  tearDown(() async {
    await coordinator.dispose();
    await Future.wait([
      userSessionBloc.close(),
      remoteSessionBloc.close(),
      realtimeBloc.close(),
      signalingJoinBloc.close(),
      supportRequestsBloc.close(),
      devicesBloc.close(),
      webRtcSessionBloc.close(),
    ]);
    await signaling.dispose();
    await realtime.dispose();
  });

  int offers() => realtime.emittedSignaling
      .where((emission) => emission.event == 'webrtc:offer')
      .length;

  Future<void> deliverOffer() async {
    realtime.answerRelayAck({
      'delivered': true,
      'remoteSessionId': remoteSessionId,
    });
    await settle();
  }

  Future<void> establish() async {
    peers.last
      ..emitPeerState(WebRtcPeerConnectionState.connected)
      ..emitControlChannelState(WebRtcDataChannelState.open)
      ..emitRemoteVideoTrack();
    await settle();
    webRtcSessionBloc.add(
      const WebRtcRemotePictureChanged(
        remoteSessionId: remoteSessionId,
        isDisplayed: true,
      ),
    );
    await settle();
  }

  Future<void> signInWithWorkingAssistance() async {
    remoteSessions.current = activeSession;
    supportRequests.requests = [buildSupportRequest()];
    realtime.peerJoinedOnJoin = true;
    userSessionBloc.add(UserSessionSignedIn(technicianSession));
    await settle();
    coordinator.start();
    await settle();
    realtime.emitConnected();
    await settle();
    await deliverOffer();
    await establish();
    expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
  }

  /// Polls until [count] offers went out, or [limit] passed.
  Future<Duration> timeUntilOffers(int count, {required Duration limit}) async {
    final clock = Stopwatch()..start();
    while (offers() < count && clock.elapsed < limit) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return clock.elapsed;
  }

  group('reproduction (T10A, Prompt 41 B/C)', () {
    test('an offer lost before the tablet rejoined is replaced at once, '
        'not after the answer deadline', () async {
      await signInWithWorkingAssistance();

      // Wi-Fi cut on the tablet: ICE fails on the web; the first recovery
      // reads REST and offers into a room the tablet is not in.
      peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      await settle();
      await deliverOffer();
      expect(offers(), 2);
      expect(webRtcSessionBloc.state, isA<WebRtcConnecting>());

      // The tablet confirmed its authority and joined the room again.
      realtime.emitPeerJoined(remoteSessionId);
      final elapsed = await timeUntilOffers(
        3,
        limit: answerDeadline + step * 4,
      );

      // ignore: avoid_print
      print(
        'next offer ${elapsed.inMilliseconds} ms after peer-joined '
        '(answer deadline ${answerDeadline.inMilliseconds} ms, '
        'step ${step.inMilliseconds} ms)',
      );
      expect(offers(), 3);
      expect(elapsed, lessThan(answerDeadline ~/ 4));
    });
  });
}
