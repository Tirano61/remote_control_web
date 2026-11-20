import '../../../devices/presentation/bloc/devices/devices_bloc.dart';
import '../../../remote_control/domain/entities/remote_control_status.dart';
import '../../../technician_realtime/domain/entities/technician_realtime_status.dart';
import '../../../technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import '../../../webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';
import '../bloc/remote_session/remote_session_bloc.dart';
import '../presence/session_device_presence.dart';
import 'remote_transmission_status.dart';

/// Everything the indicator is computed from, as the console holds it now.
final class RemoteTransmissionSignals {
  const RemoteTransmissionSignals({
    required this.session,
    required this.webRtc,
    required this.realtime,
    required this.devices,
    required this.join,
  });

  final RemoteSessionState session;
  final WebRtcSessionState webRtc;
  final TechnicianRealtimeStatus realtime;
  final DevicesState devices;
  final SignalingJoinState join;
}

/// Turns what the console already knows into [RemoteTransmissionStatus].
///
/// Pure and synchronous: it reads states, it never asks for anything, sends
/// anything or changes anything. Remote control is not one of its inputs'
/// consumers: nothing here can grant or withdraw it.
///
/// The tablet never says it withholds its screen (`remote_control_device`
/// Prompt 40 drops the frames before the encoder and tells nobody), so the
/// console works from what it *can* observe:
///
/// ```text
/// confirmed   ICE disconnected / failed           this browser's peer
///             socket down                          this browser's socket
///             tablet offline                       GET /devices (backend)
///             command refused session_not_active   the tablet itself
/// evidence    the tablet entered the room          peer-joined / join ACK
///             the tablet answered a new offer      peer connection connected
///             the tablet accepted a command        ack ok
/// ```
///
/// The tablet enters the room — and answers offers, and accepts commands —
/// only with its authority confirmed, which is also exactly when it lets its
/// screen through again. Those are the only signals taken as "it is back". A
/// picture that does not change is never a signal: a still screen is a
/// legitimate screen, and no timer is involved anywhere.
///
/// Memory is per assistance: another session id starts from nothing, so no
/// notice of a previous assistance can appear on the next one. WebRTC states
/// about another session are ignored, and the WebRTC BLoC already drops the
/// callbacks of a replaced peer connection by generation.
final class RemoteTransmissionMonitor {
  String? _sessionId;

  /// A negotiation of this assistance reached `connected` + `control` open in
  /// this page. Before that there is no transmission to talk about: the
  /// existing "Conectando..." / "Esperando pantalla..." lines say it all.
  bool _hadConnection = false;

  /// Something went wrong since the transmission was last seen healthy.
  bool _isDisturbed = false;

  bool? _wasSocketConnected;
  _PresenceRead _presence = _PresenceRead.fresh;

  /// The socket came back and the room has not been joined again yet.
  bool _isJoinPending = false;

  /// The join after the socket came back was refused or failed.
  bool _hasJoinFailed = false;

  _DeviceDoubt _doubt = _DeviceDoubt.none;

  /// Evidence from the tablet since the `GET /devices` in flight started: an
  /// offline answer of that read may be older than the evidence.
  bool _hasEvidenceDuringRead = false;
  bool _wasDevicesRefreshing = false;

  WebRtcSessionState? _previousWebRtc;
  SignalingJoinState? _previousJoin;
  String? _seenCommandId;
  String? _seenTouch;

  RemoteTransmissionSignals? _lastSignals;
  RemoteTransmissionStatus _status = RemoteTransmissionStatus.hidden;

  RemoteTransmissionStatus get status => _status;

  /// Any of the inputs changed.
  RemoteTransmissionStatus observe(RemoteTransmissionSignals signals) {
    _lastSignals = signals;
    final session = signals.session;
    if (session is! RemoteSessionLive) {
      // FINALIZAR (Ending), a close, a sign-out, no assistance: nothing to
      // recover, and nothing of this one survives into the next.
      _reset(null);
      return _status = RemoteTransmissionStatus.hidden;
    }
    final id = session.session.id;
    if (id != _sessionId) _reset(id);

    // A WebRTC state about another session is never about this one.
    final WebRtcSessionState webRtc = signals.webRtc.remoteSessionId == id
        ? signals.webRtc
        : const WebRtcIdle();
    final isSocketConnected = signals.realtime.isConnected;

    _trackNegotiation(webRtc);
    _trackSocket(isSocketConnected);
    _trackPresenceRead(signals.devices, isSocketConnected);
    _trackJoin(signals.join, id, isSocketConnected);
    _trackCommands(webRtc.remoteControl);

    final device = session.session.device;
    final isDeviceOnline =
        device == null || isSessionDeviceOnline(device, signals.devices);
    if (!isDeviceOnline &&
        isSocketConnected &&
        _presence == _PresenceRead.fresh &&
        !_hasEvidenceDuringRead) {
      _doubt = _DeviceDoubt.offlineSeen;
    }

    final (phase, cause) = _derive(
      webRtc: webRtc,
      isSocketConnected: isSocketConnected,
      isDeviceOnline: isDeviceOnline,
    );
    _isDisturbed = phase != RemoteTransmissionPhase.available;
    return _status = RemoteTransmissionStatus(
      remoteSessionId: id,
      phase: phase,
      cause: cause,
    );
  }

