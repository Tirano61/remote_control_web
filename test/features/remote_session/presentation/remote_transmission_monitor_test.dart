import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control_web/core/error/failure.dart';
import 'package:remote_control_web/features/devices/presentation/bloc/devices/devices_bloc.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_command.dart';
import 'package:remote_control_web/features/remote_control/domain/entities/remote_control_status.dart';
import 'package:remote_control_web/features/remote_session/domain/entities/remote_session_status.dart';
import 'package:remote_control_web/features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import 'package:remote_control_web/features/remote_session/presentation/transmission/remote_transmission_monitor.dart';
import 'package:remote_control_web/features/remote_session/presentation/transmission/remote_transmission_status.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/signaling_error_code.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/technician_realtime_status.dart';
import 'package:remote_control_web/features/technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_web/features/webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';

import '../../../support/console_test_doubles.dart';
import '../../../support/remote_session_test_doubles.dart';
import '../../../support/webrtc_test_doubles.dart';

const String otherSessionId = '7a0c2f4e-1111-4222-8333-944455556666';

RemoteSessionActive activeSession([String id = remoteSessionId]) =>
    RemoteSessionActive(
      session: buildRemoteSession(id: id, status: RemoteSessionStatus.active),
    );

RemoteControlStatus control({
  bool isPictureDisplayed = true,
  RemoteCommandFeedback? lastCommand,
}) => RemoteControlStatus(
  isSessionActive: true,
  isPictureDisplayed: isPictureDisplayed,
  lastCommand: lastCommand,
);

WebRtcSessionState connected({
  String id = remoteSessionId,
  bool isPictureDisplayed = true,
  RemoteCommandFeedback? lastCommand,
  String track = 'track-1',
}) => WebRtcConnected(
  remoteSessionId: id,
  controlChannelState: WebRtcDataChannelState.open,
  remoteVideoTrack: FakeRemoteVideoTrack(track),
  remoteControl: control(
    isPictureDisplayed: isPictureDisplayed,
    lastCommand: lastCommand,
  ),
);

WebRtcSessionState interrupted({String id = remoteSessionId}) =>
    WebRtcInterrupted(
      remoteSessionId: id,
      controlChannelState: WebRtcDataChannelState.open,
      remoteVideoTrack: const FakeRemoteVideoTrack('track-1'),
      remoteControl: control(),
    );

DevicesState devicesWith({bool isOnline = true, bool isRefreshing = false}) =>
    DevicesLoaded(
      devices: [buildDevice(isOnline: isOnline)],
      isRefreshing: isRefreshing,
    );

/// The console as the indicator sees it: five states, changed one at a time,
/// each change observed — exactly what the cubit feeds the monitor.
class Console {
  Console() {
    observe();
  }

  final RemoteTransmissionMonitor monitor = RemoteTransmissionMonitor();
  RemoteSessionState session = activeSession();
  WebRtcSessionState webRtc = connected();
  TechnicianRealtimeStatus realtime = const TechnicianRealtimeConnected(1);
  DevicesState devices = devicesWith();
  SignalingJoinState join = const SignalingJoined(
    remoteSessionId,
    peerJoined: true,
  );

  RemoteTransmissionStatus get status => monitor.status;

  RemoteTransmissionStatus observe() => monitor.observe(
    RemoteTransmissionSignals(
      session: session,
      webRtc: webRtc,
      realtime: realtime,
      devices: devices,
      join: join,
    ),
  );

  RemoteTransmissionStatus setWebRtc(WebRtcSessionState value) {
    webRtc = value;
    return observe();
  }

  RemoteTransmissionStatus setSession(RemoteSessionState value) {
    session = value;
    return observe();
  }

  RemoteTransmissionStatus setDevices(DevicesState value) {
    devices = value;
    return observe();
  }

  RemoteTransmissionStatus setJoin(SignalingJoinState value) {
    join = value;
    return observe();
  }

