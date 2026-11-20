import 'package:equatable/equatable.dart';

/// What the console can say about the tablet's screen of the assistance on
/// screen.
///
/// It is **information only**. Nothing reads it to decide whether remote
/// control is allowed: that stays `TechnicianConsoleCoordinator`'s
/// `_publishControlAuthority`, and an indicator never grants nor withdraws
/// anything.
///
/// The phases distinguish what the console *knows* from what it can only
/// *suspect*, because the tablet never says it paused its screen (there is no
/// such message in any contract): see docs/SESSION_LIFECYCLE.md, *Transmission
/// indicator*.
enum RemoteTransmissionPhase {
  /// Nothing to say: no notice on the picture. Also what an assistance that
  /// never connected in this page is, and what no assistance is.
  available,

  /// Confirmed: this browser's peer connection lost the tablet (ICE
  /// `disconnected`), or the backend reports the tablet offline — and the
  /// tablet withholds its screen the moment it loses the server.
  interrupted,

  /// The tablet answered a command `session_not_active`: on its side the
  /// assistance is not confirmed, and it withholds its screen meanwhile.
  possiblyPaused,

  /// The console cannot tell: its own socket is down (no presence, no close
  /// can reach it), or presence could not be re-read afterwards.
  unconfirmed,

  /// The signals are coming back, not all of them yet.
  recovering,

  /// The peer connection failed and no automatic attempt is left. There is
  /// no picture at all: it went with the peer connection.
  unavailable,
}

/// Why the console says what it says. Logged as a name; never shown as such.
enum RemoteTransmissionCause {
  none,

  /// `RTCPeerConnectionState.disconnected` on the current peer connection.
  peerDisconnected,

  /// `GET /devices` says the tablet of the assistance is offline.
  deviceOffline,

  /// The `/technicians` socket is not connected.
  serverUnreachable,

  /// After the socket came back, `GET /devices` or the room join failed.
  stateUnconfirmed,

  /// The tablet answered a command `session_not_active`.
  deviceRefusedCommand,

  /// The socket came back; presence and the room are being read again.
  reconnecting,

  /// The tablet is back online but has not shown it holds the assistance
  /// again: it re-enters the room only once its authority is confirmed.
  awaitingDevice,

  /// A new negotiation replaces the one that broke, and has no picture yet.
  renegotiating,

  /// `RTCPeerConnectionState.failed`, or an offer that was not relayed.
  connectionFailed,
}

final class RemoteTransmissionStatus extends Equatable {
  const RemoteTransmissionStatus({
    this.remoteSessionId,
    this.phase = RemoteTransmissionPhase.available,
    this.cause = RemoteTransmissionCause.none,
  });

  /// No assistance, or nothing to say about it.
  static const RemoteTransmissionStatus hidden = RemoteTransmissionStatus();

  /// The session this is about. A widget of another session never shows it.
  final String? remoteSessionId;

  final RemoteTransmissionPhase phase;
  final RemoteTransmissionCause cause;

  bool get isAvailable => phase == RemoteTransmissionPhase.available;

  /// Whether the notice deserves to be seen over the picture, rather than as a
  /// discreet line on top of it.
  bool get isProminent =>
      phase == RemoteTransmissionPhase.interrupted ||
      phase == RemoteTransmissionPhase.possiblyPaused ||
      phase == RemoteTransmissionPhase.unconfirmed;

  /// Whether this status is about [id] and has something to say.
  bool isNoticeFor(String id) => !isAvailable && remoteSessionId == id;

  @override
  List<Object?> get props => [remoteSessionId, phase, cause];

  @override
  String toString() => '${phase.name}/${cause.name}';
}
