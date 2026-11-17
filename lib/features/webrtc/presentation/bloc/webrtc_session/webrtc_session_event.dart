part of 'webrtc_session_bloc.dart';

sealed class WebRtcSessionEvent extends Equatable {
  const WebRtcSessionEvent();

  @override
  List<Object?> get props => const [];
}

/// Everything a negotiation needs is true: there is a live `RemoteSession`,
/// this socket is inside its signaling room, and the tablet is in it too.
///
/// The console raises it whenever that combination becomes true again — a
/// reconnection, a new assistance — and the BLoC decides whether it means a
/// new peer connection or nothing at all.
final class WebRtcNegotiationRequested extends WebRtcSessionEvent {
  const WebRtcNegotiationRequested(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The signaling room was lost: the socket dropped, the join expired, or the
/// backend refused a relay.
///
/// It does **not** mean the peer connection is dead. A connected one is kept:
/// WebRTC is peer to peer and does not need Socket.IO any more.
final class WebRtcSignalingLost extends WebRtcSessionEvent {
  const WebRtcSignalingLost();
}

/// The assistance is over: closed from here, closed by the tablet, or the user
/// signed out. Everything WebRTC holds is released.
final class WebRtcSessionTerminated extends WebRtcSessionEvent {
  const WebRtcSessionTerminated();
}

/// The technician clicked on the picture of the tablet.
///
/// Carries the session the picture belonged to, so that a click can never land
/// on a session other than the one it was aimed at.
final class WebRtcRemoteTapRequested extends WebRtcSessionEvent {
  const WebRtcRemoteTapRequested({
    required this.remoteSessionId,
    required this.point,
  });

  final String remoteSessionId;
  final NormalizedRemotePoint point;

  @override
  List<Object?> get props => [remoteSessionId, point];
}

/// The technician dragged across the picture of the tablet and let go.
///
/// Like a click, it carries the session the picture belonged to.
final class WebRtcRemoteSwipeRequested extends WebRtcSessionEvent {
  const WebRtcRemoteSwipeRequested({
    required this.remoteSessionId,
    required this.start,
    required this.end,
    required this.durationMs,
  });

  final String remoteSessionId;
  final NormalizedRemotePoint start;
  final NormalizedRemotePoint end;
  final int durationMs;

  @override
  List<Object?> get props => [remoteSessionId, start, end, durationMs];
}

/// The technician held the pointer still on the picture of the tablet for as long
/// as a long press takes to be recognised. Sent once, while the pointer is still
/// down: nothing that pointer does afterwards adds to it.
///
/// Like a click, it carries the session the picture belonged to, and the point
/// where the press started.
final class WebRtcRemoteLongPressRequested extends WebRtcSessionEvent {
  const WebRtcRemoteLongPressRequested({
    required this.remoteSessionId,
    required this.point,
  });

  final String remoteSessionId;
  final NormalizedRemotePoint point;

  @override
  List<Object?> get props => [remoteSessionId, point];
}

/// The technician held the pointer still on the picture for as long as a long
/// press takes to be recognised, and it is still down: the start of a remote
/// touch that the same [pointer] goes on with.
///
/// What it becomes is decided here, not by the surface: a `touch_hold`, or the
/// legacy `long_press` on a tablet that said it does not run touch sessions.
/// [point] is where the press started.
final class WebRtcRemoteTouchHoldRequested extends WebRtcSessionEvent {
  const WebRtcRemoteTouchHoldRequested({
    required this.remoteSessionId,
    required this.pointer,
    required this.point,
  });

  final String remoteSessionId;

  /// The console's pointer, which every later event of this touch names.
  final int pointer;
  final NormalizedRemotePoint point;

  @override
  List<Object?> get props => [remoteSessionId, pointer, point];
}

/// The pointer of a held touch is at [point] now, clamped to the picture.
///
/// Raised for every move of the pointer: which of them reach the tablet, and
/// when, is the touch session's decision.
final class WebRtcRemoteTouchMoved extends WebRtcSessionEvent {
  const WebRtcRemoteTouchMoved({
    required this.remoteSessionId,
    required this.pointer,
    required this.point,
  });

  final String remoteSessionId;
  final int pointer;
  final NormalizedRemotePoint point;

  @override
  List<Object?> get props => [remoteSessionId, pointer, point];
}

/// The pointer of a held touch went up at [point], clamped to the picture.
final class WebRtcRemoteTouchReleased extends WebRtcSessionEvent {
  const WebRtcRemoteTouchReleased({
    required this.remoteSessionId,
    required this.pointer,
    required this.point,
  });

  final String remoteSessionId;
  final int pointer;
  final NormalizedRemotePoint point;

  @override
  List<Object?> get props => [remoteSessionId, pointer, point];
}

/// The held touch of [pointer] can no longer go on: the browser cancelled the
/// pointer, a second one went down, the wheel turned, the geometry changed or
/// the surface went away. Nothing is dropped: the finger is taken away.
final class WebRtcRemoteTouchCancelled extends WebRtcSessionEvent {
  const WebRtcRemoteTouchCancelled({
    required this.remoteSessionId,
    required this.pointer,
  });

  final String remoteSessionId;
  final int pointer;

  @override
  List<Object?> get props => [remoteSessionId, pointer];
}

/// The technician pressed Atrás.
///
/// Like a click, it carries the session it was aimed at. Unlike a click, it needs
/// no picture.
final class WebRtcRemoteBackRequested extends WebRtcSessionEvent {
  const WebRtcRemoteBackRequested({required this.remoteSessionId});

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The technician pressed Inicio. See [WebRtcRemoteBackRequested].
final class WebRtcRemoteHomeRequested extends WebRtcSessionEvent {
  const WebRtcRemoteHomeRequested({required this.remoteSessionId});

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The technician pressed Recientes. See [WebRtcRemoteBackRequested].
final class WebRtcRemoteRecentsRequested extends WebRtcSessionEvent {
  const WebRtcRemoteRecentsRequested({required this.remoteSessionId});

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The technician explicitly sent a text from the dialog: to the field they saw
/// focused on the picture, replacing its whole content. An empty [text] empties it.
///
/// It may be a password. Nothing keeps this event, and it does not print its text.
final class WebRtcRemoteTextRequested extends WebRtcSessionEvent {
  const WebRtcRemoteTextRequested({
    required this.remoteSessionId,
    required this.text,
  });

  final String remoteSessionId;
  final String text;

  @override
  List<Object?> get props => [remoteSessionId, text];

  @override
  String toString() => 'WebRtcRemoteTextRequested($remoteSessionId)';
}

/// The technician pressed Acción: run the IME action of the field they saw
/// focused on the picture, whatever that action is.
///
/// Only ever raised by that button. Neither a tap on a field nor a text that went
/// out raises it.
final class WebRtcRemoteImeEnterRequested extends WebRtcSessionEvent {
  const WebRtcRemoteImeEnterRequested({required this.remoteSessionId});

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The surface started or stopped really displaying the tablet's screen.
///
/// Only the surface can tell: the BLoC knows there is a track, and a track exists
/// well before its first frame. Carries the session the surface belongs to, so that
/// a surface going away says nothing about the session after it.
final class WebRtcRemotePictureChanged extends WebRtcSessionEvent {
  const WebRtcRemotePictureChanged({
    required this.remoteSessionId,
    required this.isDisplayed,
  });

  final String remoteSessionId;
  final bool isDisplayed;

  @override
  List<Object?> get props => [remoteSessionId, isDisplayed];
}

/// Which session REST currently says is `ACTIVE` and not being closed, if any.
///
/// The BLoC only learns this from outside: `RemoteSession` is not its state, and
/// WebRTC being connected says nothing about it.
final class WebRtcRemoteSessionActivityChanged extends WebRtcSessionEvent {
  const WebRtcRemoteSessionActivityChanged(this.activeRemoteSessionId);

  final String? activeRemoteSessionId;

  @override
  List<Object?> get props => [activeRemoteSessionId];
}

/// A command ran out of time. Internal.
final class _WebRtcRemoteCommandTimedOut extends WebRtcSessionEvent {
  const _WebRtcRemoteCommandTimedOut(this.commandId, this.generation);

  final String commandId;
  final int generation;

  @override
  List<Object?> get props => [commandId, generation];
}

/// A timer of a touch session went off. Internal.
final class _WebRtcRemoteTouchTimerFired extends WebRtcSessionEvent {
  const _WebRtcRemoteTouchTimerFired(this.touchId, this.generation, this.timer);

  final String touchId;
  final int generation;
  final RemoteTouchTimer timer;

  @override
  List<Object?> get props => [touchId, generation, timer];
}

/// The settle time of a global action or an IME action has passed. Internal.
final class _WebRtcRemoteActionSettled extends WebRtcSessionEvent {
  const _WebRtcRemoteActionSettled(this.commandId, this.generation);

  final String commandId;
  final int generation;

  @override
  List<Object?> get props => [commandId, generation];
}

/// The peer connection reported something. Internal: only the BLoC raises it.
final class _WebRtcPeerReported extends WebRtcSessionEvent {
  const _WebRtcPeerReported(this.event, this.generation);

  final WebRtcPeerEvent event;

  /// The negotiation this callback belongs to. A late callback from a closed
  /// peer connection must never touch the current one.
  final int generation;

  @override
  List<Object?> get props => [event, generation];
}

/// A `webrtc:*` message was relayed to this technician. Internal.
final class _WebRtcSignalingReported extends WebRtcSessionEvent {
  const _WebRtcSignalingReported(this.message);

  final RemoteSignalingMessage message;

  @override
  List<Object?> get props => [message];
}
