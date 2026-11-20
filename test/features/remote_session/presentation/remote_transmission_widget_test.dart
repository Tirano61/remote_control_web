import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/app/composition_root.dart';
import 'package:remote_control_web/app/remote_control_app.dart';
import 'package:remote_control_web/core/config/app_config.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:remote_control_web/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_web/features/remote_session/presentation/widgets/active_assistance_section.dart';
import 'package:remote_control_web/features/signaling/data/technician_signaling_client_impl.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_web/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../../support/auth_test_doubles.dart';
import '../../../support/console_test_doubles.dart';
import '../../../support/realtime_test_doubles.dart';
import '../../../support/remote_session_test_doubles.dart';
import '../../../support/webrtc_test_doubles.dart';

/// The transmission indicator on the real console: every BLoC, the
/// coordinator and the cubit wired as in production, only the edges faked.
void main() {
  late FakeAuthRemoteDataSource auth;
  late InMemoryUserTokenStorage storage;
  late FakeDeviceRepository devices;
  late FakeSupportRequestRepository supportRequests;
  late FakeRemoteSessionRepository remoteSessions;
  late FakeTechnicianRealtimeClient realtime;
  late FakeWebRtcPeerClient peers;
  late FakeRemoteVideoRendererFactory renderers;

  final interruptedNotice = find.byKey(
    const Key('remote_transmission_interrupted'),
  );
  final recoveringNotice = find.byKey(
    const Key('remote_transmission_recovering'),
  );
  final placeholder = find.byKey(const Key('remote_transmission_placeholder'));
  final anyNotice = find.byWidgetPredicate(
    (widget) =>
        widget.key == const Key('remote_transmission_interrupted') ||
        widget.key == const Key('remote_transmission_recovering') ||
        widget.key == const Key('remote_transmission_placeholder'),
  );
  final picture = find.byKey(const Key('remote_screen_video'));
  final gestureLayer = find.byKey(const Key('remote_screen_gesture_layer'));

  setUp(() {
    auth = FakeAuthRemoteDataSource()..checkStatusResponse = technicianSession;
    storage = InMemoryUserTokenStorage()..token = 'stored-user-jwt';
    devices = FakeDeviceRepository()..devices = [buildDevice()];
    supportRequests = FakeSupportRequestRepository();
    remoteSessions = FakeRemoteSessionRepository();
    realtime = FakeTechnicianRealtimeClient();
    peers = FakeWebRtcPeerClient();
    renderers = FakeRemoteVideoRendererFactory();
  });

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
          pendingRemoteSessionCloseStore:
              InMemoryPendingRemoteSessionCloseStore(),
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

  WebRtcSessionBloc webRtcOf(WidgetTester tester) =>
      BlocProvider.of<WebRtcSessionBloc>(
        tester.element(find.byKey(const Key('active_assistance_section'))),
      );

  /// The offer of the newest peer connection is relayed, and that peer
  /// connection connects and shows the tablet's screen.
  Future<void> connectNewestPeer(WidgetTester tester, String track) async {
    realtime.answerRelayAck({
      'delivered': true,
      'remoteSessionId': remoteSessionId,
    });
    await settleUi(tester);
    peers.last
      ..emitControlChannelState(WebRtcDataChannelState.open)
      ..emitPeerState(WebRtcPeerConnectionState.connected)
      ..emitRemoteVideoTrack(track);
    await settleUi(tester);
    renderers.last.reportVideoAspectRatio(1280 / 800);
    await settleUi(tester);
  }

  /// An ACTIVE assistance, its peers connected and its screen on screen.
  Future<void> pumpWorkingAssistance(WidgetTester tester) async {
    remoteSessions.current = buildRemoteSession();
    realtime.peerJoinedOnJoin = true;
    await pumpConsole(tester);
    realtime.emitConnected();
    await settleUi(tester);
    await connectNewestPeer(tester, 'screen-0');
    expect(find.text('Estado: Asistencia en curso'), findsOneWidget);
    expect(picture, findsOneWidget);
  }

  String? noticeTitle(WidgetTester tester) {
    final title = find.byKey(const Key('remote_transmission_title'));
    if (title.evaluate().isEmpty) return null;
    return tester.widget<Text>(title).data;
  }

  testWidgets('A. a working assistance shows no notice at all', (tester) async {
    await pumpWorkingAssistance(tester);

    expect(anyNotice, findsNothing);
    expect(gestureLayer, findsOneWidget);
    // Still the same after a while: nothing is inferred from a still picture.
    await tester.pump(const Duration(minutes: 2));
    await settleUi(tester);
    expect(anyNotice, findsNothing);
  });

  testWidgets('ICE disconnected: interrupted over the last picture, gone '
      'when ICE comes back', (tester) async {
    await pumpWorkingAssistance(tester);

    peers.last.emitPeerState(WebRtcPeerConnectionState.disconnected);
    await settleUi(tester);

    expect(interruptedNotice, findsOneWidget);
    expect(noticeTitle(tester), kTransmissionInterruptedTitle);
    expect(find.text(kTransmissionPeerInterruptedNotice), findsOneWidget);
    // Over the picture, not instead of it.
    expect(picture, findsOneWidget);

    peers.last.emitPeerState(WebRtcPeerConnectionState.connected);
    await settleUi(tester);
    expect(anyNotice, findsNothing);
  });

  testWidgets('B/C. the socket drops with WebRTC connected: unconfirmed, '
      'and recovered once presence and the room are read again', (
    tester,
  ) async {
    await pumpWorkingAssistance(tester);

    realtime.emitReconnecting();
    await settleUi(tester);
    expect(noticeTitle(tester), kTransmissionServerUnreachableTitle);
    expect(find.text(kTransmissionServerUnreachableNotice), findsOneWidget);
    // Never claimed as an interruption of the tablet.
    expect(find.text(kTransmissionInterruptedTitle), findsNothing);
    expect(picture, findsOneWidget);

    realtime.emitConnected();
    await settleUi(tester);
    expect(anyNotice, findsNothing);
  });

  testWidgets('D. REST failing after the reconnection: never recovered '
      'without a read', (tester) async {
    await pumpWorkingAssistance(tester);
    realtime.emitReconnecting();
    await settleUi(tester);

    devices.failure = const NetworkFailure();
    realtime.emitConnected();
    await settleUi(tester);
    expect(noticeTitle(tester), kTransmissionUnconfirmedTitle);

    devices.failure = null;
    realtime.emitDevicePresenceUpdated(deviceId);
    await settleUi(tester);
    expect(anyNotice, findsNothing);
  });

  testWidgets('D (T10A). REINTENTAR after REST came back re-reads presence '
      'too: the notice does not stay unconfirmed', (tester) async {
    await pumpWorkingAssistance(tester);
    realtime.emitReconnecting();
    await settleUi(tester);
    devices.failure = const NetworkFailure();
    remoteSessions.currentFailure = const NetworkFailure();
    realtime.emitConnected();
    await settleUi(tester);
    expect(noticeTitle(tester), kTransmissionUnconfirmedTitle);
    expect(webRtcOf(tester).state.canSendRemoteNavigation, isFalse);

    devices.failure = null;
    remoteSessions.currentFailure = null;
    final loadsBefore = devices.loadCount;
    await tester.tap(find.byKey(const Key('remote_session_retry_button')));
    await settleUi(tester);

    expect(devices.loadCount, loadsBefore + 1);
    expect(anyNotice, findsNothing);
    expect(webRtcOf(tester).state.canSendRemoteNavigation, isTrue);
  });

  testWidgets('16/17/20. the tablet offline and back: the notice follows the '
      'evidence and never touches remote control', (tester) async {
    await pumpWorkingAssistance(tester);
    final webRtc = webRtcOf(tester);
    expect(webRtc.state.canSendRemoteControl, isTrue);

    devices.devices = [buildDevice(isOnline: false)];
    realtime.emitDevicePresenceUpdated(deviceId);
    await settleUi(tester);

    expect(interruptedNotice, findsOneWidget);
    expect(find.text(kTransmissionDeviceOfflineNotice), findsOneWidget);
    // Information only: what the coordinator allowed stays allowed — the
    // tablet refuses on its own side — and the notice takes no pointer.
    expect(webRtc.state.canSendRemoteControl, isTrue);
    expect(gestureLayer, findsOneWidget);
    // A click right on the notice still reaches the picture under it.
    final sentBefore = peers.last.sentRemoteControlCommands.length;
    await tester.tap(find.byKey(const Key('remote_screen_surface')));
    await settleUi(tester);
    expect(peers.last.sentRemoteControlCommands, hasLength(sentBefore + 1));

    devices.devices = [buildDevice()];
    realtime.emitDevicePresenceUpdated(deviceId);
    await settleUi(tester);
    // Online is not "back": the tablet lets its screen through only once
    // its authority is confirmed, which is when it re-enters the room.
    expect(recoveringNotice, findsOneWidget);
    expect(noticeTitle(tester), kTransmissionRecoveringTitle);

    realtime.emitPeerJoined(remoteSessionId);
    await settleUi(tester);
    expect(anyNotice, findsNothing);
    expect(webRtc.state.canSendRemoteControl, isTrue);
  });

  testWidgets('20. a paused remote control stays paused whatever the '
      'notice does', (tester) async {
    await pumpWorkingAssistance(tester);
    final webRtc = webRtcOf(tester);

    realtime.emitReconnecting();
    await settleUi(tester);
    expect(webRtc.state.canSendRemoteNavigation, isFalse);
    expect(find.byKey(const Key('remote_control_paused_notice')), findsOne);

    // The tablet's presence comes and goes meanwhile: nothing changes for
    // remote control, which waits for the coordinator's own check.
    realtime.emitPeerJoined(remoteSessionId);
    await settleUi(tester);
    expect(webRtc.state.canSendRemoteNavigation, isFalse);
  });

  testWidgets('E/6/13. ICE failed: the place of the picture says recovering, '
      'the replacement connects, and the old peer connection cannot bring '
      'a notice back', (tester) async {
    await pumpWorkingAssistance(tester);
    final failedPeer = peers.last;

    failedPeer.emitPeerState(WebRtcPeerConnectionState.failed);
    await settleUi(tester);

    // The peer connection and its picture are gone; the attempt planned at
    // once reads REST and negotiates again.
    expect(picture, findsNothing);
    expect(peers.sessions, hasLength(2));
    expect(noticeTitle(tester), kTransmissionRecoveringTitle);
    // While the replacement has no picture yet, in the place of the picture.
    expect(
      placeholder.evaluate().length + recoveringNotice.evaluate().length,
      1,
    );

    await connectNewestPeer(tester, 'screen-1');
    expect(anyNotice, findsNothing);
    expect(picture, findsOneWidget);

    // A late callback of the failed generation.
    failedPeer.emitPeerState(WebRtcPeerConnectionState.disconnected);
    await settleUi(tester);
    expect(anyNotice, findsNothing);
  });

  testWidgets('F/10. FINALIZAR during an interruption: the ended view '
      'replaces every notice at once', (tester) async {
    await pumpWorkingAssistance(tester);
    peers.last.emitPeerState(WebRtcPeerConnectionState.disconnected);
    realtime.emitReconnecting();
    await settleUi(tester);
    expect(interruptedNotice, findsOneWidget);

    await tester.tap(find.byKey(const Key('close_remote_session_button')));
    await tester.pump();

    expect(anyNotice, findsNothing);
    expect(find.byKey(const Key('active_assistance_section')), findsNothing);

    // Nothing that comes afterwards shows a recovery for it.
    realtime.emitConnected();
    await settleUi(tester);
    expect(anyNotice, findsNothing);
    expect(find.text(kTransmissionRecoveringTitle), findsNothing);
  });

  testWidgets('9/11. a SYSTEM close during a recovery ends the view', (
    tester,
  ) async {
    await pumpWorkingAssistance(tester);
    peers.last.emitPeerState(WebRtcPeerConnectionState.disconnected);
    await settleUi(tester);
    expect(interruptedNotice, findsOneWidget);

    remoteSessions.current = null;
    realtime.emitRemoteSessionClosed(remoteSessionId, endedBy: 'SYSTEM');
    await settleUi(tester);

    expect(anyNotice, findsNothing);
    expect(find.text('FINALIZAR ASISTENCIA'), findsNothing);
  });

  testWidgets('the console says what it says only for its own session', (
    tester,
  ) async {
    await pumpWorkingAssistance(tester);
    final status = BlocProvider.of<RemoteSessionBloc>(
      tester.element(find.byKey(const Key('active_assistance_section'))),
    ).state;
    expect(status.session?.id, remoteSessionId);

    realtime.emitPeerJoined('another-session');
    await settleUi(tester);
    expect(anyNotice, findsNothing);
  });
}