  /// `remote-session:peer-joined`: the tablet entered the room of [id].
  RemoteTransmissionStatus peerJoined(String id) {
    if (id != _sessionId) return _status;
    _evidence();
    final signals = _lastSignals;
    return signals == null ? _status : observe(signals);
  }

  (RemoteTransmissionPhase, RemoteTransmissionCause) _derive({
    required WebRtcSessionState webRtc,
    required bool isSocketConnected,
    required bool isDeviceOnline,
  }) {
    if (!_hadConnection) return _available;

    // This browser's own peer connection: what it says is a fact.
    if (webRtc is WebRtcFailed) {
      return webRtc.isRecoveryScheduled
          ? (
              RemoteTransmissionPhase.recovering,
              RemoteTransmissionCause.connectionFailed,
            )
          : (
              RemoteTransmissionPhase.unavailable,
              RemoteTransmissionCause.connectionFailed,
            );
    }
    if (webRtc is WebRtcInterrupted) {
      return (
        RemoteTransmissionPhase.interrupted,
        RemoteTransmissionCause.peerDisconnected,
      );
    }
    // Without the socket, presence and closes cannot reach the console: it
    // cannot tell whether the tablet still has the server.
    if (!isSocketConnected) {
      return (
        RemoteTransmissionPhase.unconfirmed,
        RemoteTransmissionCause.serverUnreachable,
      );
    }
    // Socket back: not "recovered" until presence and the room were read
    // again on it.
    if (_presence == _PresenceRead.awaitingRead ||
        _presence == _PresenceRead.reading ||
        _isJoinPending) {
      return (
        RemoteTransmissionPhase.recovering,
        RemoteTransmissionCause.reconnecting,
      );
    }
    if (_presence == _PresenceRead.failed || _hasJoinFailed) {
      return (
        RemoteTransmissionPhase.unconfirmed,
        RemoteTransmissionCause.stateUnconfirmed,
      );
    }
    if (!isDeviceOnline) {
      return (
        RemoteTransmissionPhase.interrupted,
        RemoteTransmissionCause.deviceOffline,
      );
    }
    switch (_doubt) {
      case _DeviceDoubt.offlineSeen || _DeviceDoubt.notInRoom:
        return (
          RemoteTransmissionPhase.recovering,
          RemoteTransmissionCause.awaitingDevice,
        );
      case _DeviceDoubt.refusedCommand:
        return (
          RemoteTransmissionPhase.possiblyPaused,
          RemoteTransmissionCause.deviceRefusedCommand,
        );
      case _DeviceDoubt.none:
        break;
    }
    final isFlowing =
        webRtc.isConnected &&
        webRtc.isControlChannelOpen &&
        webRtc.remoteControl.isPictureDisplayed;
    if (!isFlowing && _isDisturbed) {
      return (
        RemoteTransmissionPhase.recovering,
        RemoteTransmissionCause.renegotiating,
      );
    }
    return _available;
  }

  static const (RemoteTransmissionPhase, RemoteTransmissionCause) _available = (
    RemoteTransmissionPhase.available,
    RemoteTransmissionCause.none,
  );

  void _trackNegotiation(WebRtcSessionState webRtc) {
    final previous = _previousWebRtc;
    _previousWebRtc = webRtc;
    if (webRtc.isConnected && webRtc.isControlChannelOpen) {
      _hadConnection = true;
    }
    // A new negotiation reached `connected`: the tablet answered its offer,
    // which it does only with its authority confirmed. ICE coming back on
    // the same peer connection (interrupted -> connected) is not that.
    if (webRtc is WebRtcConnected &&
        (previous is WebRtcPreparing ||
            previous is WebRtcOffering ||
            previous is WebRtcConnecting)) {
      _evidence();
    }
  }

  void _trackSocket(bool isConnected) {
    final was = _wasSocketConnected;
    _wasSocketConnected = isConnected;
    if (was == null || was == isConnected) return;
    if (!isConnected) {
      // Nothing heard from now on: presence and the room are to be read again.
      _presence = _PresenceRead.awaitingSocket;
      _isJoinPending = true;
      _hasJoinFailed = false;
      return;
    }
    if (_presence == _PresenceRead.awaitingSocket) {
      _presence = _PresenceRead.awaitingRead;
    }
  }

