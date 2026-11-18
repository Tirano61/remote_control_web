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
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_command.dart';
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
import 'package:remote_control_web/features/technician_realtime/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/signaling_error_code.dart';
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

/// Lets the event loop drain, so the BLoCs process everything the coordinator
/// dispatched. Several rules chain across BLoCs, hence more than one turn.
Future<void> settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// How the console recovers — or refuses to recover — a remote session when
/// the `/technicians` socket, the backend or the peer connection let it down.
///
/// Everything is real but the transports: the coordinator, every BLoC, the
/// signaling client and the negotiation logic run exactly as in production,
/// over a scripted backend, socket and peer connection.
void main() {
  late FakeRemoteSessionRepository remoteSessions;
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

  final activeSession = buildRemoteSession(
    status: RemoteSessionStatus.active,
    connectedAt: DateTime.utc(2026, 3, 11, 9, 35, 12),
  );

  setUp(() {
    final auth = FakeAuthRemoteDataSource()
      ..checkStatusResponse = technicianSession;
    final storage = InMemoryUserTokenStorage()..token = 'stored-user-jwt';
    remoteSessions = FakeRemoteSessionRepository();
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

  Future<void> signIn() async {
    userSessionBloc.add(UserSessionSignedIn(technicianSession));
    await settle();
    coordinator.start();
    await settle();
  }

  /// The backend relayed the last offer.
  Future<void> deliverOffer({String id = remoteSessionId}) async {
    realtime.answerRelayAck({'delivered': true, 'remoteSessionId': id});
    await settle();
  }

  int offers() => realtime.emittedSignaling
      .where((emission) => emission.event == 'webrtc:offer')
      .length;

  /// The peers of the current negotiation reached each other, the channel is
  /// open, the screen arrives and is displayed.
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

  /// An `ACTIVE` assistance recovered from REST, its peers connected and its
  /// screen on display: remote control is available.
  Future<void> signInWithWorkingAssistance() async {
    remoteSessions.current = activeSession;
    supportRequests.requests = [buildSupportRequest()];
    realtime.peerJoinedOnJoin = true;
    await signIn();
    realtime.emitConnected();
    await settle();
    await deliverOffer();
    await establish();
    expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
    expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
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

  /// The socket drops and comes back: a new connection, as in production.
  Future<void> reconnect() async {
    realtime.emitReconnecting();
    await settle();
    realtime.emitConnected();
    await settle();
  }

  group('reconnection', () {
    test('ACTIVE still there: controls come back only after REST', () async {
      await signInWithWorkingAssistance();
      final peer = peers.last;
      final readsBefore = remoteSessions.currentCount;
      final gate = Completer<void>();
      remoteSessions.currentGate = gate.future;

      await reconnect();

      // The GET was asked for and has not answered: no control yet.
      expect(remoteSessions.currentCount, readsBefore + 1);
      expect(webRtcSessionBloc.state.canSendRemoteControl, isFalse);
      await tap();
      expect(peer.sentRemoteControlCommands, isEmpty);

      gate.complete();
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
      expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
      // The same peer connection, never a second one, and one offer in all.
      expect(peers.sessions, hasLength(1));
      expect(peer.isClosed, isFalse);
      expect(offers(), 1);
      // Joined again: room membership is connection scoped.
      expect(realtime.joinedSessionIds, [remoteSessionId, remoteSessionId]);

      await tap();
      expect(peer.sentRemoteControlCommands, hasLength(1));
    });

    test('REST null: the assistance and everything WebRTC holds go', () async {
      await signInWithWorkingAssistance();
      final peer = peers.last;
      final queueLoadsBefore = supportRequests.loadCount;

      // Closed by the backend (SYSTEM) while the socket was away: the event
      // was lost, and only REST knows.
      realtime.emitReconnecting();
      await settle();
      remoteSessions.current = null;
      realtime.emitConnected();
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(peer.isClosed, isTrue);
      expect(webRtcSessionBloc.state, isA<WebRtcIdle>());
      expect(webRtcSessionBloc.state.isControlChannelOpen, isFalse);
      expect(webRtcSessionBloc.state.canSendRemoteControl, isFalse);
      expect(signalingJoinBloc.state, isA<SignalingIdle>());
      expect(supportRequests.loadCount, greaterThan(queueLoadsBefore));
      await tap();
      expect(peer.sentRemoteControlCommands, isEmpty);
    });

    test('REST answering it CLOSED is no assistance either', () async {
      await signInWithWorkingAssistance();
      final peer = peers.last;

      realtime.emitReconnecting();
      await settle();
      remoteSessions.current = buildRemoteSession(
        status: RemoteSessionStatus.closed,
      );
      realtime.emitConnected();
      await settle();

      expect(remoteSessionBloc.state.hasLiveSession, isFalse);
      expect(peer.isClosed, isTrue);
      expect(webRtcSessionBloc.state, isA<WebRtcIdle>());
    });

    test(
      'an HTTP error is not a confirmation: control stays suspended',
      () async {
        await signInWithWorkingAssistance();
        final peer = peers.last;

        realtime.emitReconnecting();
        await settle();
        remoteSessions.currentFailure = const NetworkFailure();
        realtime.emitConnected();
        await settle();

        // Kept on screen, unconfirmed; the peer connection is left alone.
        expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
        expect(remoteSessionBloc.state.isVerified, isFalse);
        expect(remoteSessionBloc.state.failure, isNotNull);
        expect(peer.isClosed, isFalse);
        expect(webRtcSessionBloc.state.canSendRemoteControl, isFalse);
        await tap();
        expect(peer.sentRemoteControlCommands, isEmpty);

        // REINTENTAR, with the backend reachable again.
        remoteSessions.currentFailure = null;
        remoteSessionBloc.add(const RemoteSessionRefreshRequested());
        await settle();

        expect(remoteSessionBloc.state.isVerified, isTrue);
        expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
        await tap();
        expect(peer.sentRemoteControlCommands, hasLength(1));
      },
    );

    test(
      'a read already in flight cannot answer for the reconnection',
      () async {
        await signInWithWorkingAssistance();
        final readsBefore = remoteSessions.currentCount;
        final gate = Completer<void>();
        remoteSessions.currentGate = gate.future;

        // A GET leaves before the socket drops ...
        remoteSessionBloc.add(const RemoteSessionRefreshRequested());
        await settle();
        await reconnect();
        // ... and the reconnection's GET is folded into it.
        expect(remoteSessions.currentCount, readsBefore + 1);

        remoteSessions.currentGate = null;
        gate.complete();
        await settle();

        // The old answer was dropped and the read made again: only that second
        // read gives the control back.
        expect(remoteSessions.currentCount, readsBefore + 2);
        expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
      },
    );

    test('another session after reconnecting inherits nothing', () async {
      await signInWithWorkingAssistance();
      final oldPeer = peers.last;

      realtime.emitReconnecting();
      await settle();
      // The old one was closed meanwhile and a new one exists for this
      // technician — created from another tab, for instance.
      remoteSessions.current = buildRemoteSession(
        id: 'second-session',
        supportRequestId: 'second-request',
      );
      realtime.emitConnected();
      await settle();

      expect(remoteSessionBloc.state.session!.id, 'second-session');
      expect(oldPeer.isClosed, isTrue);
      expect(webRtcSessionBloc.state.remoteSessionId, isNot(remoteSessionId));
      expect(realtime.joinedSessionIds.last, 'second-session');
      // No command can be aimed at the old session any more ...
      await tap();
      expect(oldPeer.sentRemoteControlCommands, isEmpty);
      // ... and the new one has to go through its own negotiation.
      expect(peers.last, isNot(same(oldPeer)));
      expect(peers.last.remoteSessionId, 'second-session');
      expect(webRtcSessionBloc.state.canSendRemoteControl, isFalse);
    });

    test('the presence and queue re-reads are still made', () async {
      await signInWithWorkingAssistance();
      final devicesBefore = devices.loadCount;
      final queueBefore = supportRequests.loadCount;

      await reconnect();

      expect(devices.loadCount, devicesBefore + 1);
      expect(supportRequests.loadCount, queueBefore + 1);
    });
  });

  group('socket lost', () {
    test(
      'suspends control at once, with the data channel still open',
      () async {
        await signInWithWorkingAssistance();
        final peer = peers.last;
        await tap();
        expect(webRtcSessionBloc.state.remoteControl.pendingCommands, 1);

        realtime.emitReconnecting();
        await settle();

        // WebRTC is untouched ...
        expect(peer.isClosed, isFalse);
        expect(webRtcSessionBloc.state, isA<WebRtcConnected>());
        expect(webRtcSessionBloc.state.isControlChannelOpen, isTrue);
        // ... but remote control is not available, and nothing is pending.
        expect(webRtcSessionBloc.state.canSendRemoteControl, isFalse);
        expect(webRtcSessionBloc.state.canSendRemoteNavigation, isFalse);
        expect(webRtcSessionBloc.state.remoteControl.pendingCommands, 0);
        expect(webRtcSessionBloc.state.remoteControl.lastCommand, isNull);
      },
    );

    test('a command during the suspension is dropped, not queued', () async {
      await signInWithWorkingAssistance();
      final peer = peers.last;
      realtime.emitReconnecting();
      await settle();

      await tap();
      webRtcSessionBloc
        ..add(const WebRtcRemoteBackRequested(remoteSessionId: remoteSessionId))
        ..add(
          const WebRtcRemoteTextRequested(
            remoteSessionId: remoteSessionId,
            text: 'secreto',
          ),
        );
      await settle();
      expect(peer.sentRemoteControlCommands, isEmpty);

      // Coming back sends none of them: nothing was held for later.
      realtime.emitConnected();
      await settle();
      expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
      expect(peer.sentRemoteControlCommands, isEmpty);
    });

    test('a finger down is lifted, and nothing follows it', () async {
      await signInWithWorkingAssistance();
      final peer = peers.last;
      webRtcSessionBloc.add(
        const WebRtcRemoteTouchHoldRequested(
          remoteSessionId: remoteSessionId,
          pointer: 1,
          point: NormalizedRemotePoint(0.5, 0.5),
        ),
      );
      await settle();
      expect(webRtcSessionBloc.state.remoteControl.isTouchActive, isTrue);

      realtime.emitReconnecting();
      await settle();

      expect(webRtcSessionBloc.state.remoteControl.isTouchActive, isFalse);
      final kinds = peer.sentRemoteControlCommands.map((c) => c.kind).toList();
      // The hold, and at most the courtesy cancel that lifts the finger.
      expect(kinds.first, RemoteCommandKind.touchHold);
      expect(kinds.skip(1), everyElement(RemoteCommandKind.touchCancel));
      final count = kinds.length;

      webRtcSessionBloc.add(
        const WebRtcRemoteTouchMoved(
          remoteSessionId: remoteSessionId,
          pointer: 1,
          point: NormalizedRemotePoint(0.7, 0.7),
        ),
      );
      await settle();
      expect(peer.sentRemoteControlCommands, hasLength(count));
    });
  });

  group('remote-session:closed', () {
    for (final endedBy in ['SYSTEM', 'DEVICE', 'TECHNICIAN']) {
      test('$endedBy ends the assistance before REST answers', () async {
        await signInWithWorkingAssistance();
        final peer = peers.last;
        final gate = Completer<void>();
        remoteSessions
          ..current = null
          ..currentGate = gate.future;

        realtime.emitRemoteSessionClosed(remoteSessionId, endedBy: endedBy);
        await settle();

        expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
        expect(peer.isClosed, isTrue);
        expect(webRtcSessionBloc.state, isA<WebRtcIdle>());
        expect(webRtcSessionBloc.state.canSendRemoteControl, isFalse);
        expect(signalingJoinBloc.state, isA<SignalingIdle>());
        await tap();
        expect(peer.sentRemoteControlCommands, isEmpty);

        gate.complete();
        await settle();
        expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      });
    }

    test('during a drag: the touch ends and nothing follows it', () async {
      await signInWithWorkingAssistance();
      final peer = peers.last;
      webRtcSessionBloc.add(
        const WebRtcRemoteTouchHoldRequested(
          remoteSessionId: remoteSessionId,
          pointer: 1,
          point: NormalizedRemotePoint(0.5, 0.5),
        ),
      );
      await settle();
      peer.emitRemoteControlAck(peer.sentRemoteControlCommands.single.id);
      await settle();
      webRtcSessionBloc.add(
        const WebRtcRemoteTouchMoved(
          remoteSessionId: remoteSessionId,
          pointer: 1,
          point: NormalizedRemotePoint(0.6, 0.6),
        ),
      );
      await settle();
      expect(webRtcSessionBloc.state.remoteControl.isTouchActive, isTrue);
      final beforeClose = peer.sentRemoteControlCommands.length;

      remoteSessions.current = null;
      realtime.emitRemoteSessionClosed(remoteSessionId, endedBy: 'SYSTEM');
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(peer.isClosed, isTrue);
      expect(webRtcSessionBloc.state.remoteControl.isTouchActive, isFalse);
      final afterClose = peer.sentRemoteControlCommands
          .skip(beforeClose)
          .map((c) => c.kind);
      expect(afterClose, everyElement(RemoteCommandKind.touchCancel));
      final count = peer.sentRemoteControlCommands.length;

      // The pointer keeps moving and goes up: nothing reaches anybody.
      webRtcSessionBloc
        ..add(
          const WebRtcRemoteTouchMoved(
            remoteSessionId: remoteSessionId,
            pointer: 1,
            point: NormalizedRemotePoint(0.8, 0.8),
          ),
        )
        ..add(
          const WebRtcRemoteTouchReleased(
            remoteSessionId: remoteSessionId,
            pointer: 1,
            point: NormalizedRemotePoint(0.8, 0.8),
          ),
        );
      await settle();
      expect(peer.sentRemoteControlCommands, hasLength(count));
      expect(peers.sessions, hasLength(1));
    });

    test('an old GET answering ACTIVE afterwards changes nothing', () async {
      await signInWithWorkingAssistance();
      final joinsBefore = realtime.joinedSessionIds.length;
      final gate = Completer<void>();
      remoteSessions.currentGate = gate.future;

      // A read leaves while the backend still has the session ACTIVE ...
      remoteSessionBloc.add(const RemoteSessionRefreshRequested());
      await settle();
      // ... the backend closes it and says so ...
      remoteSessions.current = null;
      realtime.emitRemoteSessionClosed(remoteSessionId, endedBy: 'SYSTEM');
      await settle();
      // ... and the old read comes back saying ACTIVE.
      remoteSessions.currentGate = null;
      gate.complete();
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(webRtcSessionBloc.state, isA<WebRtcIdle>());
      expect(peers.sessions, hasLength(1));
      expect(realtime.joinedSessionIds, hasLength(joinsBefore));
      expect(offers(), 1);
    });

    test('an event for another id leaves the assistance alone', () async {
      await signInWithWorkingAssistance();
      final peer = peers.last;

      realtime.emitRemoteSessionClosed('another-session', endedBy: 'SYSTEM');
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
      expect(peer.isClosed, isFalse);
      expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
    });
  });

  group('FINALIZAR', () {
    test('a confirmed close followed by a failed GET stays closed', () async {
      await signInWithWorkingAssistance();
      final peer = peers.last;
      remoteSessions.currentFailure = const NetworkFailure();

      remoteSessionBloc.add(const RemoteSessionCloseRequested());
      await settle();

      expect(remoteSessions.closedIds, [remoteSessionId]);
      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(remoteSessionBloc.state.failure, isNull);
      expect(peer.isClosed, isTrue);
      expect(webRtcSessionBloc.state, isA<WebRtcIdle>());
      expect(webRtcSessionBloc.state.canSendRemoteControl, isFalse);
      // Nothing is joined or negotiated again for it.
      expect(peers.sessions, hasLength(1));
      expect(signalingJoinBloc.state, isA<SignalingIdle>());
    });

    test('a new assistance after a legitimate close starts cleanly', () async {
      await signInWithWorkingAssistance();
      final firstPeer = peers.last;
      remoteSessionBloc.add(const RemoteSessionCloseRequested());
      await settle();
      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());

      remoteSessions.createResponse = buildRemoteSession(
        id: 'second-session',
        supportRequestId: 'second-request',
      );
      remoteSessionBloc.add(
        const RemoteSessionCreateRequested('second-request'),
      );
      await settle();
      await deliverOffer(id: 'second-session');
      await establish(id: 'second-session');

      expect(remoteSessionBloc.state, isA<RemoteSessionActive>());
      expect(remoteSessionBloc.state.session!.id, 'second-session');
      expect(peers.sessions, hasLength(2));
      expect(peers.last.remoteSessionId, 'second-session');
      expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);

      await tap(id: 'second-session');
      expect(peers.last.sentRemoteControlCommands, hasLength(1));
      expect(firstPeer.sentRemoteControlCommands, isEmpty);
      // A tap aimed at the old session reaches nobody.
      await tap();
      expect(peers.last.sentRemoteControlCommands, hasLength(1));
    });
  });

  group('join refused', () {
    test('UNAUTHORIZED reads REST, which ends a closed session', () async {
      remoteSessions.current = activeSession;
      realtime.joinResult = const JoinRemoteSessionRejected(
        SignalingErrorCode.unauthorized,
      );
      await signIn();
      final readsBefore = remoteSessions.currentCount;
      remoteSessions.current = null;

      realtime.emitConnected();
      await settle();

      expect(remoteSessions.currentCount, readsBefore + 1);
      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
    });
  });

  group('WebRTC recovery', () {
    const budget =
        TechnicianConsoleCoordinator.maxAutomaticWebRtcRecoveriesPerSession;

    void answer(String sdp) => realtime.emitSignalingEvent('webrtc:answer', {
      'remoteSessionId': remoteSessionId,
      'from': 'DEVICE',
      'sdp': sdp,
    });

    test('FAILED asks REST first, then makes exactly one new offer', () async {
      await signInWithWorkingAssistance();
      final failed = peers.last;
      final readsBefore = remoteSessions.currentCount;
      final gate = Completer<void>();
      remoteSessions.currentGate = gate.future;

      failed.emitPeerState(WebRtcPeerConnectionState.failed);
      await settle();

      // Released at once, and nothing renegotiated before REST answers.
      expect(failed.isClosed, isTrue);
      expect(webRtcSessionBloc.state, isA<WebRtcFailed>());
      expect(webRtcSessionBloc.state.canSendRemoteControl, isFalse);
      expect(remoteSessions.currentCount, readsBefore + 1);
      expect(peers.sessions, hasLength(1));
      expect(offers(), 1);

      remoteSessions.currentGate = null;
      gate.complete();
      await settle();

      // Still ACTIVE in the backend: one new peer connection, one new offer.
      expect(peers.sessions, hasLength(2));
      expect(offers(), 2);
      // The same RemoteSession: nothing was created, nothing accepted again.
      expect(remoteSessions.createdSupportRequestIds, isEmpty);
      expect(remoteSessions.activatedIds, isEmpty);
      expect(peers.last.remoteSessionId, remoteSessionId);

      await deliverOffer();
      await establish();
      expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
      await tap();
      expect(peers.last.sentRemoteControlCommands, hasLength(1));
      expect(failed.sentRemoteControlCommands, isEmpty);
    });

    test('the recovery never leaves two peer connections', () async {
      await signInWithWorkingAssistance();
      peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      await settle();
      await deliverOffer();

      // Every trigger that re-evaluates readiness, again.
      realtime.emitPeerJoined(remoteSessionId);
      remoteSessionBloc.add(const RemoteSessionRefreshRequested());
      await settle();

      expect(peers.sessions, hasLength(2));
      expect(peers.sessions.where((peer) => !peer.isClosed), hasLength(1));
      expect(offers(), 2);
    });

    test('a late ACK and an unexpected answer change nothing', () async {
      await signInWithWorkingAssistance();
      peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      await settle();
      final recovering = peers.last;
      expect(peers.sessions, hasLength(2));

      // An answer before the new offer was even relayed: nothing waits for
      // one, so it is ignored rather than applied to the new connection.
      answer('v=0 stale answer');
      await settle();
      expect(recovering.appliedAnswers, isEmpty);

      // The new offer is relayed, then the acknowledgement arrives twice.
      await deliverOffer();
      await deliverOffer();
      expect(webRtcSessionBloc.state, isA<WebRtcConnecting>());

      answer('v=0 answer');
      answer('v=0 duplicate answer');
      await settle();
      expect(recovering.appliedAnswers, hasLength(1));
      expect(peers.sessions, hasLength(2));
      expect(offers(), 2);
    });

    test('the old data channel speaks for nothing any more', () async {
      await signInWithWorkingAssistance();
      final failed = peers.last;
      failed.emitPeerState(WebRtcPeerConnectionState.failed);
      await settle();
      await deliverOffer();
      final recovering = peers.last;

      // Late callbacks of the failed peer connection.
      failed
        ..emitControlChannelState(WebRtcDataChannelState.open)
        ..emitPeerState(WebRtcPeerConnectionState.connected)
        ..emitRemoteVideoTrack('old-screen')
        ..emitRemoteControlAck('tap-1');
      await settle();

      // None of it is taken for the new negotiation.
      expect(webRtcSessionBloc.state, isA<WebRtcConnecting>());
      expect(webRtcSessionBloc.state.isControlChannelOpen, isFalse);
      expect(webRtcSessionBloc.state.hasRemoteVideo, isFalse);
      expect(webRtcSessionBloc.state.canSendRemoteControl, isFalse);
      await tap();
      expect(failed.sentRemoteControlCommands, isEmpty);
      expect(recovering.sentRemoteControlCommands, isEmpty);
    });

    test('a close arriving during the recovery wins', () async {
      await signInWithWorkingAssistance();
      final gate = Completer<void>();
      remoteSessions.currentGate = gate.future;

      peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      await settle();
      // The backend closes it while the recovery's GET travels ...
      remoteSessions.current = null;
      realtime.emitRemoteSessionClosed(remoteSessionId, endedBy: 'SYSTEM');
      await settle();
      // ... and that GET comes back with what it read: ACTIVE.
      remoteSessions.currentGate = null;
      gate.complete();
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(webRtcSessionBloc.state, isA<WebRtcIdle>());
      expect(peers.sessions, hasLength(1));
      expect(offers(), 1);
    });

    test('REST without the session: nothing is renegotiated', () async {
      await signInWithWorkingAssistance();
      remoteSessions.current = null;

      peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      await settle();

      expect(remoteSessionBloc.state, isA<RemoteSessionIdle>());
      expect(peers.sessions, hasLength(1));
      expect(offers(), 1);
    });

    test('REST failing: no offer until a read confirms the session', () async {
      await signInWithWorkingAssistance();
      remoteSessions.currentFailure = const NetworkFailure();

      peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      await settle();
      expect(remoteSessionBloc.state.isVerified, isFalse);
      expect(peers.sessions, hasLength(1));

      remoteSessions.currentFailure = null;
      remoteSessionBloc.add(const RemoteSessionRefreshRequested());
      await settle();

      expect(peers.sessions, hasLength(2));
      expect(offers(), 2);
    });

    test('the budget bounds the attempts, without a timer', () async {
      await signInWithWorkingAssistance();

      // Every new peer connection fails before connecting.
      for (var attempt = 0; attempt <= budget; attempt++) {
        peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
        await settle();
        await deliverOffer();
      }

      expect(peers.sessions, hasLength(budget + 1));
      expect(webRtcSessionBloc.state, isA<WebRtcFailed>());
      // Nothing more happens on its own, however long it waits.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await settle();
      expect(peers.sessions, hasLength(budget + 1));
      expect(offers(), budget + 1);
    });

    test('a connection that worked again gives the budget back', () async {
      await signInWithWorkingAssistance();

      for (var round = 0; round < budget + 1; round++) {
        peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
        await settle();
        await deliverOffer();
        await establish();
        expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
      }

      expect(peers.sessions, hasLength(budget + 2));
    });

    test('a reconnection after the budget negotiates again', () async {
      await signInWithWorkingAssistance();
      for (var attempt = 0; attempt <= budget; attempt++) {
        peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
        await settle();
        await deliverOffer();
      }
      expect(peers.sessions, hasLength(budget + 1));

      // A genuinely new situation: a new socket, joined again.
      await reconnect();

      expect(peers.sessions, hasLength(budget + 2));
    });
  });

  group('presence', () {
    test(
      'device:presence-updated still reloads both lists, nothing else',
      () async {
        await signInWithWorkingAssistance();
        final devicesBefore = devices.loadCount;
        final queueBefore = supportRequests.loadCount;
        final readsBefore = remoteSessions.currentCount;

        realtime.emitDevicePresenceUpdated(deviceId);
        await settle();

        expect(devices.loadCount, devicesBefore + 1);
        expect(supportRequests.loadCount, queueBefore + 1);
        // Presence is not authority: the session is neither read nor touched.
        expect(remoteSessions.currentCount, readsBefore);
        expect(webRtcSessionBloc.state.canSendRemoteControl, isTrue);
      },
    );
  });
}
