import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/app/console/technician_console_coordinator.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/auth/domain/usecases/log_out.dart';
import 'package:remote_control_web/features/auth/domain/usecases/restore_session.dart';
import 'package:remote_control_web/features/auth/presentation/bloc/user_session/user_session_bloc.dart';
import 'package:remote_control_web/features/devices/domain/usecases/load_devices.dart';
import 'package:remote_control_web/features/devices/presentation/bloc/devices/devices_bloc.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
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
/// room (Prompt 27), and everything that must not change because of it.
///
/// Everything is real but the transports, as in
/// `technician_console_session_recovery_test.dart`. Times are scaled down:
/// the first offer's answer deadline (30 s in production), the recovery
/// offers' one (10 s) and the recovery step (5 s) become [answerDeadline],
/// [recoveryDeadline] and [step].
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
  const recoveryDeadline = Duration(milliseconds: 200);
  const step = Duration(milliseconds: 100);
  const budget =
      TechnicianConsoleCoordinator.maxAutomaticWebRtcRecoveriesPerSession;

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
      recoveryAnswerDeadline: recoveryDeadline,
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

  int candidatesRelayed() => realtime.emittedSignaling
      .where((emission) => emission.event == 'webrtc:ice-candidate')
      .length;

  Future<void> deliverOffer({String id = remoteSessionId}) async {
    realtime.answerRelayAck({'delivered': true, 'remoteSessionId': id});
    await settle();
  }

  void answer(String sdp, {String id = remoteSessionId}) =>
      realtime.emitSignalingEvent('webrtc:answer', {
        'remoteSessionId': id,
        'from': 'DEVICE',
        'sdp': sdp,
      });

  Future<void> peerJoined({String id = remoteSessionId}) async {
    realtime.emitPeerJoined(id);
    await settle();
  }

  Future<void> establish({String id = remoteSessionId}) async {
    peers.last
      ..emitPeerState(WebRtcPeerConnectionState.connected)
      ..emitControlChannelState(WebRtcDataChannelState.open)
      ..emitRemoteVideoTrack();
    await settle();
    webRtcSessionBloc.add(
      WebRtcRemotePictureChanged(remoteSessionId: id, isDisplayed: true),
    );
    await settle();
  }

  Future<void> tap({String id = remoteSessionId}) async {
    webRtcSessionBloc.add(
      WebRtcRemoteTapRequested(
        remoteSessionId: id,
        point: const NormalizedRemotePoint(0.5, 0.5),
      ),
    );
    await settle();
  }

  Future<void> signIn() async {
    userSessionBloc.add(UserSessionSignedIn(technicianSession));
    await settle();
    coordinator.start();
    await settle();
  }

  Future<void> signInWithWorkingAssistance() async {
    remoteSessions.current = activeSession;
    supportRequests.requests = [buildSupportRequest()];
    realtime.peerJoinedOnJoin = true;
    await signIn();
    realtime.emitConnected();
    await settle();
    await deliverOffer();
    await establish();
    expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
  }

  /// The tablet's Wi-Fi cut as seen on the T10A: ICE fails here, the first
  /// recovery reads REST and its offer is relayed into a room the tablet is
  /// no longer in. Nobody answers it.
  Future<void> cutAndLoseTheRecoveryOffer() async {
    peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
    await settle();
    await deliverOffer();
    expect(webRtcSessionBloc.state, isA<WebRtcConnecting>());
    expect(webRtcSessionBloc.state.isOfferLost, isFalse);
  }

  /// Polls until [count] offers went out, or [limit] passed.
  Future<Duration> timeUntilOffers(int count, {required Duration limit}) async {
    final clock = Stopwatch()..start();
    while (offers() < count && clock.elapsed < limit) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return clock.elapsed;
  }

  Future<void> wait(Duration duration) async {
    await Future<void>.delayed(duration);
    await settle();
  }

  group('reproduction (T10A, Prompt 41 B/C)', () {
    test('an offer lost before the tablet rejoined is replaced at once, '
        'not after the answer deadline', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();
      expect(offers(), 2);

      // The tablet confirmed its authority and joined the room again.
      realtime.emitPeerJoined(remoteSessionId);
      final elapsed = await timeUntilOffers(
        3,
        limit: answerDeadline + step * 4,
      );

      // Before Prompt 27: 707 ms here, the answer deadline (600) + the step
      // (100) — 30 s + 5 s on the T10A, ~53 s from the cut.
      // ignore: avoid_print
      print(
        'next offer ${elapsed.inMilliseconds} ms after peer-joined '
        '(answer deadline ${recoveryDeadline.inMilliseconds} ms, '
        'step ${step.inMilliseconds} ms)',
      );
      expect(offers(), 3);
      expect(elapsed, lessThan(recoveryDeadline ~/ 2));
    });
  });

  group('the offer and the tablet coming back', () {
    test('1. a normal first offer: one offer, and an arrival once connected '
        'changes nothing', () async {
      await signInWithWorkingAssistance();
      expect(offers(), 1);

      await peerJoined();
      await wait(answerDeadline);

      expect(offers(), 1);
      expect(peers.sessions, hasLength(1));
      expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
    });

    test('2. an offer relayed while the tablet is away just waits', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();
      await wait(step);

      expect(offers(), 2);
      expect(webRtcSessionBloc.state.isOfferLost, isFalse);
      expect(webRtcSessionBloc.state.isAnswerOverdue, isFalse);
    });

    test('3/4. a valid return marks it lost, REST is read, and one new offer '
        'goes out at once', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();
      final lost = peers.last;
      final reads = remoteSessions.currentCount;
      final gate = Completer<void>();
      remoteSessions.currentGate = gate.future;

      await peerJoined();

      // Lost, not failed: nothing torn down, and REST before anything.
      expect(webRtcSessionBloc.state.isOfferLost, isTrue);
      expect(webRtcSessionBloc.state.isAnswerOverdue, isFalse);
      expect(webRtcSessionBloc.state.isTabletSilent, isFalse);
      expect(webRtcSessionBloc.state.isRecoveryScheduled, isTrue);
      expect(lost.isClosed, isFalse);
      expect(remoteSessions.currentCount, reads + 1);
      expect(offers(), 2);

      remoteSessions.currentGate = null;
      gate.complete();
      await settle();

      expect(lost.isClosed, isTrue);
      expect(peers.sessions, hasLength(3));
      expect(peers.sessions.where((peer) => !peer.isClosed), hasLength(1));
      expect(offers(), 3);
      expect(webRtcSessionBloc.state.isOfferLost, isFalse);
    });

    test(
      '5. an offer that got its answer is progressing: left alone',
      () async {
        await signInWithWorkingAssistance();
        await cutAndLoseTheRecoveryOffer();
        answer('v=0 answer');
        await settle();
        expect(peers.last.appliedAnswers, hasLength(1));

        await peerJoined();
        await wait(step);

        expect(webRtcSessionBloc.state.isOfferLost, isFalse);
        expect(peers.sessions, hasLength(2));
        expect(offers(), 2);
      },
    );

    test('5b. an answer that still comes for an offer taken for lost is '
        'applied, and nothing replaces it', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();
      final gate = Completer<void>();
      remoteSessions.currentGate = gate.future;
      await peerJoined();
      expect(webRtcSessionBloc.state.isOfferLost, isTrue);

      answer('v=0 answer after all');
      await settle();
      expect(peers.last.appliedAnswers, hasLength(1));
      expect(webRtcSessionBloc.state.isOfferLost, isFalse);

      remoteSessions.currentGate = null;
      gate.complete();
      await settle();
      expect(peers.sessions, hasLength(2));
      expect(offers(), 2);
    });

    test('6. two peer-joined: one replacement', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();

      realtime
        ..emitPeerJoined(remoteSessionId)
        ..emitPeerJoined(remoteSessionId);
      await settle();
      await deliverOffer();
      // A late duplicate after the new offer was relayed is the tablet
      // coming back once more, which only its own reconnection produces;
      // the one in flight with the first is absorbed by the REST read.
      await wait(step);

      expect(peers.sessions, hasLength(3));
      expect(peers.sessions.where((peer) => !peer.isClosed), hasLength(1));
      expect(offers(), 3);
    });

    test('7. peer-joined of another session changes nothing', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();

      await peerJoined(id: '9a0f3d1b-4c88-9e64-6f2a-5c7e8b103d1b');
      await wait(step);

      expect(webRtcSessionBloc.state.isOfferLost, isFalse);
      expect(offers(), 2);
    });

    test('8. readiness heard while this socket was still joining is not an '
        'arrival against a later offer', () async {
      // On /technicians the event only ever describes the tablet side: the
      // backend announces a join to the OPPOSITE namespace, so another tab of
      // this technician never produces it. What the console can still get
      // wrong is when it heard it.
      remoteSessions.current = activeSession;
      supportRequests.requests = [buildSupportRequest()];
      final gate = Completer<void>();
      realtime.joinGate = gate.future;
      await signIn();
      realtime.emitConnected();
      await settle();
      expect(signalingJoinBloc.state, isA<SignalingJoining>());
      realtime.emitPeerJoined(remoteSessionId);
      await settle();
      realtime.joinGate = null;
      gate.complete();
      await settle();

      // Readiness from the event that overtook the ACK: the first offer.
      expect(offers(), 1);
      await deliverOffer();
      await wait(step);
      expect(webRtcSessionBloc.state.isOfferLost, isFalse);
      expect(offers(), 1);
    });
  });

  group('generations', () {
    test(
      '9. the old peer connection reporting CONNECTED changes nothing',
      () async {
        await signInWithWorkingAssistance();
        await cutAndLoseTheRecoveryOffer();
        final lost = peers.last;
        await peerJoined();
        expect(peers.sessions, hasLength(3));

        lost
          ..emitPeerState(WebRtcPeerConnectionState.connected)
          ..emitControlChannelState(WebRtcDataChannelState.open)
          ..emitRemoteVideoTrack('old-screen');
        await settle();

        expect(webRtcSessionBloc.state, isNot(isA<WebRtcConnected>()));
        expect(webRtcSessionBloc.state.hasRemoteVideo, isFalse);
        expect(webRtcSessionBloc.state.canSendRemoteControl, isFalse);
      },
    );

    test('10. ICE FAILED while an attempt waits: it runs now, with the '
        'schedule given back', () async {
      await signInWithWorkingAssistance();
      // Attempt 1 at once, failed too: attempt 2 waits for its step.
      peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      await settle();
      await deliverOffer();
      peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      await settle();
      expect(webRtcSessionBloc.state, isA<WebRtcFailed>());
      expect(webRtcSessionBloc.state.isRecoveryScheduled, isTrue);
      expect(peers.sessions, hasLength(2));

      await peerJoined();

      expect(peers.sessions, hasLength(3));
      expect(offers(), 3);
      await deliverOffer();
      // Nothing doubled when the planned time would have come.
      await wait(step * 2);
      expect(peers.sessions, hasLength(3));
    });

    test(
      '11. ICE DISCONNECTED is not replaced because the tablet is back',
      () async {
        await signInWithWorkingAssistance();
        final peer = peers.last;
        peer.emitPeerState(WebRtcPeerConnectionState.disconnected);
        await settle();

        await peerJoined();
        await wait(step);

        expect(webRtcSessionBloc.state, isA<WebRtcInterrupted>());
        expect(peer.isClosed, isFalse);
        expect(offers(), 1);

        // When it does fail, the attempt is immediate.
        peer.emitPeerState(WebRtcPeerConnectionState.failed);
        await settle();
        expect(offers(), 2);
      },
    );

    test('12. the answer to the old offer, late, is not applied to the new '
        'one', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();
      await peerJoined();
      final replacement = peers.last;

      // Before the new offer was even relayed: nothing waits for an answer.
      answer('v=0 stale answer');
      await settle();
      expect(replacement.appliedAnswers, isEmpty);

      await deliverOffer();
      answer('v=0 answer');
      answer('v=0 duplicate');
      await settle();
      expect(replacement.appliedAnswers, hasLength(1));
    });

    test('13. ICE of the replaced peer connection goes nowhere', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();
      final lost = peers.last;
      await peerJoined();
      await deliverOffer();
      final relayedBefore = candidatesRelayed();

      lost.emitLocalCandidate('candidate:old 1 udp 1 10.0.0.1 5000 typ host');
      await settle();
      expect(candidatesRelayed(), relayedBefore);

      // A remote candidate before the new answer waits for it, and only
      // ever reaches the new peer connection.
      realtime.emitSignalingEvent('webrtc:ice-candidate', {
        'remoteSessionId': remoteSessionId,
        'from': 'DEVICE',
        'candidate': 'candidate:1 1 udp 1 10.0.0.2 5001 typ host',
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      });
      await settle();
      expect(lost.addedIceCandidates, isEmpty);
      answer('v=0 answer');
      await settle();
      expect(peers.last.addedIceCandidates, hasLength(1));
    });
  });

  group('the console socket and presence', () {
    test('14/15. socket down before the replacement: nothing offered while '
        'down, one offer when it is back', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();
      final gate = Completer<void>();
      remoteSessions.currentGate = gate.future;
      await peerJoined();

      realtime.emitReconnecting();
      await settle();
      remoteSessions.currentGate = null;
      gate.complete();
      await settle();
      // No room to offer into; the unfinished negotiation is dropped.
      expect(offers(), 2);
      expect(peers.sessions.every((peer) => peer.isClosed), isTrue);

      realtime.emitConnected();
      await settle();
      expect(offers(), 3);
      expect(peers.sessions.where((peer) => !peer.isClosed), hasLength(1));

      // The ACK of the new socket is not an arrival.
      await deliverOffer();
      await wait(step);
      expect(offers(), 3);
    });

    test('16. the tablet ONLINE without re-entering the room offers '
        'nothing', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();

      devices.devices = [buildDevice()];
      realtime.emitDevicePresenceUpdated(deviceId);
      await wait(step);

      expect(webRtcSessionBloc.state.isOfferLost, isFalse);
      expect(offers(), 2);
    });

    test('17. back in the room, REST not confirming yet: no offer until it '
        'does; a failed read waits for the next step', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();
      remoteSessions.currentFailure = const NetworkFailure();

      await peerJoined();
      expect(webRtcSessionBloc.state.isOfferLost, isTrue);
      expect(offers(), 2);
      expect(webRtcSessionBloc.state.isRecoveryScheduled, isTrue);

      remoteSessions.currentFailure = null;
      await wait(step + const Duration(milliseconds: 30));
      expect(offers(), 3);
    });
  });

  group('fallback without peer-joined', () {
    test('18/19. a recovery offer nobody answers is replaced after the '
        'recovery deadline, not the first offer one', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();

      final elapsed = await timeUntilOffers(
        3,
        limit: answerDeadline + step * 2,
      );

      expect(offers(), 3);
      expect(elapsed, greaterThanOrEqualTo(recoveryDeadline));
      expect(elapsed, lessThan(answerDeadline));
    });

    test('18b. the first offer of an assistance keeps its longer deadline '
        '(MediaProjection consent)', () async {
      remoteSessions.current = activeSession;
      supportRequests.requests = [buildSupportRequest()];
      realtime.peerJoinedOnJoin = true;
      await signIn();
      realtime.emitConnected();
      await settle();
      await deliverOffer();

      await wait(recoveryDeadline + step);
      expect(webRtcSessionBloc.state.isAnswerOverdue, isFalse);
      expect(offers(), 1);
    });

    test(
      '20. spent schedule: bounded; a later arrival tries once more',
      () async {
        await signInWithWorkingAssistance();
        await cutAndLoseTheRecoveryOffer();
        for (var round = 0; round < budget + 1; round++) {
          await wait(
            recoveryDeadline + step + const Duration(milliseconds: 20),
          );
          await deliverOffer();
        }
        final spent = offers();
        expect(spent, budget + 1);
        expect(webRtcSessionBloc.state.isRecoveryScheduled, isFalse);
        await wait(recoveryDeadline + step);
        expect(offers(), spent);

        // The tablet comes back once more: a new situation, one more offer.
        await peerJoined();
        expect(offers(), spent + 1);
      },
    );
  });

  group('the assistance ending', () {
    test('21. REST answering CLOSED (SYSTEM) after the arrival: no offer, '
        'nothing reopened', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();
      remoteSessions.current = buildRemoteSession(
        status: RemoteSessionStatus.closed,
      );

      await peerJoined();

      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(webRtcSessionBloc.state, isA<WebRtcIdle>());
      expect(offers(), 2);
    });

    test(
      '21b. remote-session:closed SYSTEM while the arrival reads REST',
      () async {
        await signInWithWorkingAssistance();
        await cutAndLoseTheRecoveryOffer();
        final gate = Completer<void>();
        remoteSessions.currentGate = gate.future;
        await peerJoined();

        remoteSessions.current = null;
        realtime.emitRemoteSessionClosed(remoteSessionId, endedBy: 'SYSTEM');
        await settle();
        remoteSessions.currentGate = null;
        gate.complete();
        await settle();

        expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
        expect(webRtcSessionBloc.state, isA<WebRtcIdle>());
        expect(offers(), 2);
      },
    );

    test(
      '22. FINALIZAR while the arrival reads REST: nothing goes out',
      () async {
        await signInWithWorkingAssistance();
        await cutAndLoseTheRecoveryOffer();
        final gate = Completer<void>();
        remoteSessions.currentGate = gate.future;
        await peerJoined();

        remoteSessionBloc.add(const RemoteSessionCloseRequested());
        await settle();
        remoteSessions.currentGate = null;
        gate.complete();
        await settle();
        await wait(step);

        expect(remoteSessions.closedIds, [remoteSessionId]);
        expect(remoteSessionBloc.state.hasLiveSession, isFalse);
        expect(peers.sessions.every((peer) => peer.isClosed), isTrue);
        expect(offers(), 2);
      },
    );

    test(
      '23. a close still pending: an arrival offers and joins nothing',
      () async {
        await signInWithWorkingAssistance();
        await cutAndLoseTheRecoveryOffer();
        remoteSessions.closeFailure = const NetworkFailure();
        remoteSessionBloc.add(const RemoteSessionCloseRequested());
        await settle();
        expect(pendingCloses.ids, {remoteSessionId});
        final joins = realtime.joinedSessionIds.length;

        await peerJoined();
        await wait(step);

        expect(remoteSessionBloc.state.hasLiveSession, isFalse);
        expect(realtime.joinedSessionIds, hasLength(joins));
        expect(offers(), 2);
      },
    );

    test('30. after remote-session:closed nothing comes back', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();
      remoteSessions.current = null;
      realtime.emitRemoteSessionClosed(remoteSessionId, endedBy: 'DEVICE');
      await settle();

      await peerJoined();
      answer('v=0 late answer');
      await wait(step);

      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(webRtcSessionBloc.state, isA<WebRtcIdle>());
      expect(offers(), 2);
    });
  });

  group('next assistances and repeated cuts', () {
    test('24/25. a new assistance starts clean, and nothing of the previous '
        'one counts', () async {
      await signInWithWorkingAssistance();
      await cutAndLoseTheRecoveryOffer();
      await peerJoined();
      remoteSessions.current = null;
      realtime.emitRemoteSessionClosed(remoteSessionId, endedBy: 'DEVICE');
      await settle();

      const second = 'second-session';
      remoteSessions.createResponse = buildRemoteSession(
        id: second,
        supportRequestId: 'second-request',
      );
      remoteSessionBloc.add(
        const RemoteSessionCreateRequested('second-request'),
      );
      await settle();
      final offersBefore = offers();
      expect(offersBefore, 4);

      // A late arrival or answer of the first session: not about this one.
      await peerJoined();
      answer('v=0 answer of the first session');
      await settle();
      expect(offers(), offersBefore);
      expect(peers.last.appliedAnswers, isEmpty);

      await deliverOffer(id: second);
      await establish(id: second);
      expect(remoteSessionBloc.state.session!.id, second);
      expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);

      // Its own cut is recovered the same way.
      peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      await settle();
      await deliverOffer(id: second);
      await peerJoined(id: second);
      expect(offers(), offersBefore + 2);
    });

    test('26/27/28/29. three cuts in a row: one peer at a time, the same '
        'session, video and control back each time', () async {
      await signInWithWorkingAssistance();

      for (var cut = 1; cut <= 3; cut++) {
        await cutAndLoseTheRecoveryOffer();
        await peerJoined();
        await deliverOffer();
        answer('v=0 answer $cut');
        await settle();
        await establish();

        expect(peers.sessions.where((peer) => !peer.isClosed), hasLength(1));
        expect(webRtcSessionBloc.state.hasRemoteVideo, isTrue);
        expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
        await tap();
        expect(peers.last.sentRemoteControlCommands, hasLength(1));
      }

      // 1 + 3 x (lost recovery offer + its replacement).
      expect(offers(), 7);
      // The capture belongs to the RemoteSession, which never changed: no
      // new assistance, no new acceptance asked for, nothing closed.
      expect(remoteSessions.createdSupportRequestIds, isEmpty);
      expect(remoteSessions.activatedIds, isEmpty);
      expect(remoteSessions.closedIds, isEmpty);
      expect(peers.sessions.map((peer) => peer.remoteSessionId).toSet(), {
        remoteSessionId,
      });
    });

    test(
      '29b. the arrival never gives remote control back on its own',
      () async {
        await signInWithWorkingAssistance();
        final gate = Completer<void>();
        remoteSessions.currentGate = gate.future;
        // The console's socket comes back: control waits for its REST check.
        realtime.emitReconnecting();
        await settle();
        realtime.emitConnected();
        await settle();
        expect(webRtcSessionBloc.state.canSendRemoteNavigation, isFalse);

        await peerJoined();
        expect(webRtcSessionBloc.state.canSendRemoteNavigation, isFalse);

        remoteSessions.currentGate = null;
        gate.complete();
        await settle();
        expect(webRtcSessionBloc.state.canSendRemoteNavigation, isTrue);
      },
    );
  });
}