  /// The socket drops: the room goes with it, as the coordinator resets it.
  void dropSocket() {
    realtime = const TechnicianRealtimeReconnecting();
    observe();
    setJoin(const SignalingIdle());
  }

  /// The socket comes back on a new connection, and the coordinator's
  /// `GET /devices` and join run, in the order they really do.
  void restoreSocket({
    bool isDeviceOnline = true,
    bool peerJoined = true,
    bool devicesFail = false,
    String id = remoteSessionId,
  }) {
    realtime = TechnicianRealtimeConnected((realtime.connectionId ?? 1) + 1);
    observe();
    final previous = devices as DevicesLoaded;
    setDevices(previous.copyWith(isRefreshing: true));
    setJoin(SignalingJoining(id));
    setDevices(
      devicesFail
          ? previous.copyWith(
              isRefreshing: false,
              refreshFailure: const NetworkFailure(),
            )
          : devicesWith(isOnline: isDeviceOnline),
    );
    setJoin(SignalingJoined(id, peerJoined: peerJoined));
  }

  /// `device:presence-updated` -> `GET /devices` answering [isOnline].
  void presence({required bool isOnline}) {
    final previous = devices as DevicesLoaded;
    setDevices(previous.copyWith(isRefreshing: true));
    setDevices(devicesWith(isOnline: isOnline));
  }
}

void expectStatus(
  RemoteTransmissionStatus status,
  RemoteTransmissionPhase phase, [
  RemoteTransmissionCause? cause,
]) {
  expect(status.phase, phase, reason: '$status');
  if (cause != null) expect(status.cause, cause, reason: '$status');
}

