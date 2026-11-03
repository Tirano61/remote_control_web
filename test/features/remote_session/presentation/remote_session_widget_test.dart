import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/app/composition_root.dart';
import 'package:remote_control_web/app/remote_control_app.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/normalized_remote_point.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_ack.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_web/features/remote_session/data/repositories/remote_session_repository_impl.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_web/features/signaling/data/technician_signaling_client_impl.dart';
import 'package:remote_control_web/features/support/domain/entities/support_request_status.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_web/features/webrtc/presentation/widgets/remote_screen_view.dart';

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
  late FakeRemoteVideoRendererFactory renderers;

  setUp(() {
    auth = FakeAuthRemoteDataSource()..checkStatusResponse = technicianSession;
    storage = InMemoryUserTokenStorage()..token = 'stored-user-jwt';
    devices = FakeDeviceRepository();
    supportRequests = FakeSupportRequestRepository();
    remoteSessions = FakeRemoteSessionRepository();
    realtime = FakeTechnicianRealtimeClient();
    peers = FakeWebRtcPeerClient();
    renderers = FakeRemoteVideoRendererFactory();
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

  Future<void> pumpConsole(
    WidgetTester tester, {
    Size viewSize = const Size(1400, 1400),
  }) async {
    tester.view.physicalSize = viewSize;
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
          remoteVideoRendererFactory: renderers.create,
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
      expect(
        find.text('Estado: Usuario autorizó la asistencia'),
        findsOneWidget,
      );
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
      expect(
        find.byKey(const Key('active_assistance_section')),
        findsOneWidget,
      );
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
      expect(
        find.byKey(const Key('active_assistance_section')),
        findsOneWidget,
      );
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
      expect(
        find.byKey(const Key('active_assistance_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('remote_session_error_banner')),
        findsNothing,
      );
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

      expect(
        find.byKey(const Key('active_assistance_section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('remote_session_retry_button')),
        findsOneWidget,
      );
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

      expect(
        find.byKey(const Key('active_assistance_section')),
        findsOneWidget,
      );
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

      expect(
        find.byKey(const Key('active_assistance_section')),
        findsOneWidget,
      );
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
      expect(find.text('Preparando el canal de asistencia...'), findsOneWidget);

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
      expect(
        find.byKey(const Key('remote_session_connected_at')),
        findsNothing,
      );
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

      expect(
        find.byKey(const Key('remote_session_error_banner')),
        findsOneWidget,
      );
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

  group('remote screen', () {
    /// A CONNECTING session whose tablet is in the room: the negotiation
    /// starts and the offer is relayed.
    Future<void> pumpNegotiating(
      WidgetTester tester, {
      Size viewSize = const Size(1400, 1400),
    }) async {
      remoteSessions.current = buildRemoteSession();
      realtime.peerJoinedOnJoin = true;
      await pumpConsole(tester, viewSize: viewSize);
      await connectSocket(tester);
      realtime.answerRelayAck({
        'delivered': true,
        'remoteSessionId': remoteSessionId,
      });
      await settleUi(tester);
    }

    /// Peer connection connected and `control` open: the console activates
    /// the session and the backend answers ACTIVE.
    Future<void> establish(WidgetTester tester) async {
      peers.last
        ..emitControlChannelState(WebRtcDataChannelState.open)
        ..emitPeerState(WebRtcPeerConnectionState.connected);
      await settleUi(tester);
    }

    Finder video(String id) => find.byKey(Key('fake_remote_video_$id'));
    final waiting = find.text(kWaitingForRemoteScreenNotice);
    final surface = find.byKey(const Key('remote_screen_surface'));

    testWidgets(
      'an assistance without a picture is complete and waits for it',
      (tester) async {
        await pumpNegotiating(tester);
        await establish(tester);

        // Regression: video is not part of what makes the assistance work.
        expect(remoteSessions.activatedIds, [remoteSessionId]);
        expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
        expect(
          tester.widget<Text>(find.byKey(const Key('webrtc_status'))).data,
          'Conexión remota establecida',
        );
        expect(
          tester
              .widget<Text>(find.byKey(const Key('webrtc_debug_status')))
              .data,
          'WebRTC: conectado · Canal de control: abierto',
        );
        expect(find.text('FINALIZAR ASISTENCIA'), findsOneWidget);
        // MediaProjection may still be waiting for consent on the tablet: a
        // placeholder, never an error.
        expect(waiting, findsOneWidget);
        expect(find.byKey(const Key('remote_screen_video')), findsNothing);
        expect(renderers.created, hasLength(1));
        expect(renderers.last.attachedTracks, isEmpty);
      },
    );

    testWidgets('the tablet screen replaces the placeholder', (tester) async {
      await pumpNegotiating(tester);
      await establish(tester);

      final track = peers.last.emitRemoteVideoTrack('screen-0');
      await settleUi(tester);
      renderers.last.reportVideoAspectRatio(1280 / 800);
      await settleUi(tester);

      expect(renderers.last.attachedTracks, [same(track)]);
      expect(video('screen-0'), findsOneWidget);
      expect(waiting, findsNothing);
      // The diagnostics stay around the picture.
      expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
      expect(find.byKey(const Key('webrtc_status')), findsOneWidget);
      expect(find.text('FINALIZAR ASISTENCIA'), findsOneWidget);
    });

    testWidgets('CONNECTING -> ACTIVE keeps the renderer and the picture', (
      tester,
    ) async {
      await pumpNegotiating(tester);
      // `ontrack` fires when the answer is applied, before ICE completes and
      // well before the backend says ACTIVE.
      final track = peers.last.emitRemoteVideoTrack('screen-0');
      await settleUi(tester);
      expect(
        find.text('Estado: Conectando con el dispositivo...'),
        findsOneWidget,
      );
      expect(video('screen-0'), findsOneWidget);
      final renderer = renderers.last;

      await establish(tester);

      expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
      expect(renderers.created, [same(renderer)]);
      expect(renderer.disposeCount, 0);
      expect(renderer.detachCount, 0);
      expect(renderer.attachedTracks, [same(track)]);
      expect(video('screen-0'), findsOneWidget);
    });

    testWidgets('a new track of the session moves to the same renderer', (
      tester,
    ) async {
      await pumpNegotiating(tester);
      await establish(tester);
      final a = peers.last.emitRemoteVideoTrack('screen-a');
      await settleUi(tester);

      final b = peers.last.emitRemoteVideoTrack('screen-b');
      await settleUi(tester);

      expect(renderers.created, hasLength(1));
      expect(renderers.last.attachedTracks, [same(a), same(b)]);
      expect(video('screen-b'), findsOneWidget);
      expect(video('screen-a'), findsNothing);
    });

    testWidgets('FINALIZAR ASISTENCIA releases the picture', (tester) async {
      await pumpNegotiating(tester);
      await establish(tester);
      peers.last.emitRemoteVideoTrack('screen-0');
      await settleUi(tester);

      await tester.tap(find.byKey(const Key('close_remote_session_button')));
      await settleUi(tester);

      expect(surface, findsNothing);
      expect(renderers.created, hasLength(1));
      expect(renderers.last.disposeCount, 1);
      expect(renderers.last.isDisplaying, isFalse);
    });

    testWidgets('a session closed from the tablet releases the picture', (
      tester,
    ) async {
      await pumpNegotiating(tester);
      await establish(tester);
      peers.last.emitRemoteVideoTrack('screen-0');
      await settleUi(tester);

      remoteSessions.current = null;
      realtime.emitRemoteSessionClosed(remoteSessionId);
      await settleUi(tester);

      expect(find.byKey(const Key('active_assistance_section')), findsNothing);
      expect(renderers.last.disposeCount, 1);
    });

    testWidgets('a failed peer connection takes the picture away', (
      tester,
    ) async {
      await pumpNegotiating(tester);
      await establish(tester);
      peers.last.emitRemoteVideoTrack('screen-0');
      await settleUi(tester);

      peers.last.emitPeerState(WebRtcPeerConnectionState.failed);
      await settleUi(tester);

      expect(surface, findsNothing);
      expect(renderers.last.disposeCount, 1);
      // The assistance itself is still the backend's to end.
      expect(find.text('FINALIZAR ASISTENCIA'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('webrtc_status'))).data,
        'No se pudo establecer la conexión remota.',
      );
    });

    testWidgets('signing out releases the picture', (tester) async {
      await pumpNegotiating(tester);
      await establish(tester);
      peers.last.emitRemoteVideoTrack('screen-0');
      await settleUi(tester);

      await tester.tap(find.byKey(const Key('logout_button')));
      await settleUi(tester);

      expect(surface, findsNothing);
      expect(renderers.last.disposeCount, 1);
    });

    for (final viewSize in const [
      Size(1280, 720),
      Size(1024, 768),
      Size(800, 600),
      Size(420, 800),
    ]) {
      testWidgets('fits ${viewSize.width.toInt()}x${viewSize.height.toInt()} '
          'without overflow', (tester) async {
        await pumpNegotiating(tester, viewSize: viewSize);
        await establish(tester);
        peers.last.emitRemoteVideoTrack('screen-0');
        await settleUi(tester);

        for (final aspectRatio in const [1280 / 800, 800 / 1280]) {
          renderers.last.reportVideoAspectRatio(aspectRatio);
          await settleUi(tester);

          expect(tester.takeException(), isNull);
          final size = tester.getSize(surface);
          expect(size.width, lessThanOrEqualTo(viewSize.width));
          expect(size.height, lessThanOrEqualTo(viewSize.height));
          // Never stretched: the box has the picture's own proportions.
          expect(size.width / size.height, closeTo(aspectRatio, 0.01));
        }
        expect(find.text('FINALIZAR ASISTENCIA'), findsOneWidget);
      });
    }
  });

  group('remote control', () {
    final surface = find.byKey(const Key('remote_screen_surface'));
    final gestureLayer = find.byKey(const Key('remote_screen_gesture_layer'));

    String statusLine(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const Key('remote_control_status')))
        .data!;

    /// An ACTIVE assistance with the picture of the tablet on screen.
    Future<void> pumpAssistance(WidgetTester tester) async {
      remoteSessions.current = buildRemoteSession();
      realtime.peerJoinedOnJoin = true;
      await pumpConsole(tester);
      await connectSocket(tester);
      realtime.answerRelayAck({
        'delivered': true,
        'remoteSessionId': remoteSessionId,
      });
      await settleUi(tester);
      peers.last
        ..emitControlChannelState(WebRtcDataChannelState.open)
        ..emitPeerState(WebRtcPeerConnectionState.connected)
        ..emitRemoteVideoTrack('screen-0');
      await settleUi(tester);
      renderers.last.reportVideoAspectRatio(1280 / 800);
      await settleUi(tester);
    }

    Future<void> clickCentre(WidgetTester tester) async {
      await tester.tapAt(tester.getCenter(surface));
      await settleUi(tester);
    }

    /// From three quarters of the way down the surface to a quarter, in 350 ms.
    Future<void> dragUpwards(WidgetTester tester) async {
      final box = tester.getRect(surface);
      final gesture = await tester.createGesture();
      await gesture.down(
        Offset(box.center.dx, box.top + box.height * 0.75),
        timeStamp: const Duration(seconds: 10),
      );
      await gesture.moveTo(
        Offset(box.center.dx, box.top + box.height * 0.25),
        timeStamp: const Duration(seconds: 10, milliseconds: 200),
      );
      await gesture.up(
        timeStamp: const Duration(seconds: 10, milliseconds: 350),
      );
      await settleUi(tester);
    }

    testWidgets('a click reaches the tablet, and its answer comes back', (
      tester,
    ) async {
      await pumpAssistance(tester);
      expect(statusLine(tester), 'Control remoto: listo');

      await clickCentre(tester);

      final command =
          peers.last.sentRemoteControlCommands.single as RemoteTapCommand;
      expect(command.point, const NormalizedRemotePoint(0.5, 0.5));
      expect(statusLine(tester), 'Enviando toque...');

      peers.last.emitRemoteControlAck(command.id);
      await settleUi(tester);

      expect(statusLine(tester), 'Toque enviado');
    });

    const refusals = {
      RemoteControlError.accessibilityUnavailable:
          'El dispositivo no tiene habilitado el control remoto.',
      RemoteControlError.gestureRejected: 'No se pudo ejecutar el toque.',
      RemoteControlError.invalidCommand: 'Control remoto no disponible',
      RemoteControlError.unsupportedCommand: 'Control remoto no disponible',
    };

    refusals.forEach((error, message) {
      testWidgets('${error.code} is explained and ends nothing', (
        tester,
      ) async {
        await pumpAssistance(tester);

        await clickCentre(tester);
        peers.last.emitRemoteControlAck('tap-1', error: error);
        await settleUi(tester);

        expect(statusLine(tester), message);
        expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
        expect(
          find.byKey(const Key('fake_remote_video_screen-0')),
          findsOneWidget,
        );
        expect(peers.last.isClosed, isFalse);
        expect(remoteSessions.closedIds, isEmpty);
        expect(gestureLayer, findsOneWidget);
      });
    });

    testWidgets('session_not_active asks REST, once, and sends nothing', (
      tester,
    ) async {
      await pumpAssistance(tester);
      final readsBefore = remoteSessions.currentCount;

      await clickCentre(tester);
      peers.last.emitRemoteControlAck(
        'tap-1',
        error: RemoteControlError.sessionNotActive,
      );
      await settleUi(tester);

      expect(remoteSessions.currentCount, readsBefore + 1);
      expect(peers.last.sentRemoteControlCommands, hasLength(1));
      expect(peers.last.isClosed, isFalse);
      expect(
        statusLine(tester),
        'La asistencia no está activa en el dispositivo.',
      );

      // Later states still carry that tap: they do not read REST again.
      peers.last.emitPeerState(WebRtcPeerConnectionState.disconnected);
      await settleUi(tester);
      expect(remoteSessions.currentCount, readsBefore + 1);
    });

    testWidgets('session_not_active that REST confirms ends the assistance', (
      tester,
    ) async {
      await pumpAssistance(tester);

      await clickCentre(tester);
      remoteSessions.current = null;
      peers.last.emitRemoteControlAck(
        'tap-1',
        error: RemoteControlError.sessionNotActive,
      );
      await settleUi(tester);

      expect(find.byKey(const Key('active_assistance_section')), findsNothing);
      expect(surface, findsNothing);
      expect(renderers.last.disposeCount, 1);
    });

    testWidgets('nothing can be clicked while the session is CONNECTING', (
      tester,
    ) async {
      remoteSessions.activateFailure = const NetworkFailure();
      await pumpAssistance(tester);
      expect(
        find.text('Estado: Conectando con el dispositivo...'),
        findsOneWidget,
      );
      expect(statusLine(tester), 'Control remoto: no disponible');
      expect(gestureLayer, findsNothing);

      await clickCentre(tester);

      expect(peers.last.sentRemoteControlCommands, isEmpty);
    });

    testWidgets('nothing can be clicked before the first frame', (
      tester,
    ) async {
      remoteSessions.current = buildRemoteSession();
      realtime.peerJoinedOnJoin = true;
      await pumpConsole(tester);
      await connectSocket(tester);
      realtime.answerRelayAck({
        'delivered': true,
        'remoteSessionId': remoteSessionId,
      });
      await settleUi(tester);
      peers.last
        ..emitControlChannelState(WebRtcDataChannelState.open)
        ..emitPeerState(WebRtcPeerConnectionState.connected)
        ..emitRemoteVideoTrack('screen-0');
      await settleUi(tester);

      // ACTIVE, with a track and a channel: the tablet is still asking the user
      // for MediaProjection consent, so there is nothing to aim at.
      expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
      expect(find.text(kWaitingForRemoteScreenNotice), findsOneWidget);
      expect(statusLine(tester), 'Control remoto: no disponible');

      await clickCentre(tester);

      expect(peers.last.sentRemoteControlCommands, isEmpty);
    });

    testWidgets('the controls of the console are not part of the picture', (
      tester,
    ) async {
      await pumpAssistance(tester);

      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('remote_control_status'))),
      );
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('webrtc_status'))),
      );
      await settleUi(tester);

      expect(peers.last.sentRemoteControlCommands, isEmpty);
    });

    testWidgets('pressing FINALIZAR stops the clicks at once', (tester) async {
      await pumpAssistance(tester);
      final gate = Completer<void>();
      remoteSessions.closeGate = gate.future;
      await clickCentre(tester);
      expect(peers.last.sentRemoteControlCommands, hasLength(1));

      await tester.tap(find.byKey(const Key('close_remote_session_button')));
      await settleUi(tester);

      // The backend has not answered and the picture is still there, but the
      // technician asked to stop.
      expect(surface, findsOneWidget);
      expect(gestureLayer, findsNothing);
      expect(statusLine(tester), 'Control remoto: no disponible');
      await clickCentre(tester);
      expect(peers.last.sentRemoteControlCommands, hasLength(1));

      gate.complete();
      await settleUi(tester);

      expect(surface, findsNothing);
      expect(peers.last.sentRemoteControlCommands, hasLength(1));
    });

    testWidgets('a close that failed gives the control back', (tester) async {
      await pumpAssistance(tester);
      remoteSessions.closeFailure = const NetworkFailure();

      await tester.tap(find.byKey(const Key('close_remote_session_button')));
      await settleUi(tester);

      // The assistance goes on, so does the control.
      expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
      expect(statusLine(tester), 'Control remoto: listo');

      await clickCentre(tester);

      expect(peers.last.sentRemoteControlCommands, hasLength(1));
    });

    testWidgets('signing out with a tap in flight leaves nothing behind', (
      tester,
    ) async {
      await pumpAssistance(tester);
      final session = peers.last;
      await clickCentre(tester);

      await tester.tap(find.byKey(const Key('logout_button')));
      await settleUi(tester);

      expect(surface, findsNothing);
      expect(renderers.last.disposeCount, 1);
      expect(session.sentRemoteControlCommands, hasLength(1));
    });

    testWidgets('a drag reaches the tablet, and its answer comes back', (
      tester,
    ) async {
      await pumpAssistance(tester);

      await dragUpwards(tester);

      final session = peers.last;
      final command =
          session.sentRemoteControlCommands.single as RemoteSwipeCommand;
      expect(command.start, const NormalizedRemotePoint(0.5, 0.75));
      expect(command.end, const NormalizedRemotePoint(0.5, 0.25));
      expect(command.durationMs, 350);
      expect(statusLine(tester), 'Enviando desplazamiento...');

      session.emitRemoteControlAck(command.id);
      await settleUi(tester);

      expect(statusLine(tester), 'Desplazamiento enviado');
    });

    const swipeRefusals = {
      RemoteControlError.accessibilityUnavailable:
          'El dispositivo no tiene habilitado el control remoto.',
      RemoteControlError.gestureRejected:
          'No se pudo ejecutar el desplazamiento.',
      RemoteControlError.invalidCommand: 'Control remoto no disponible',
    };

    swipeRefusals.forEach((error, message) {
      testWidgets('a swipe refused with ${error.code} ends nothing', (
        tester,
      ) async {
        await pumpAssistance(tester);

        await dragUpwards(tester);
        peers.last.emitRemoteControlAck('swipe-1', error: error);
        await settleUi(tester);

        expect(statusLine(tester), message);
        expect(peers.last.sentRemoteControlCommands, hasLength(1));
        expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
        expect(
          find.byKey(const Key('fake_remote_video_screen-0')),
          findsOneWidget,
        );
        expect(peers.last.isClosed, isFalse);
        expect(gestureLayer, findsOneWidget);
      });
    });

    testWidgets('a swipe answered session_not_active asks REST, once', (
      tester,
    ) async {
      await pumpAssistance(tester);
      final readsBefore = remoteSessions.currentCount;

      await dragUpwards(tester);
      peers.last.emitRemoteControlAck(
        'swipe-1',
        error: RemoteControlError.sessionNotActive,
      );
      await settleUi(tester);

      expect(remoteSessions.currentCount, readsBefore + 1);
      expect(peers.last.sentRemoteControlCommands, hasLength(1));
      expect(peers.last.isClosed, isFalse);
    });

    testWidgets('a swipe nobody answers is reported, not sent again', (
      tester,
    ) async {
      await pumpAssistance(tester);

      await dragUpwards(tester);
      expect(statusLine(tester), 'Enviando desplazamiento...');

      // Its deadline: 350 ms of work and the three second margin.
      await tester.pump(const Duration(seconds: 4));
      await settleUi(tester);

      expect(
        statusLine(tester),
        'El dispositivo no confirmó el desplazamiento.',
      );
      expect(peers.last.sentRemoteControlCommands, hasLength(1));
    });

    testWidgets('a tap and a swipe each say what they are', (tester) async {
      await pumpAssistance(tester);

      await clickCentre(tester);
      expect(statusLine(tester), 'Enviando toque...');

      await dragUpwards(tester);
      expect(statusLine(tester), 'Enviando desplazamiento...');

      peers.last.emitRemoteControlAck('swipe-2');
      await settleUi(tester);
      expect(statusLine(tester), 'Desplazamiento enviado');

      await clickCentre(tester);
      peers.last.emitRemoteControlAck('tap-3');
      await settleUi(tester);
      expect(statusLine(tester), 'Toque enviado');
    });

    testWidgets('a drag is not a click, on its way or at its end', (
      tester,
    ) async {
      await pumpAssistance(tester);

      await dragUpwards(tester);

      final commands = peers.last.sentRemoteControlCommands;
      expect(commands, hasLength(1));
      expect(commands.single, isA<RemoteSwipeCommand>());
    });

    testWidgets('nothing can be dragged while the session is CONNECTING', (
      tester,
    ) async {
      remoteSessions.activateFailure = const NetworkFailure();
      await pumpAssistance(tester);
      expect(gestureLayer, findsNothing);

      await dragUpwards(tester);

      expect(peers.last.sentRemoteControlCommands, isEmpty);
    });

    testWidgets('nothing can be dragged before the first frame', (
      tester,
    ) async {
      remoteSessions.current = buildRemoteSession();
      realtime.peerJoinedOnJoin = true;
      await pumpConsole(tester);
      await connectSocket(tester);
      realtime.answerRelayAck({
        'delivered': true,
        'remoteSessionId': remoteSessionId,
      });
      await settleUi(tester);
      peers.last
        ..emitControlChannelState(WebRtcDataChannelState.open)
        ..emitPeerState(WebRtcPeerConnectionState.connected)
        ..emitRemoteVideoTrack('screen-0');
      await settleUi(tester);
      expect(find.text(kWaitingForRemoteScreenNotice), findsOneWidget);

      await dragUpwards(tester);

      expect(peers.last.sentRemoteControlCommands, isEmpty);
    });

    testWidgets('pressing FINALIZAR cancels the drag under way', (
      tester,
    ) async {
      await pumpAssistance(tester);
      final gate = Completer<void>();
      remoteSessions.closeGate = gate.future;
      final box = tester.getRect(surface);

      final drag = await tester.startGesture(box.center);
      await drag.moveBy(const Offset(0, -40));
      await tester.pump();

      await tester.tap(find.byKey(const Key('close_remote_session_button')));
      await settleUi(tester);
      expect(surface, findsOneWidget);
      expect(gestureLayer, findsNothing);

      await drag.moveBy(const Offset(0, -40));
      await drag.up();
      await settleUi(tester);

      expect(peers.last.sentRemoteControlCommands, isEmpty);

      gate.complete();
      await settleUi(tester);
      expect(surface, findsNothing);
      expect(peers.last.sentRemoteControlCommands, isEmpty);
    });

    testWidgets('pressing FINALIZAR forgets a swipe waiting for its answer', (
      tester,
    ) async {
      await pumpAssistance(tester);
      final session = peers.last;
      final gate = Completer<void>();
      remoteSessions.closeGate = gate.future;
      await dragUpwards(tester);
      expect(statusLine(tester), 'Enviando desplazamiento...');

      await tester.tap(find.byKey(const Key('close_remote_session_button')));
      await settleUi(tester);

      expect(statusLine(tester), 'Control remoto: no disponible');

      // An answer that arrives now has nothing left to speak about.
      session.emitRemoteControlAck('swipe-1');
      await settleUi(tester);
      expect(statusLine(tester), 'Control remoto: no disponible');

      gate.complete();
      await settleUi(tester);
      expect(session.sentRemoteControlCommands, hasLength(1));
    });

    testWidgets('a rotation keeps the swipes working', (tester) async {
      await pumpAssistance(tester);

      await dragUpwards(tester);
      renderers.last.reportVideoAspectRatio(800 / 1280);
      await settleUi(tester);
      await dragUpwards(tester);
      renderers.last.reportVideoAspectRatio(1280 / 800);
      await settleUi(tester);
      await dragUpwards(tester);

      final commands = peers.last.sentRemoteControlCommands;
      expect(commands.map((c) => c.id), ['swipe-1', 'swipe-2', 'swipe-3']);
      for (final command in commands) {
        expect(
          (command as RemoteSwipeCommand).start,
          const NormalizedRemotePoint(0.5, 0.75),
        );
        expect(command.end, const NormalizedRemotePoint(0.5, 0.25));
      }
      expect(renderers.created, hasLength(1));
    });

    testWidgets('a rotation keeps the control working', (tester) async {
      await pumpAssistance(tester);

      await clickCentre(tester);
      renderers.last.reportVideoAspectRatio(800 / 1280);
      await settleUi(tester);
      await clickCentre(tester);
      renderers.last.reportVideoAspectRatio(1280 / 800);
      await settleUi(tester);
      await clickCentre(tester);

      final commands = peers.last.sentRemoteControlCommands;
      expect(commands.map((c) => c.id), ['tap-1', 'tap-2', 'tap-3']);
      for (final command in commands) {
        expect((command as RemoteTapCommand).point.x, closeTo(0.5, 1e-9));
        expect(command.point.y, closeTo(0.5, 1e-9));
      }
      expect(renderers.created, hasLength(1));
    });

    group('Back and Home', () {
      final backButton = find.byKey(const Key('remote_back_button'));
      final homeButton = find.byKey(const Key('remote_home_button'));
      final navigationStatus = find.byKey(
        const Key('remote_navigation_status'),
      );

      bool isEnabled(WidgetTester tester, Finder button) =>
          tester.widget<OutlinedButton>(button).onPressed != null;

      String navigationLine(WidgetTester tester) =>
          tester.widget<Text>(navigationStatus).data!;

      List<RemoteControlCommand> sent() => peers.last.sentRemoteControlCommands;

      Future<void> press(WidgetTester tester, Finder button) async {
        await tester.tap(button);
        await tester.pump();
        await tester.pump();
      }

      /// ACTIVE, connected and `control` open, with no track at all.
      Future<void> pumpWithoutVideo(WidgetTester tester) async {
        remoteSessions.current = buildRemoteSession();
        realtime.peerJoinedOnJoin = true;
        await pumpConsole(tester);
        await connectSocket(tester);
        realtime.answerRelayAck({
          'delivered': true,
          'remoteSessionId': remoteSessionId,
        });
        await settleUi(tester);
        peers.last
          ..emitControlChannelState(WebRtcDataChannelState.open)
          ..emitPeerState(WebRtcPeerConnectionState.connected);
        await settleUi(tester);
      }

      /// Past what is left of the guard, once the answer has arrived.
      Future<void> outliveGuard(WidgetTester tester) =>
          tester.pump(remoteNavigationSettleDuration);

      testWidgets('both are there, by name, and enabled', (tester) async {
        await pumpAssistance(tester);

        expect(find.text('Atrás'), findsOneWidget);
        expect(find.text('Inicio'), findsOneWidget);
        expect(isEnabled(tester, backButton), isTrue);
        expect(isEnabled(tester, homeButton), isTrue);
        expect(navigationStatus, findsNothing);
      });

      testWidgets('ACTIVE and control open without video: enabled', (
        tester,
      ) async {
        await pumpWithoutVideo(tester);

        expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
        expect(find.text(kWaitingForRemoteScreenNotice), findsOneWidget);
        expect(statusLine(tester), 'Control remoto: no disponible');
        expect(gestureLayer, findsNothing);
        expect(isEnabled(tester, backButton), isTrue);
        expect(isEnabled(tester, homeButton), isTrue);

        await press(tester, homeButton);
        expect(sent(), const [RemoteHomeCommand(id: 'home-1')]);
        expect(navigationLine(tester), 'Enviando Inicio...');

        peers.last.emitRemoteControlAck('home-1');
        await tester.pump();
        expect(navigationLine(tester), 'Inicio enviado');
        // The line about gestures is still right: there is nothing to aim at.
        expect(statusLine(tester), 'Control remoto: no disponible');
      });

      testWidgets('disabled while the session is CONNECTING', (tester) async {
        remoteSessions.activateFailure = const NetworkFailure();
        await pumpAssistance(tester);
        expect(
          find.text('Estado: Conectando con el dispositivo...'),
          findsOneWidget,
        );

        expect(isEnabled(tester, backButton), isFalse);
        expect(isEnabled(tester, homeButton), isFalse);
        await tester.tap(backButton, warnIfMissed: false);
        await settleUi(tester);

        expect(sent(), isEmpty);
      });

      testWidgets('disabled before the peers are connected', (tester) async {
        remoteSessions.current = buildRemoteSession();
        await pumpConsole(tester);

        expect(backButton, findsOneWidget);
        expect(isEnabled(tester, backButton), isFalse);
        expect(isEnabled(tester, homeButton), isFalse);
      });

      testWidgets('disabled with the control channel closed', (tester) async {
        await pumpAssistance(tester);

        peers.last.emitControlChannelState(WebRtcDataChannelState.closed);
        await settleUi(tester);

        expect(isEnabled(tester, backButton), isFalse);
        expect(isEnabled(tester, homeButton), isFalse);
      });

      testWidgets('there is no assistance without a session', (tester) async {
        await pumpConsole(tester);

        expect(backButton, findsNothing);
        expect(homeButton, findsNothing);
      });

      testWidgets('Back: its frame, its answer, its words', (tester) async {
        await pumpAssistance(tester);

        await press(tester, backButton);
        expect(sent(), const [RemoteBackCommand(id: 'back-1')]);
        expect(navigationLine(tester), 'Enviando Atrás...');

        peers.last.emitRemoteControlAck('back-1');
        await tester.pump();
        expect(navigationLine(tester), 'Atrás enviado');
      });

      testWidgets('Home: its frame, its answer, its words', (tester) async {
        await pumpAssistance(tester);

        await press(tester, homeButton);
        expect(sent(), const [RemoteHomeCommand(id: 'home-1')]);
        expect(navigationLine(tester), 'Enviando Inicio...');

        peers.last.emitRemoteControlAck('home-1');
        await tester.pump();
        expect(navigationLine(tester), 'Inicio enviado');
      });

      testWidgets('the line under the picture keeps talking about gestures', (
        tester,
      ) async {
        await pumpAssistance(tester);

        await press(tester, homeButton);
        expect(statusLine(tester), 'Control remoto: listo');

        peers.last.emitRemoteControlAck(
          'home-1',
          error: RemoteControlError.gestureRejected,
        );
        await tester.pump();
        expect(statusLine(tester), 'Control remoto: listo');

        await clickCentre(tester);
        expect(statusLine(tester), 'Enviando toque...');
        expect(navigationStatus, findsNothing);
      });

      const refusals = {
        RemoteControlError.accessibilityUnavailable:
            'El dispositivo no tiene habilitado el control remoto.',
        RemoteControlError.gestureRejected: 'No se pudo ejecutar la acción.',
        RemoteControlError.invalidCommand: 'Control remoto no disponible',
        RemoteControlError.unsupportedCommand: 'Control remoto no disponible',
      };

      refusals.forEach((error, message) {
        testWidgets(
          '${error.code} is explained, ends nothing, frees the rest',
          (tester) async {
            await pumpAssistance(tester);

            await press(tester, homeButton);
            peers.last.emitRemoteControlAck('home-1', error: error);
            await tester.pump();
            await tester.pump();

            expect(navigationLine(tester), message);
            expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
            expect(
              find.byKey(const Key('fake_remote_video_screen-0')),
              findsOneWidget,
            );
            expect(peers.last.isClosed, isFalse);
            expect(remoteSessions.closedIds, isEmpty);
            expect(sent(), hasLength(1));
            expect(isEnabled(tester, backButton), isTrue);
            expect(gestureLayer, findsOneWidget);
          },
        );
      });

      testWidgets('session_not_active asks REST, once, and sends nothing', (
        tester,
      ) async {
        await pumpAssistance(tester);
        final readsBefore = remoteSessions.currentCount;

        await press(tester, backButton);
        peers.last.emitRemoteControlAck(
          'back-1',
          error: RemoteControlError.sessionNotActive,
        );
        await settleUi(tester);

        expect(remoteSessions.currentCount, readsBefore + 1);
        expect(sent(), hasLength(1));
        expect(peers.last.isClosed, isFalse);
        expect(
          navigationLine(tester),
          'La asistencia no está activa en el dispositivo.',
        );
      });

      testWidgets('no answer in time says the action was not confirmed', (
        tester,
      ) async {
        await pumpAssistance(tester);

        await press(tester, backButton);
        await tester.pump(const Duration(milliseconds: 3050));
        await tester.pump();

        expect(navigationLine(tester), 'El dispositivo no confirmó la acción.');
        expect(isEnabled(tester, backButton), isTrue);
        expect(sent(), hasLength(1));
      });

      testWidgets('a double click is one action', (tester) async {
        await pumpAssistance(tester);

        await press(tester, backButton);
        expect(isEnabled(tester, backButton), isFalse);
        expect(isEnabled(tester, homeButton), isFalse);
        await tester.tap(backButton, warnIfMissed: false);
        await tester.pump();

        expect(sent(), const [RemoteBackCommand(id: 'back-1')]);

        peers.last.emitRemoteControlAck('back-1');
        await outliveGuard(tester);
        await tester.pump();
        expect(isEnabled(tester, backButton), isTrue);
      });

      testWidgets('a click during the guard is nothing, and works afterwards', (
        tester,
      ) async {
        await pumpAssistance(tester);

        await press(tester, homeButton);
        peers.last.emitRemoteControlAck('home-1');
        await tester.pump(const Duration(milliseconds: 50));
        expect(navigationLine(tester), 'Inicio enviado');

        expect(gestureLayer, findsNothing);
        await tester.tapAt(tester.getCenter(surface));
        await tester.pump(const Duration(milliseconds: 150));
        expect(sent(), hasLength(1));

        await tester.pump(remoteNavigationSettleDuration);
        await tester.pump();
        expect(gestureLayer, findsOneWidget);
        expect(isEnabled(tester, homeButton), isTrue);

        await clickCentre(tester);
        expect(sent(), hasLength(2));
        expect(sent().last, isA<RemoteTapCommand>());
      });

      testWidgets('a drag during the guard is nothing, and works afterwards', (
        tester,
      ) async {
        await pumpAssistance(tester);

        await press(tester, backButton);
        peers.last.emitRemoteControlAck('back-1');
        await tester.pump();

        await dragUpwards(tester);
        expect(sent(), hasLength(1));

        await outliveGuard(tester);
        await tester.pump();
        await dragUpwards(tester);
        expect(sent(), hasLength(2));
        expect(sent().last, isA<RemoteSwipeCommand>());
      });

      testWidgets('a press that starts in the guard is not picked up', (
        tester,
      ) async {
        await pumpAssistance(tester);
        await press(tester, homeButton);
        peers.last.emitRemoteControlAck('home-1');
        await tester.pump();

        final gesture = await tester.createGesture();
        await gesture.down(tester.getCenter(surface));
        await tester.pump(remoteNavigationSettleDuration);
        await tester.pump();
        expect(gestureLayer, findsOneWidget);
        await gesture.up();
        await settleUi(tester);

        expect(sent(), hasLength(1));
      });

      testWidgets('the guard leaves the picture and its renderer alone', (
        tester,
      ) async {
        await pumpAssistance(tester);

        await press(tester, homeButton);
        peers.last.emitRemoteControlAck('home-1');
        await tester.pump();

        expect(
          find.byKey(const Key('fake_remote_video_screen-0')),
          findsOneWidget,
        );
        await outliveGuard(tester);
        await tester.pump();

        expect(renderers.created, hasLength(1));
        expect(renderers.last.disposeCount, 0);
        expect(renderers.last.detachCount, 0);
        expect(peers.last.isClosed, isFalse);
      });

      testWidgets('the buttons are not part of the picture', (tester) async {
        await pumpAssistance(tester);
        final picture = tester.getRect(surface);

        expect(tester.getRect(backButton).top, greaterThan(picture.bottom));
        expect(tester.getRect(homeButton).top, greaterThan(picture.bottom));

        await press(tester, backButton);

        expect(sent().whereType<RemoteTapCommand>(), isEmpty);
        expect(sent().whereType<RemoteSwipeCommand>(), isEmpty);
      });

      testWidgets('FINALIZAR is not held by the guard, and clears it', (
        tester,
      ) async {
        await pumpAssistance(tester);
        final session = peers.last;
        final gate = Completer<void>();
        remoteSessions.closeGate = gate.future;

        await press(tester, backButton);
        expect(navigationLine(tester), 'Enviando Atrás...');

        await tester.tap(find.byKey(const Key('close_remote_session_button')));
        await tester.pump();
        await tester.pump();
        await tester.pump();

        expect(remoteSessions.closedIds, hasLength(1));
        expect(navigationStatus, findsNothing);
        expect(isEnabled(tester, backButton), isFalse);
        expect(isEnabled(tester, homeButton), isFalse);

        // An answer that arrives now has nothing left to speak about.
        session.emitRemoteControlAck('back-1');
        await settleUi(tester);
        expect(navigationStatus, findsNothing);
        expect(session.sentRemoteControlCommands, hasLength(1));

        gate.complete();
        await settleUi(tester);

        expect(backButton, findsNothing);
        expect(homeButton, findsNothing);
        expect(session.sentRemoteControlCommands, hasLength(1));
      });

      testWidgets('a close that failed gives Back and Home back', (
        tester,
      ) async {
        await pumpAssistance(tester);
        remoteSessions.closeFailure = const NetworkFailure();

        await press(tester, homeButton);
        await tester.tap(find.byKey(const Key('close_remote_session_button')));
        await settleUi(tester);

        expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
        expect(isEnabled(tester, backButton), isTrue);
        expect(isEnabled(tester, homeButton), isTrue);
      });

      group('Recents', () {
        final recentsButton = find.byKey(const Key('remote_recents_button'));

        testWidgets('it is there, by name, and enabled', (tester) async {
          await pumpAssistance(tester);

          expect(find.text('Recientes'), findsOneWidget);
          expect(isEnabled(tester, recentsButton), isTrue);
          expect(navigationStatus, findsNothing);
        });

        testWidgets('its frame, its answer, its words', (tester) async {
          await pumpAssistance(tester);

          await press(tester, recentsButton);
          expect(sent(), const [RemoteRecentsCommand(id: 'recents-1')]);
          expect(navigationLine(tester), 'Enviando Recientes...');

          peers.last.emitRemoteControlAck('recents-1');
          await tester.pump();
          expect(navigationLine(tester), 'Recientes enviado');
          expect(sent().whereType<RemoteTapCommand>(), isEmpty);
        });

        testWidgets('without video, all three work and gestures do not', (
          tester,
        ) async {
          await pumpWithoutVideo(tester);

          expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
          expect(statusLine(tester), 'Control remoto: no disponible');
          expect(gestureLayer, findsNothing);
          expect(isEnabled(tester, backButton), isTrue);
          expect(isEnabled(tester, homeButton), isTrue);
          expect(isEnabled(tester, recentsButton), isTrue);

          await tester.tapAt(tester.getCenter(surface));
          await settleUi(tester);
          expect(sent(), isEmpty);

          await press(tester, recentsButton);
          expect(sent(), const [RemoteRecentsCommand(id: 'recents-1')]);
          expect(navigationLine(tester), 'Enviando Recientes...');

          peers.last.emitRemoteControlAck('recents-1');
          await tester.pump();
          expect(navigationLine(tester), 'Recientes enviado');
          expect(statusLine(tester), 'Control remoto: no disponible');
        });

        testWidgets('disabled while the session is CONNECTING', (tester) async {
          remoteSessions.activateFailure = const NetworkFailure();
          await pumpAssistance(tester);

          expect(isEnabled(tester, recentsButton), isFalse);
          await tester.tap(recentsButton, warnIfMissed: false);
          await settleUi(tester);

          expect(sent(), isEmpty);
        });

        testWidgets('disabled before the peers are connected', (tester) async {
          remoteSessions.current = buildRemoteSession();
          await pumpConsole(tester);

          expect(recentsButton, findsOneWidget);
          expect(isEnabled(tester, recentsButton), isFalse);
        });

        testWidgets('disabled with the control channel closed', (tester) async {
          await pumpAssistance(tester);

          peers.last.emitControlChannelState(WebRtcDataChannelState.closed);
          await settleUi(tester);

          expect(isEnabled(tester, recentsButton), isFalse);
        });

        const refusals = {
          RemoteControlError.accessibilityUnavailable:
              'El dispositivo no tiene habilitado el control remoto.',
          RemoteControlError.gestureRejected: 'No se pudo ejecutar la acción.',
          RemoteControlError.sessionNotActive:
              'La asistencia no está activa en el dispositivo.',
        };

        refusals.forEach((error, message) {
          testWidgets('${error.code} is explained and frees the rest', (
            tester,
          ) async {
            await pumpAssistance(tester);

            await press(tester, recentsButton);
            peers.last.emitRemoteControlAck('recents-1', error: error);
            await settleUi(tester);

            expect(navigationLine(tester), message);
            expect(peers.last.isClosed, isFalse);
            expect(remoteSessions.closedIds, isEmpty);
            expect(sent(), hasLength(1));
            expect(isEnabled(tester, recentsButton), isTrue);
            expect(gestureLayer, findsOneWidget);
          });
        });

        testWidgets('no answer in time says the action was not confirmed', (
          tester,
        ) async {
          await pumpAssistance(tester);

          await press(tester, recentsButton);
          await tester.pump(const Duration(milliseconds: 3050));
          await tester.pump();

          expect(
            navigationLine(tester),
            'El dispositivo no confirmó la acción.',
          );
          expect(isEnabled(tester, recentsButton), isTrue);
          expect(sent(), hasLength(1));
        });

        testWidgets(
          'during its guard nothing goes out, afterwards a tap does',
          (tester) async {
            await pumpAssistance(tester);

            await press(tester, recentsButton);
            peers.last.emitRemoteControlAck('recents-1');
            await tester.pump(const Duration(milliseconds: 50));

            expect(isEnabled(tester, backButton), isFalse);
            expect(isEnabled(tester, homeButton), isFalse);
            expect(isEnabled(tester, recentsButton), isFalse);
            expect(gestureLayer, findsNothing);
            await tester.tapAt(tester.getCenter(surface));
            await tester.tap(recentsButton, warnIfMissed: false);
            await tester.pump(const Duration(milliseconds: 150));
            expect(sent(), hasLength(1));

            await tester.pump(remoteNavigationSettleDuration);
            await tester.pump();
            expect(isEnabled(tester, recentsButton), isTrue);
            expect(gestureLayer, findsOneWidget);

            await clickCentre(tester);
            expect(sent(), hasLength(2));
            expect(sent().last, isA<RemoteTapCommand>());
          },
        );

        testWidgets('FINALIZAR is not held by the guard, and clears it', (
          tester,
        ) async {
          await pumpAssistance(tester);
          final session = peers.last;
          final gate = Completer<void>();
          remoteSessions.closeGate = gate.future;

          await press(tester, recentsButton);
          expect(navigationLine(tester), 'Enviando Recientes...');

          await tester.tap(
            find.byKey(const Key('close_remote_session_button')),
          );
          await tester.pump();
          await tester.pump();
          await tester.pump();

          expect(remoteSessions.closedIds, hasLength(1));
          expect(navigationStatus, findsNothing);
          expect(isEnabled(tester, recentsButton), isFalse);

          await tester.tap(recentsButton, warnIfMissed: false);
          session.emitRemoteControlAck('recents-1');
          await settleUi(tester);
          expect(navigationStatus, findsNothing);
          expect(session.sentRemoteControlCommands, hasLength(1));

          gate.complete();
          await settleUi(tester);

          expect(recentsButton, findsNothing);
          expect(session.sentRemoteControlCommands, hasLength(1));
        });
      });

      group('the bar stays on screen', () {
        final recentsButton = find.byKey(const Key('remote_recents_button'));
        final closeButton = find.byKey(
          const Key('close_remote_session_button'),
        );

        /// An ACTIVE assistance with a picture of [aspectRatio], in this window.
        Future<void> pumpInWindow(
          WidgetTester tester,
          Size viewSize, {
          double aspectRatio = 1280 / 800,
        }) async {
          remoteSessions.current = buildRemoteSession();
          realtime.peerJoinedOnJoin = true;
          await pumpConsole(tester, viewSize: viewSize);
          await connectSocket(tester);
          realtime.answerRelayAck({
            'delivered': true,
            'remoteSessionId': remoteSessionId,
          });
          await settleUi(tester);
          peers.last
            ..emitControlChannelState(WebRtcDataChannelState.open)
            ..emitPeerState(WebRtcPeerConnectionState.connected)
            ..emitRemoteVideoTrack('screen-0');
          await settleUi(tester);
          renderers.last.reportVideoAspectRatio(aspectRatio);
          await settleUi(tester);
        }

        void expectBarInside(WidgetTester tester, Size viewSize) {
          for (final button in [
            backButton,
            homeButton,
            recentsButton,
            closeButton,
          ]) {
            final rect = tester.getRect(button);
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.bottom, lessThanOrEqualTo(viewSize.height));
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(viewSize.width));
          }
        }

        const windows = [
          Size(1280, 855),
          Size(1920, 1080),
          Size(1280, 800),
          Size(1280, 600),
        ];

        for (final viewSize in windows) {
          for (final aspectRatio in const [1280 / 800, 800 / 1280]) {
            final name =
                '${viewSize.width.toInt()}x${viewSize.height.toInt()}, '
                '${aspectRatio > 1 ? 'landscape' : 'portrait'}';

            testWidgets('$name: inside the window, without scrolling', (
              tester,
            ) async {
              await pumpInWindow(tester, viewSize, aspectRatio: aspectRatio);

              expect(tester.takeException(), isNull);
              expectBarInside(tester, viewSize);

              final picture = tester.getRect(surface);
              expect(
                picture.width / picture.height,
                closeTo(aspectRatio, 0.01),
              );
              expect(
                tester.getRect(backButton).top,
                greaterThan(picture.bottom),
              );
            });
          }
        }

        testWidgets('at 855 px the picture keeps most of the window', (
          tester,
        ) async {
          const viewSize = Size(1280, 855);
          await pumpInWindow(tester, viewSize, aspectRatio: 800 / 1280);

          // The old limit was 70% of the window, with the bar off screen.
          expect(tester.getSize(surface).height, greaterThan(855 * 0.6));
        });

        testWidgets('a tall window does not grow it past its maximum', (
          tester,
        ) async {
          await pumpInWindow(
            tester,
            const Size(1400, 1400),
            aspectRatio: 800 / 1280,
          );

          expect(tester.getSize(surface).height, 900);
        });

        testWidgets('without video the bar is there too', (tester) async {
          const viewSize = Size(1280, 855);
          remoteSessions.current = buildRemoteSession();
          realtime.peerJoinedOnJoin = true;
          await pumpConsole(tester, viewSize: viewSize);
          await connectSocket(tester);
          realtime.answerRelayAck({
            'delivered': true,
            'remoteSessionId': remoteSessionId,
          });
          await settleUi(tester);
          peers.last
            ..emitControlChannelState(WebRtcDataChannelState.open)
            ..emitPeerState(WebRtcPeerConnectionState.connected);
          await settleUi(tester);

          expect(tester.takeException(), isNull);
          expectBarInside(tester, viewSize);
        });

        testWidgets('an error banner takes its height from the picture', (
          tester,
        ) async {
          const viewSize = Size(1280, 855);
          await pumpInWindow(tester, viewSize, aspectRatio: 800 / 1280);
          final before = tester.getSize(surface).height;
          final renderer = renderers.last;
          remoteSessions.closeFailure = const NetworkFailure();

          await tester.tap(closeButton);
          await settleUi(tester);

          expect(
            find.byKey(const Key('remote_session_error_banner')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          expect(tester.getSize(surface).height, lessThan(before));
          expectBarInside(tester, viewSize);
          expect(renderers.created, [same(renderer)]);
          expect(renderer.disposeCount, 0);
        });

        testWidgets('a message does not move the buttons', (tester) async {
          await pumpInWindow(tester, const Size(1280, 855));
          final before = tester.getRect(recentsButton);

          await press(tester, recentsButton);
          peers.last.emitRemoteControlAck(
            'recents-1',
            error: RemoteControlError.accessibilityUnavailable,
          );
          await settleUi(tester);

          expect(navigationStatus, findsOneWidget);
          expect(tester.getRect(recentsButton), before);
        });

        for (final viewSize in const [
          Size(1000, 800),
          Size(700, 800),
          Size(500, 800),
          Size(420, 800),
          Size(360, 640),
        ]) {
          for (final aspectRatio in const [1280 / 800, 800 / 1280]) {
            final name =
                '${viewSize.width.toInt()}x${viewSize.height.toInt()}, '
                '${aspectRatio > 1 ? 'landscape' : 'portrait'}';

            testWidgets('$name: wraps, nothing overflows or is cut', (
              tester,
            ) async {
              await pumpInWindow(tester, viewSize, aspectRatio: aspectRatio);

              expect(tester.takeException(), isNull);
              // Down to where the title of the section starts wrapping, which
              // the test font makes happen far sooner than a real one does.
              expectBarInside(
                tester,
                viewSize.width > 420 ? viewSize : Size(viewSize.width, 5000),
              );
              expect(find.text('Atrás'), findsOneWidget);
              expect(find.text('Inicio'), findsOneWidget);
              expect(find.text('Recientes'), findsOneWidget);
              expect(find.text('FINALIZAR ASISTENCIA'), findsOneWidget);
              final picture = tester.getSize(surface);
              expect(
                picture.width / picture.height,
                closeTo(aspectRatio, 0.01),
              );
            });
          }
        }

        testWidgets('a smaller picture keeps the gestures aligned', (
          tester,
        ) async {
          await pumpInWindow(tester, const Size(1280, 855));

          await clickCentre(tester);

          final tap = sent().single as RemoteTapCommand;
          expect(tap.point.x, closeTo(0.5, 1e-9));
          expect(tap.point.y, closeTo(0.5, 1e-9));
        });

        testWidgets('a resize keeps the renderer', (tester) async {
          await pumpInWindow(tester, const Size(1280, 855));
          final renderer = renderers.last;

          tester.view.physicalSize = const Size(900, 700);
          await settleUi(tester);

          expect(tester.takeException(), isNull);
          expect(renderers.created, [same(renderer)]);
          expect(renderer.disposeCount, 0);
          expect(renderer.detachCount, 0);
          expectBarInside(tester, const Size(900, 700));
        });
      });
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
      expect(
        find.byKey(const Key('active_assistance_section')),
        findsOneWidget,
      );

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
    testWidgets('no token or transport detail is ever rendered', (
      tester,
    ) async {
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
