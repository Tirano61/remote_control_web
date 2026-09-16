import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/app/composition_root.dart';
import 'package:remote_control_web/app/remote_control_app.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/remote_session/data/repositories/remote_session_repository_impl.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_web/features/signaling/data/technician_signaling_client_impl.dart';
import 'package:remote_control_web/features/support/domain/entities/support_request_status.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_connection_state.dart';

import '../../../support/auth_test_doubles.dart';
import '../../../support/console_test_doubles.dart';
import '../../../support/realtime_test_doubles.dart';
import '../../../support/webrtc_test_doubles.dart';
import '../../../support/remote_session_test_doubles.dart';

void main() {
  late FakeAuthRemoteDataSource auth;
  late InMemoryUserTokenStorage storage;
  late FakeDeviceRepository devices;
  late FakeSupportRequestRepository supportRequests;
  late FakeRemoteSessionRepository remoteSessions;
  late FakeTechnicianRealtimeClient realtime;
  late FakeWebRtcPeerClient peers;

  setUp(() {
    auth = FakeAuthRemoteDataSource()..checkStatusResponse = technicianSession;
    storage = InMemoryUserTokenStorage()..token = 'stored-user-jwt';
    devices = FakeDeviceRepository();
    supportRequests = FakeSupportRequestRepository();
    remoteSessions = FakeRemoteSessionRepository();
    realtime = FakeTechnicianRealtimeClient();
    peers = FakeWebRtcPeerClient();
  });

  /// The request this technician owns and the tablet already accepted.
  void withAcceptedRequest() {
    supportRequests.requests = [
      buildSupportRequest(
        status: SupportRequestStatus.accepted,
        technician: technicianId,
        respondedAt: DateTime.utc(2026, 3, 11, 9, 32),
      ),
    ];
  }

  /// Advances the UI without waiting for it to become still.
  ///
  /// The assistance view shows a progress indicator for as long as the session
  /// is `CONNECTING`, so `pumpAndSettle` would never return there.
  Future<void> settleUi(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> pumpConsole(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RemoteControlApp(
        dependencies: AppDependencies(
          config: const AppConfig(backendBaseUrl: 'http://localhost:3000'),
          authRepository: AuthRepositoryImpl(
            remoteDataSource: auth,
            tokenStorage: storage,
          ),
          deviceRepository: devices,
          supportRequestRepository: supportRequests,
          remoteSessionRepository: remoteSessions,
          technicianRealtimeClient: realtime,
          technicianSignalingClient: TechnicianSignalingClientImpl(
            transport: realtime,
          ),
          webRtcPeerClient: peers,
        ),
      ),
    );
    await settleUi(tester);
  }

  Future<void> connectSocket(WidgetTester tester) async {
    realtime.emitConnected();
    await settleUi(tester);
  }

  Future<void> startAssistance(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey('start_assistance_button_$requestId')),
    );
    await settleUi(tester);
  }

  group('INICIAR ASISTENCIA', () {
    testWidgets('is offered for an accepted request of this technician', (
      tester,
    ) async {
      withAcceptedRequest();

      await pumpConsole(tester);

      expect(find.text('INICIAR ASISTENCIA'), findsOneWidget);
      expect(find.text('Estado: Usuario autorizó la asistencia'), findsOneWidget);
    });

    testWidgets('is not offered while the tablet has not answered', (
      tester,
    ) async {
      supportRequests.requests = [
        buildSupportRequest(
          status: SupportRequestStatus.assigned,
          technician: technicianId,
        ),
      ];

      await pumpConsole(tester);

      expect(find.text('INICIAR ASISTENCIA'), findsNothing);
    });

    testWidgets('is not offered for a request of another technician', (
      tester,
    ) async {
      supportRequests.requests = [
        buildSupportRequest(
          status: SupportRequestStatus.accepted,
          technician: 'another-technician',
        ),
      ];

      await pumpConsole(tester);

      expect(find.text('INICIAR ASISTENCIA'), findsNothing);
    });

    testWidgets('opens the assistance view in CONNECTING', (tester) async {
      withAcceptedRequest();
      await pumpConsole(tester);

      await startAssistance(tester);

      expect(remoteSessions.createdSupportRequestIds, [requestId]);
      expect(find.byKey(const Key('active_assistance_section')), findsOneWidget);
      expect(find.text('ASISTENCIA REMOTA'), findsOneWidget);
      expect(
        find.text('Estado: Conectando con el dispositivo...'),
        findsOneWidget,
      );
      expect(find.text('Tablet Prueba'), findsWidgets);
      expect(find.text('132-491-092'), findsWidgets);
      expect(find.text('FINALIZAR ASISTENCIA'), findsOneWidget);
    });

    testWidgets('a live session hides the action on other requests', (
      tester,
    ) async {
      supportRequests.requests = [
        buildSupportRequest(
          status: SupportRequestStatus.accepted,
          technician: technicianId,
        ),
        buildSupportRequest(
          id: 'second-request',
          status: SupportRequestStatus.accepted,
          technician: technicianId,
        ),
      ];
      await pumpConsole(tester);
      expect(find.text('INICIAR ASISTENCIA'), findsNWidgets(2));

      await startAssistance(tester);

      // One live session per technician: a second start could only be a 409.
      expect(find.text('INICIAR ASISTENCIA'), findsNothing);
      expect(find.byKey(const Key('active_assistance_section')), findsOneWidget);
    });

    testWidgets('a 409 shows the session the technician already had', (
      tester,
    ) async {
      // The console believed it had no assistance open — the response of an
      // earlier create was lost, or another tab started one.
      withAcceptedRequest();
      final gate = Completer<void>();
      remoteSessions
        ..current = null
        ..createFailure = const ConflictFailure(kCreateConflictMessage)
        ..createGate = gate.future;
      await pumpConsole(tester);
      expect(find.text('INICIAR ASISTENCIA'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('start_assistance_button_$requestId')),
      );
      await tester.pump();
      // What the backend really has while it answers the conflict.
      remoteSessions.current = buildRemoteSession(
        supportRequestId: 'another-request',
      );
      gate.complete();
      await settleUi(tester);

      // Reconciled: the assistance is shown and no error is reported.
      expect(find.byKey(const Key('active_assistance_section')), findsOneWidget);
      expect(find.byKey(const Key('remote_session_error_banner')), findsNothing);
      expect(find.text('INICIAR ASISTENCIA'), findsNothing);
    });

    testWidgets('a 409 with nothing to recover reports the conflict', (
      tester,
    ) async {
      withAcceptedRequest();
      remoteSessions.createFailure = const ConflictFailure(
        kCreateConflictMessage,
      );
      await pumpConsole(tester);

      await startAssistance(tester);

      expect(find.text(kCreateConflictMessage), findsOneWidget);
      expect(find.byKey(const Key('active_assistance_section')), findsNothing);
      // No technical detail reaches the user.
      expect(find.textContaining('409'), findsNothing);
      expect(find.textContaining('Exception'), findsNothing);
    });
  });

  group('FINALIZAR ASISTENCIA', () {
    testWidgets('is disabled while the close is in flight', (tester) async {
      withAcceptedRequest();
      await pumpConsole(tester);
      await startAssistance(tester);

      final gate = Completer<void>();
      remoteSessions.closeGate = gate.future;
      final button = find.byKey(const Key('close_remote_session_button'));
      await tester.tap(button);
      await tester.pump();

      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      // A second click cannot produce a second close.
      await tester.tap(button, warnIfMissed: false);
      await tester.pump();
      expect(remoteSessions.closedIds, [remoteSessionId]);

      gate.complete();
      await settleUi(tester);
    });

    testWidgets('ends the assistance and reloads the queue', (tester) async {
      withAcceptedRequest();
      await pumpConsole(tester);
      await startAssistance(tester);
      final queueLoadsBefore = supportRequests.loadCount;

      // The backend completes the request in the same transaction.
      supportRequests.requestsAfterFirstLoad = [
        buildSupportRequest(
          status: SupportRequestStatus.completed,
          technician: technicianId,
          closedAt: DateTime.utc(2026, 3, 11, 9, 51),
        ),
      ];
      await tester.tap(find.byKey(const Key('close_remote_session_button')));
      await settleUi(tester);

      expect(remoteSessions.closedIds, [remoteSessionId]);
      expect(find.byKey(const Key('active_assistance_section')), findsNothing);
      expect(supportRequests.loadCount, greaterThan(queueLoadsBefore));
      expect(find.text('HISTORIAL (1)'), findsOneWidget);
    });

    testWidgets('a network failure keeps the assistance and offers a retry', (
      tester,
    ) async {
      withAcceptedRequest();
      await pumpConsole(tester);
      await startAssistance(tester);

      remoteSessions.closeFailure = const NetworkFailure();
      await tester.tap(find.byKey(const Key('close_remote_session_button')));
      await settleUi(tester);

      expect(find.byKey(const Key('active_assistance_section')), findsOneWidget);
      expect(find.byKey(const Key('remote_session_retry_button')), findsOneWidget);
      expect(find.text('FINALIZAR ASISTENCIA'), findsOneWidget);
    });
  });

  group('recovery after a reload', () {
    testWidgets('a CONNECTING session comes back on its own', (tester) async {
      // Exactly what an F5 looks like: nothing in memory, a live session in the
      // backend.
      remoteSessions.current = buildRemoteSession();
      withAcceptedRequest();

      await pumpConsole(tester);

      expect(find.byKey(const Key('active_assistance_section')), findsOneWidget);
      expect(
        find.text('Estado: Conectando con el dispositivo...'),
        findsOneWidget,
      );
      expect(remoteSessions.currentCount, 1);
    });

    testWidgets('an ACTIVE session is shown as in progress', (tester) async {
      remoteSessions.current = buildRemoteSession(
        status: RemoteSessionStatus.active,
        connectedAt: DateTime.utc(2026, 3, 11, 9, 35, 12),
      );

      await pumpConsole(tester);

      expect(find.byKey(const Key('active_assistance_section')), findsOneWidget);
      expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
      expect(find.text('FINALIZAR ASISTENCIA'), findsOneWidget);
      // Recovered as ACTIVE: there was nothing to activate.
      expect(remoteSessions.activatedIds, isEmpty);
    });

    testWidgets('the session is joined once the socket is connected', (
      tester,
    ) async {
      remoteSessions.current = buildRemoteSession();
      await pumpConsole(tester);
      expect(
        find.text('Preparando el canal de asistencia...'),
        findsOneWidget,
      );

      await connectSocket(tester);

      expect(realtime.joinedSessionIds, [remoteSessionId]);
      expect(find.text('Canal de asistencia establecido.'), findsOneWidget);
    });
  });

  group('remote connection', () {
    /// The tablet is in the signaling room, so a negotiation starts as soon
    /// as the socket is up.
    Future<void> pumpWithReadyPeer(WidgetTester tester) async {
      remoteSessions.current = buildRemoteSession();
      realtime.peerJoinedOnJoin = true;
      await pumpConsole(tester);
      await connectSocket(tester);
      // The backend relayed the offer to the tablet.
      realtime.answerRelayAck({
        'delivered': true,
        'remoteSessionId': remoteSessionId,
      });
      await settleUi(tester);
    }

    testWidgets('says it is connecting while WebRTC negotiates', (
      tester,
    ) async {
      await pumpWithReadyPeer(tester);

      expect(peers.sessions, hasLength(1));
      expect(
        tester.widget<Text>(find.byKey(const Key('webrtc_status'))).data,
        'Conectando con el dispositivo...',
      );
    });

    testWidgets('reports the remote connection once the channel is open', (
      tester,
    ) async {
      // The confirmation never gets through, so the session stays where the
      // backend has it and only the WebRTC line moves.
      remoteSessions.activateFailure = const NetworkFailure();
      await pumpWithReadyPeer(tester);

      peers.last
        ..emitControlChannelState(WebRtcDataChannelState.open)
        ..emitPeerState(WebRtcPeerConnectionState.connected);
      await settleUi(tester);

      expect(
        tester.widget<Text>(find.byKey(const Key('webrtc_status'))).data,
        'Conexión remota establecida',
      );
      // The RemoteSession is never promoted locally: it is whatever the last
      // successful REST read said.
      expect(
        find.text('Estado: Conectando con el dispositivo...'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('remote_session_connected_at')), findsNothing);
    });

    testWidgets('an established connection turns the session ACTIVE', (
      tester,
    ) async {
      await pumpWithReadyPeer(tester);
      expect(
        find.text('Estado: Conectando con el dispositivo...'),
        findsOneWidget,
      );

      peers.last
        ..emitControlChannelState(WebRtcDataChannelState.open)
        ..emitPeerState(WebRtcPeerConnectionState.connected);
      await settleUi(tester);

      // No contradiction left on screen: the three lines agree.
      expect(remoteSessions.activatedIds, [remoteSessionId]);
      expect(find.text('ASISTENCIA REMOTA'), findsOneWidget);
      expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
      expect(
        find.text('Estado: Conectando con el dispositivo...'),
        findsNothing,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('webrtc_status'))).data,
        'Conexión remota establecida',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('webrtc_debug_status'))).data,
        'WebRTC: conectado · Canal de control: abierto',
      );
      expect(find.text('FINALIZAR ASISTENCIA'), findsOneWidget);
    });

    testWidgets('shows the connectedAt the backend stamped', (tester) async {
      await pumpWithReadyPeer(tester);

      peers.last
        ..emitControlChannelState(WebRtcDataChannelState.open)
        ..emitPeerState(WebRtcPeerConnectionState.connected);
      await settleUi(tester);

      final connectedAt = remoteSessions.current!.connectedAt!.toLocal();
      String two(int n) => n.toString().padLeft(2, '0');
      expect(
        tester
            .widget<Text>(find.byKey(const Key('remote_session_connected_at')))
            .data,
        'Conectado desde: ${two(connectedAt.hour)}:${two(connectedAt.minute)}',
      );
    });

    testWidgets('an activation that failed offers a retry that activates', (
      tester,
    ) async {
      remoteSessions.activateFailure = const NetworkFailure();
      await pumpWithReadyPeer(tester);
      peers.last
        ..emitControlChannelState(WebRtcDataChannelState.open)
        ..emitPeerState(WebRtcPeerConnectionState.connected);
      await settleUi(tester);

      expect(find.byKey(const Key('remote_session_error_banner')), findsOneWidget);
      expect(find.text('FINALIZAR ASISTENCIA'), findsOneWidget);
      expect(remoteSessions.activatedIds, hasLength(1));

      remoteSessions.activateFailure = null;
      await tester.tap(find.byKey(const Key('remote_session_retry_button')));
      await settleUi(tester);

      expect(remoteSessions.activatedIds, hasLength(2));
      expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
    });

    testWidgets('nothing is shown while the tablet has not joined', (
      tester,
    ) async {
      remoteSessions.current = buildRemoteSession();
      await pumpConsole(tester);
      await connectSocket(tester);

      expect(peers.sessions, isEmpty);
      expect(find.byKey(const Key('webrtc_status')), findsNothing);
    });
  });

  group('closed from the tablet', () {
    testWidgets('the assistance disappears after re-reading the backend', (
      tester,
    ) async {
      remoteSessions.current = buildRemoteSession();
      supportRequests.requests = [
        buildSupportRequest(
          status: SupportRequestStatus.accepted,
          technician: technicianId,
        ),
      ];
      await pumpConsole(tester);
      await connectSocket(tester);
      expect(find.byKey(const Key('active_assistance_section')), findsOneWidget);

      remoteSessions.current = null;
      supportRequests.requestsAfterFirstLoad = [
        buildSupportRequest(
          status: SupportRequestStatus.completed,
          technician: technicianId,
          closedAt: DateTime.utc(2026, 3, 11, 9, 51),
        ),
      ];
      realtime.emitRemoteSessionClosed(remoteSessionId);
      await settleUi(tester);

      expect(find.byKey(const Key('active_assistance_section')), findsNothing);
      expect(find.text('HISTORIAL (1)'), findsOneWidget);
    });
  });

  group('security', () {
    testWidgets('no token or transport detail is ever rendered', (tester) async {
      remoteSessions.current = buildRemoteSession();
      await pumpConsole(tester);
      await connectSocket(tester);

      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map(
            (widget) =>
                '${widget.data ?? ''}${widget.textSpan?.toPlainText() ?? ''}',
          )
          .join('\n');
      expect(texts, isNot(contains('tecnico-jwt')));
      expect(texts, isNot(contains('stored-user-jwt')));
      expect(texts, isNot(contains('Bearer')));
      expect(texts, isNot(contains('Socket')));
      expect(texts, isNot(contains('socket')));
      expect(texts, isNot(contains('remote-session:join')));
      expect(texts, isNot(contains('/technicians')));
    });
  });
}