void main() {
  group('healthy transmission', () {
    test('1. ACTIVE with the picture on screen: nothing to say', () {
      final console = Console();

      expectStatus(console.status, RemoteTransmissionPhase.available);
      expect(console.status.remoteSessionId, remoteSessionId);
      expect(console.status.isNoticeFor(remoteSessionId), isFalse);
    });

    test('7. a tablet online that shares no screen yet is not a problem', () {
      final console = Console()
        ..setWebRtc(const WebRtcConnecting(remoteSessionId: remoteSessionId));
      expectStatus(console.status, RemoteTransmissionPhase.available);

      // Connected, channel open, no picture: the existing "Esperando pantalla
      // del dispositivo..." is what the technician needs to read.
      final fresh = Console();
      fresh
        ..setWebRtc(const WebRtcIdle())
        ..setWebRtc(connected(isPictureDisplayed: false));
      expectStatus(fresh.status, RemoteTransmissionPhase.available);
    });

    test('8. a still screen on a healthy connection says nothing, however '
        'often it is looked at', () {
      final console = Console();
      for (var i = 0; i < 100; i++) {
        console.observe();
      }
      // The monitor has no timer and never looks at frames: only signals.
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('a negotiation that never connected in this page says nothing', () {
      final console = Console()
        ..setWebRtc(const WebRtcPreparing(remoteSessionId: remoteSessionId));
      // Brand new monitor whose session never connected.
      final monitor = RemoteTransmissionMonitor();
      final status = monitor.observe(
        RemoteTransmissionSignals(
          session: activeSession(),
          webRtc: const WebRtcFailed(
            remoteSessionId: remoteSessionId,
            reason: WebRtcFailureReason.connectionFailed,
          ),
          realtime: const TechnicianRealtimeReconnecting(),
          devices: devicesWith(isOnline: false),
          join: const SignalingIdle(),
        ),
      );
      expectStatus(status, RemoteTransmissionPhase.available);
      expect(console.status.phase, RemoteTransmissionPhase.available);
    });
  });

  group('confirmed interruptions', () {
    test('2/16. the backend reports the tablet offline', () {
      final console = Console()..presence(isOnline: false);

      expectStatus(
        console.status,
        RemoteTransmissionPhase.interrupted,
        RemoteTransmissionCause.deviceOffline,
      );
      expect(console.status.isProminent, isTrue);
    });

    test('3. ICE disconnected on the current peer connection', () {
      final console = Console()..setWebRtc(interrupted());

      expectStatus(
        console.status,
        RemoteTransmissionPhase.interrupted,
        RemoteTransmissionCause.peerDisconnected,
      );

      // ICE comes back on the same peer connection: the notice goes.
      console.setWebRtc(connected());
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('4. ICE failed: recovering while an attempt is planned, '
        'unavailable once none is left', () {
      final console = Console()
        ..setWebRtc(
          const WebRtcFailed(
            remoteSessionId: remoteSessionId,
            reason: WebRtcFailureReason.connectionFailed,
            isRecoveryScheduled: true,
          ),
        );
      expectStatus(
        console.status,
        RemoteTransmissionPhase.recovering,
        RemoteTransmissionCause.connectionFailed,
      );

      console.setWebRtc(
        const WebRtcFailed(
          remoteSessionId: remoteSessionId,
          reason: WebRtcFailureReason.connectionFailed,
        ),
      );
      expectStatus(
        console.status,
        RemoteTransmissionPhase.unavailable,
        RemoteTransmissionCause.connectionFailed,
      );
    });

    test('ICE disconnected wins over a socket that dropped too', () {
      final console = Console()
        ..dropSocket()
        ..setWebRtc(interrupted());
      expectStatus(
        console.status,
        RemoteTransmissionPhase.interrupted,
        RemoteTransmissionCause.peerDisconnected,
      );
    });
  });

  group('what the console cannot confirm', () {
    test('the socket drops while WebRTC stays connected: unconfirmed, '
        'never "interrupted"', () {
      final console = Console()..dropSocket();

      expectStatus(
        console.status,
        RemoteTransmissionPhase.unconfirmed,
        RemoteTransmissionCause.serverUnreachable,
      );
    });

    test('presence shown before the socket dropped is not trusted while it '
        'is down', () {
      final console = Console()
        ..dropSocket()
        ..setDevices(devicesWith(isOnline: false));
      expectStatus(
        console.status,
        RemoteTransmissionPhase.unconfirmed,
        RemoteTransmissionCause.serverUnreachable,
      );
    });

    test('D. a GET /devices that fails after the reconnection keeps it '
        'unconfirmed, and a later one settles it', () {
      final console = Console()
        ..dropSocket()
        ..restoreSocket(devicesFail: true);
      expectStatus(
        console.status,
        RemoteTransmissionPhase.unconfirmed,
        RemoteTransmissionCause.stateUnconfirmed,
      );

      console.presence(isOnline: true);
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('a join refused after the reconnection keeps it unconfirmed', () {
      final console = Console()..dropSocket();
      console.realtime = const TechnicianRealtimeConnected(2);
      console
        ..observe()
        ..setDevices(devicesWith(isRefreshing: true))
        ..setDevices(devicesWith())
        ..setJoin(const SignalingJoining(remoteSessionId))
        ..setJoin(
          const SignalingUnavailable(
            remoteSessionId: remoteSessionId,
            error: SignalingErrorCode.unavailable,
          ),
        );
      expectStatus(
        console.status,
        RemoteTransmissionPhase.unconfirmed,
        RemoteTransmissionCause.stateUnconfirmed,
      );

      // REINTENTAR on the channel line: joined, the tablet is in.
      console.setJoin(const SignalingJoined(remoteSessionId, peerJoined: true));
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('the tablet answers a command session_not_active: possibly paused, '
        'until it accepts one again', () {
      final console = Console()
        ..setWebRtc(
          connected(
            lastCommand: const RemoteCommandFeedback(
              commandId: 'c-1',
              kind: RemoteCommandKind.tap,
              outcome: RemoteCommandOutcome.pending,
            ),
          ),
        );
      expectStatus(console.status, RemoteTransmissionPhase.available);

      console.setWebRtc(
        connected(
          lastCommand: const RemoteCommandFeedback(
            commandId: 'c-1',
            kind: RemoteCommandKind.tap,
            outcome: RemoteCommandOutcome.sessionNotActive,
          ),
        ),
      );
      expectStatus(
        console.status,
        RemoteTransmissionPhase.possiblyPaused,
        RemoteTransmissionCause.deviceRefusedCommand,
      );

      console.setWebRtc(
        connected(
          lastCommand: const RemoteCommandFeedback(
            commandId: 'c-2',
            kind: RemoteCommandKind.back,
            outcome: RemoteCommandOutcome.confirmed,
          ),
        ),
      );
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('a refused command is cleared by the tablet re-entering the room', () {
      final console = Console()
        ..setWebRtc(
          connected(
            lastCommand: const RemoteCommandFeedback(
              commandId: 'c-1',
              kind: RemoteCommandKind.tap,
              outcome: RemoteCommandOutcome.sessionNotActive,
            ),
          ),
        );
      expect(console.status.phase, RemoteTransmissionPhase.possiblyPaused);

      console.monitor.peerJoined(remoteSessionId);
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });
  });

  group('recovery', () {
    test('5. socket back with WebRTC still pending is not "recovered"', () {
      final console = Console()..dropSocket();
      // The negotiation is being replaced while the socket is away.
      console.setWebRtc(
        const WebRtcConnecting(remoteSessionId: remoteSessionId),
      );
      console.restoreSocket();

      expectStatus(
        console.status,
        RemoteTransmissionPhase.recovering,
        RemoteTransmissionCause.renegotiating,
      );

      console.setWebRtc(connected(isPictureDisplayed: false));
      expectStatus(
        console.status,
        RemoteTransmissionPhase.recovering,
        RemoteTransmissionCause.renegotiating,
      );

      console.setWebRtc(connected(track: 'track-2'));
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('while presence and the room are being read again it is '
        'recovering, not recovered', () {
      final console = Console()..dropSocket();
      console.realtime = const TechnicianRealtimeConnected(2);
      expectStatus(
        console.observe(),
        RemoteTransmissionPhase.recovering,
        RemoteTransmissionCause.reconnecting,
      );
      console.setDevices(devicesWith(isRefreshing: true));
      expect(console.status.cause, RemoteTransmissionCause.reconnecting);
      console.setDevices(devicesWith());
      // The room is not joined again yet.
      expect(console.status.cause, RemoteTransmissionCause.reconnecting);
      console
        ..setJoin(const SignalingJoining(remoteSessionId))
        ..setJoin(const SignalingJoined(remoteSessionId, peerJoined: true));
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('12. a GET /devices in flight across the reconnection does not end '
        'the recovery: the read queued behind it does', () {
      final console = Console()
        ..setDevices(devicesWith(isRefreshing: true))
        ..dropSocket();
      console.realtime = const TechnicianRealtimeConnected(2);
      console.observe();
      // The old read answers, with the coordinator's read queued behind it.
      console.setDevices(devicesWith(isRefreshing: true));
      expect(console.status.cause, RemoteTransmissionCause.reconnecting);
      console
        ..setJoin(const SignalingJoined(remoteSessionId, peerJoined: true))
        ..setDevices(devicesWith());
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('socket back, the tablet not in the room: waiting for the tablet, '
        'until it enters', () {
      final console = Console()
        ..dropSocket()
        ..restoreSocket(peerJoined: false);
      expectStatus(
        console.status,
        RemoteTransmissionPhase.recovering,
        RemoteTransmissionCause.awaitingDevice,
      );

      console.setJoin(const SignalingJoined(remoteSessionId, peerJoined: true));
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('socket back with the tablet offline: interrupted', () {
      final console = Console()
        ..dropSocket()
        ..restoreSocket(isDeviceOnline: false, peerJoined: false);
      expectStatus(
        console.status,
        RemoteTransmissionPhase.interrupted,
        RemoteTransmissionCause.deviceOffline,
      );
    });

    test('6/18. peer recovered: failed -> new negotiation -> picture', () {
      final console = Console()
        ..setWebRtc(
          const WebRtcFailed(
            remoteSessionId: remoteSessionId,
            reason: WebRtcFailureReason.connectionFailed,
            isRecoveryScheduled: true,
          ),
        );
      // The recovery attempt: REST confirmed the session, a new offer.
      console
        ..setWebRtc(const WebRtcPreparing(remoteSessionId: remoteSessionId))
        ..setWebRtc(const WebRtcOffering(remoteSessionId: remoteSessionId));
      expectStatus(
        console.status,
        RemoteTransmissionPhase.recovering,
        RemoteTransmissionCause.renegotiating,
      );
      console.setWebRtc(
        const WebRtcConnecting(remoteSessionId: remoteSessionId),
      );
      expect(console.status.phase, RemoteTransmissionPhase.recovering);
      // Connected and channel open, but no picture yet: not yet.
      console.setWebRtc(connected(isPictureDisplayed: false, track: 'b'));
      expect(console.status.phase, RemoteTransmissionPhase.recovering);
      console.setWebRtc(connected(track: 'b'));
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('17. presence back: waits for the tablet to show it holds the '
        'assistance again', () {
      final console = Console()..presence(isOnline: false);
      expect(console.status.cause, RemoteTransmissionCause.deviceOffline);

      console.presence(isOnline: true);
      expectStatus(
        console.status,
        RemoteTransmissionPhase.recovering,
        RemoteTransmissionCause.awaitingDevice,
      );

      // It re-enters the room only with its authority confirmed.
      console.monitor.peerJoined(remoteSessionId);
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('17. the tablet re-entering the room while the offline answer was '
        'in flight does not leave the notice stuck', () {
      final console = Console();
      final loaded = console.devices as DevicesLoaded;
      console.setDevices(loaded.copyWith(isRefreshing: true));
      // The tablet came back and rejoined while that GET was travelling.
      console.monitor.peerJoined(remoteSessionId);
      // The old GET answers offline, with the next one queued behind it.
      console.setDevices(devicesWith(isOnline: false, isRefreshing: true));
      expect(console.status.cause, RemoteTransmissionCause.deviceOffline);
      console.setDevices(devicesWith());
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('peer-joined of another session is no evidence', () {
      final console = Console()
        ..presence(isOnline: false)
        ..presence(isOnline: true);
      console.monitor.peerJoined(otherSessionId);
      expect(console.status.cause, RemoteTransmissionCause.awaitingDevice);
    });

    test('a new negotiation the tablet answered is evidence; ICE coming '
        'back on the same peer connection is not', () {
      final console = Console()
        ..presence(isOnline: false)
        ..presence(isOnline: true)
        ..setWebRtc(interrupted())
        ..setWebRtc(connected());
      expect(console.status.cause, RemoteTransmissionCause.awaitingDevice);

      console
        ..setWebRtc(const WebRtcConnecting(remoteSessionId: remoteSessionId))
        ..setWebRtc(connected(track: 'b'));
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('15. several cuts in a row, each one recovered', () {
      final console = Console();
      for (var i = 0; i < 3; i++) {
        console.setWebRtc(interrupted());
        expect(console.status.phase, RemoteTransmissionPhase.interrupted);
        console.setWebRtc(connected());
        expect(console.status.phase, RemoteTransmissionPhase.available);

        console.dropSocket();
        expect(console.status.phase, RemoteTransmissionPhase.unconfirmed);
        console.restoreSocket();
        expect(console.status.phase, RemoteTransmissionPhase.available);

        console.presence(isOnline: false);
        expect(console.status.phase, RemoteTransmissionPhase.interrupted);
        console.presence(isOnline: true);
        console.monitor.peerJoined(remoteSessionId);
        expect(console.status.phase, RemoteTransmissionPhase.available);
      }
    });
  });

  group('the end of an assistance wins over everything', () {
    test(
      '9/11. remote-session:closed (DEVICE or SYSTEM) during a recovery',
      () {
        final console = Console()
          ..setWebRtc(
            const WebRtcFailed(
              remoteSessionId: remoteSessionId,
              reason: WebRtcFailureReason.connectionFailed,
              isRecoveryScheduled: true,
            ),
          );
        expect(console.status.phase, RemoteTransmissionPhase.recovering);

        console.setSession(const RemoteSessionIdle());
        expect(console.status, RemoteTransmissionStatus.hidden);

        // A WebRTC state of the closed session arriving late changes nothing.
        console.setWebRtc(interrupted());
        expect(console.status, RemoteTransmissionStatus.hidden);
      },
    );

    test('10. FINALIZAR during an interruption: nothing to recover', () {
      final console = Console()
        ..setWebRtc(interrupted())
        ..dropSocket();
      expect(console.status.phase, RemoteTransmissionPhase.interrupted);

      console.setSession(
        const RemoteSessionEnding(remoteSessionId: remoteSessionId),
      );
      expect(console.status, RemoteTransmissionStatus.hidden);

      // Whatever happens next — the socket back, a late WebRTC callback — no
      // recovery is ever shown for it.
      console
        ..restoreSocket()
        ..setWebRtc(connected());
      expect(console.status, RemoteTransmissionStatus.hidden);
    });

    test('19. a close that stays pending (unconfirmed) shows no transmission '
        'state', () {
      final console = Console()
        ..setSession(
          const RemoteSessionEnding(
            remoteSessionId: remoteSessionId,
            isConfirming: false,
          ),
        );
      expect(console.status, RemoteTransmissionStatus.hidden);
      console.presence(isOnline: false);
      expect(console.status, RemoteTransmissionStatus.hidden);
    });
  });

  group('identity', () {
    test('13. a WebRTC state about another session is never shown on this '
        'one', () {
      final console = Console()..setWebRtc(interrupted(id: otherSessionId));
      // Not about this session: its own negotiation is gone, nothing else.
      expect(console.status.remoteSessionId, remoteSessionId);
      expect(
        console.status.cause,
        isNot(RemoteTransmissionCause.peerDisconnected),
      );
    });

    test('14. a new assistance inherits nothing of the previous one', () {
      final console = Console()
        ..dropSocket()
        ..setWebRtc(interrupted());
      expect(console.status.phase, RemoteTransmissionPhase.interrupted);

      // The old one ends; another one starts and is negotiated from zero.
      console
        ..setSession(const RemoteSessionIdle())
        ..setWebRtc(const WebRtcIdle())
        ..restoreSocket(id: otherSessionId);
      console
        ..setSession(activeSession(otherSessionId))
        ..setWebRtc(const WebRtcPreparing(remoteSessionId: otherSessionId))
        ..setWebRtc(const WebRtcConnecting(remoteSessionId: otherSessionId));
      expectStatus(console.status, RemoteTransmissionPhase.available);
      expect(console.status.remoteSessionId, otherSessionId);

      console.setWebRtc(connected(id: otherSessionId, track: 'other'));
      expectStatus(console.status, RemoteTransmissionPhase.available);
    });

    test('another session replacing the held one is a new memory', () {
      final console = Console()..presence(isOnline: false);
      expect(console.status.phase, RemoteTransmissionPhase.interrupted);

      console
        ..setSession(activeSession(otherSessionId))
        ..setDevices(devicesWith())
        ..setWebRtc(const WebRtcPreparing(remoteSessionId: otherSessionId));
      expectStatus(console.status, RemoteTransmissionPhase.available);
      expect(console.status.remoteSessionId, otherSessionId);
    });
  });
}