  /// `GET /devices` after the socket came back. The coordinator asks for it on
  /// every reconnection; [DevicesBloc] serialises its reads, so the first read
  /// that ends without another one behind it started after the reconnection.
  void _trackPresenceRead(DevicesState devices, bool isSocketConnected) {
    final isRefreshing =
        devices is DevicesLoading ||
        (devices is DevicesLoaded && devices.isRefreshing);
    if (isRefreshing && !_wasDevicesRefreshing) _hasEvidenceDuringRead = false;
    _wasDevicesRefreshing = isRefreshing;

    if (!isSocketConnected) return;
    switch (_presence) {
      case _PresenceRead.fresh || _PresenceRead.awaitingSocket:
        return;
      case _PresenceRead.awaitingRead:
        if (isRefreshing) _presence = _PresenceRead.reading;
      case _PresenceRead.reading || _PresenceRead.failed:
        if (isRefreshing) {
          _presence = _PresenceRead.reading;
        } else if (devices is DevicesLoaded && devices.refreshFailure == null) {
          _presence = _PresenceRead.fresh;
        } else if (_presence == _PresenceRead.reading) {
          _presence = _PresenceRead.failed;
        }
    }
  }

  void _trackJoin(SignalingJoinState join, String id, bool isSocketConnected) {
    final previous = _previousJoin;
    _previousJoin = join;
    if (!isSocketConnected) return;

    if (join is SignalingJoined && join.remoteSessionId == id) {
      final hadPeer =
          previous is SignalingJoined &&
          previous.remoteSessionId == id &&
          previous.peerJoined;
      // The first join on the connection that came back, or the one that
      // finally got through after a refused one.
      if (_isJoinPending || _hasJoinFailed) {
        _isJoinPending = false;
        _hasJoinFailed = false;
        // The ACK of this new connection says whether the tablet is in the
        // room right now. Not in it: it lost its own server too, and lets its
        // screen through only once it is back and has rejoined.
        if (join.peerJoined) {
          _evidence();
        } else if (_doubt == _DeviceDoubt.none) {
          _doubt = _DeviceDoubt.notInRoom;
        }
      } else if (join.peerJoined && !hadPeer) {
        _evidence();
      }
      return;
    }
    if (join is SignalingUnavailable &&
        join.remoteSessionId == id &&
        _isJoinPending) {
      _isJoinPending = false;
      _hasJoinFailed = true;
    }
  }

  void _trackCommands(RemoteControlStatus control) {
    final command = control.lastCommand;
    if (command != null &&
        command.commandId != _seenCommandId &&
        command.outcome != RemoteCommandOutcome.pending) {
      _seenCommandId = command.commandId;
      _onAnswer(command.outcome);
    }
    final touch = control.lastTouch;
    if (touch == null) return;
    final key = '${touch.touchId}:${touch.phase.name}';
    if (key == _seenTouch) return;
    _seenTouch = key;
    switch (touch.phase) {
      case RemoteTouchPhase.held || RemoteTouchPhase.released:
        _onAnswer(RemoteCommandOutcome.confirmed);
      case RemoteTouchPhase.failed:
        final failure = touch.failure;
        if (failure != null) _onAnswer(failure);
      case RemoteTouchPhase.holding ||
          RemoteTouchPhase.dragging ||
          RemoteTouchPhase.releasing ||
          RemoteTouchPhase.cancelling ||
          RemoteTouchPhase.cancelled:
        break;
    }
  }

  void _onAnswer(RemoteCommandOutcome outcome) {
    if (outcome == RemoteCommandOutcome.confirmed) {
      _evidence();
    } else if (outcome == RemoteCommandOutcome.sessionNotActive &&
        _doubt == _DeviceDoubt.none) {
      _doubt = _DeviceDoubt.refusedCommand;
    }
  }

  /// The tablet showed it holds the assistance again.
  void _evidence() {
    _doubt = _DeviceDoubt.none;
    _hasEvidenceDuringRead = true;
  }

  void _reset(String? id) {
    _sessionId = id;
    _hadConnection = false;
    _isDisturbed = false;
    _wasSocketConnected = null;
    _presence = _PresenceRead.fresh;
    _isJoinPending = false;
    _hasJoinFailed = false;
    _doubt = _DeviceDoubt.none;
    _hasEvidenceDuringRead = false;
    _wasDevicesRefreshing = false;
    _previousWebRtc = null;
    _previousJoin = null;
    _seenCommandId = null;
    _seenTouch = null;
  }
}

enum _PresenceRead {
  /// The list is what the backend said after the socket last came back.
  fresh,

  /// The socket is down: nothing the list says can be trusted any more.
  awaitingSocket,

  /// The socket is back; the read it asks for has not started.
  awaitingRead,
  reading,
  failed,
}

enum _DeviceDoubt { none, offlineSeen, notInRoom, refusedCommand }
