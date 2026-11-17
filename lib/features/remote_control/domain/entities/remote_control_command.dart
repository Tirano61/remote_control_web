import 'package:equatable/equatable.dart';

import 'normalized_remote_point.dart';

/// What a global action counts for in the tablet's queue. Not how long Android
/// takes to animate it: nothing says that, and nothing here waits for it.
const Duration remoteNavigationEstimatedWork = Duration(milliseconds: 50);

/// How long after a global action or an IME action was sent the screen is assumed
/// to be still on its way somewhere else. See `RemoteSettleGuard`.
const Duration remoteSettleDuration = Duration(milliseconds: 350);

/// The longest text the tablet takes, in UTF-16 code units: what [String.length]
/// counts in Dart, so an emoji may well count as two.
const int maxRemoteTextLength = 4096;

/// How long a text can keep the tablet's queue busy. The tablet gives up on the
/// operation after five seconds, so that is what an answer may legitimately take.
const Duration remoteSetTextEstimatedWork = Duration(seconds: 5);

/// How long an IME action can keep the tablet's queue busy. It goes through the
/// same accessibility bridge as a text, which gives up after the same five seconds.
const Duration remoteImeEnterEstimatedWork = Duration(seconds: 5);

/// How long a long press can keep the tablet's queue busy. The web never says how
/// long it lasts: the tablet holds it for Android's own long press timeout plus a
/// margin, and gives up on a gesture after five seconds, so that is what an answer
/// may legitimately take.
const Duration remoteLongPressEstimatedWork = Duration(seconds: 5);

/// How long the tablet may take to answer a `touch_hold`, a `touch_release` or a
/// `touch_cancel`. The hold is answered once Android's long press timeout has
/// passed, and a release or a cancel sent during the hold waits for it: the same
/// five seconds as a long press.
const Duration remoteTouchEstimatedWork = Duration(seconds: 5);

/// What one moving stroke of a touch lasts at most on the tablet.
const Duration remoteTouchMoveEstimatedWork = Duration(milliseconds: 100);

/// The kinds of command the protocol defines.
enum RemoteCommandKind {
  tap,
  swipe,
  longPress,
  back,
  home,
  recents,
  setText,
  imeEnter,
  touchHold,
  touchMove,
  touchRelease,
  touchCancel;

  /// A touch on the picture.
  bool get isGesture =>
      this == tap || this == swipe || this == longPress || isTouchMessage;

  /// One message of a touch session: see `RemoteTouchSession`.
  bool get isTouchMessage =>
      this == touchHold ||
      this == touchMove ||
      this == touchRelease ||
      this == touchCancel;

  /// A global action of Android.
  bool get isNavigation => this == back || this == home || this == recents;

  /// What may move the screen somewhere else after Android accepted it, so that
  /// nothing else goes out until it had time to: see `RemoteSettleGuard`. A long
  /// press may open a menu, a selection or a popup, and so may lifting the finger
  /// of a touch: a drop, or the end of a long press. A `touch_hold` does not: the
  /// finger is still down, and the touch goes on.
  bool get settlesScreen =>
      isNavigation ||
      this == imeEnter ||
      this == longPress ||
      this == touchRelease;

  /// How the ids of this kind start.
  String get idPrefix => switch (this) {
    longPress => 'long',
    setText => 'text',
    imeEnter => 'enter',
    touchHold => 'hold',
    touchMove => 'mv',
    touchRelease => 'rel',
    touchCancel => 'cxl',
    _ => name,
  };

  /// How the log calls this kind.
  String get logName => switch (this) {
    longPress => 'long_press',
    setText => 'set_text',
    imeEnter => 'ime_enter',
    touchHold => 'touch_hold',
    touchMove => 'touch_move',
    touchRelease => 'touch_release',
    touchCancel => 'touch_cancel',
    _ => name,
  };
}

/// Something the technician asks the tablet to do over the `control` channel.
///
/// Sealed on purpose: the protocol is an agreement with `remote_control_device`,
/// and a command exists here only once both sides implement it. Today that is
/// the tap, the swipe, the long press, Back, Home, Recents, the text, the IME
/// action and the four messages of a touch session, and nothing else.
sealed class RemoteControlCommand extends Equatable {
  const RemoteControlCommand({required this.id});

  /// Chosen by this side and opaque to the device, which only echoes it in its
  /// acknowledgement. It never carries coordinates or screen content.
  final String id;

  RemoteCommandKind get kind;

  /// How long the command keeps the tablet's queue busy once it starts: what any
  /// command sent after this one has to wait for.
  Duration get estimatedWork;
}

/// A single touch at [point].
final class RemoteTapCommand extends RemoteControlCommand {
  const RemoteTapCommand({required super.id, required this.point});

  /// What Android holds a tap for. It is the device's own constant and is not
  /// part of the frame.
  static const Duration gestureDuration = Duration(milliseconds: 50);

  final NormalizedRemotePoint point;

  @override
  RemoteCommandKind get kind => RemoteCommandKind.tap;

  @override
  Duration get estimatedWork => gestureDuration;

  @override
  List<Object?> get props => [id, point];

  /// The id only: coordinates are not logged.
  @override
  String toString() => 'RemoteTapCommand($id)';
}

/// One straight stroke from [start] to a different [end], lasting [durationMs].
final class RemoteSwipeCommand extends RemoteControlCommand {
  // Not const: comparing two points is not something a constant can do, and the
  // contract says start and end differ.
  // ignore: prefer_const_constructors_in_immutables
  RemoteSwipeCommand({
    required super.id,
    required this.start,
    required this.end,
    required this.durationMs,
  }) : assert(start != end),
       assert(durationMs >= minDurationMs && durationMs <= maxDurationMs);

  /// The range the tablet executes. Anything else is `invalid_command` there.
  static const int minDurationMs = 50;
  static const int maxDurationMs = 2000;

  /// The duration to send for a stroke that really took [elapsed].
  ///
  /// Clamped, unlike a coordinate: moving a coordinate would touch somewhere the
  /// technician did not aim at, while a duration outside the range only says the
  /// stroke was faster or slower than the tablet can reproduce.
  static int durationMsFor(Duration elapsed) =>
      elapsed.inMilliseconds.clamp(minDurationMs, maxDurationMs);

  final NormalizedRemotePoint start;
  final NormalizedRemotePoint end;
  final int durationMs;

  @override
  RemoteCommandKind get kind => RemoteCommandKind.swipe;

  @override
  Duration get estimatedWork => Duration(milliseconds: durationMs);

  @override
  List<Object?> get props => [id, start, end, durationMs];

  /// The id only: coordinates are not logged.
  @override
  String toString() => 'RemoteSwipeCommand($id)';
}

/// A touch held still at [point], for as long as the tablet decides.
///
/// The web decides *when* the technician means a long press; the tablet decides
/// *how long* Android holds it (its own long press timeout plus a margin). No
/// duration goes on the wire.
final class RemoteLongPressCommand extends RemoteControlCommand {
  const RemoteLongPressCommand({required super.id, required this.point});

  final NormalizedRemotePoint point;

  @override
  RemoteCommandKind get kind => RemoteCommandKind.longPress;

  @override
  Duration get estimatedWork => remoteLongPressEstimatedWork;

  @override
  List<Object?> get props => [id, point];

  /// The id only: coordinates are not logged.
  @override
  String toString() => 'RemoteLongPressCommand($id)';
}

/// A global action of Android: nothing but its id goes on the wire.
///
/// Not a touch at some corner of the screen, so it needs no picture to have been
/// aimed at. That is the whole difference with a tap or a swipe, and why it can
/// be used while the tablet shares no screen.
sealed class RemoteNavigationCommand extends RemoteControlCommand {
  const RemoteNavigationCommand({required super.id});

  @override
  Duration get estimatedWork => remoteNavigationEstimatedWork;

  @override
  List<Object?> get props => [id];
}

/// Android's Back.
final class RemoteBackCommand extends RemoteNavigationCommand {
  const RemoteBackCommand({required super.id});

  @override
  RemoteCommandKind get kind => RemoteCommandKind.back;

  @override
  String toString() => 'RemoteBackCommand($id)';
}

/// Android's Home.
final class RemoteHomeCommand extends RemoteNavigationCommand {
  const RemoteHomeCommand({required super.id});

  @override
  RemoteCommandKind get kind => RemoteCommandKind.home;

  @override
  String toString() => 'RemoteHomeCommand($id)';
}

/// Android's overview of recent apps.
final class RemoteRecentsCommand extends RemoteNavigationCommand {
  const RemoteRecentsCommand({required super.id});

  @override
  RemoteCommandKind get kind => RemoteCommandKind.recents;

  @override
  String toString() => 'RemoteRecentsCommand($id)';
}

/// Replaces the whole content of whichever field has input focus on the tablet.
///
/// [text] is sent exactly as it was written: never trimmed, normalized or cut.
/// It may be a password, so this object must not outlive the send: what stays
/// behind while the answer is awaited is `PendingRemoteCommand`, which has no
/// text. The text is also the one thing here that never gets printed.
final class RemoteSetTextCommand extends RemoteControlCommand {
  const RemoteSetTextCommand({required super.id, required this.text})
    : assert(text.length <= maxRemoteTextLength);

  /// Whether the tablet would take [text]. Anything longer is `invalid_command`
  /// there, and is refused here rather than cut.
  static bool fits(String text) => text.length <= maxRemoteTextLength;

  final String text;

  @override
  RemoteCommandKind get kind => RemoteCommandKind.setText;

  @override
  Duration get estimatedWork => remoteSetTextEstimatedWork;

  @override
  List<Object?> get props => [id, text];

  /// The id only: the text is not logged, whatever it holds.
  @override
  String toString() => 'RemoteSetTextCommand($id)';
}

/// Runs the IME action of whichever field has input focus on the tablet.
///
/// Not "press Enter": no key is simulated and nothing is written. The field runs
/// the action it declares for the keyboard's action key, which may be Search, Go,
/// Next, Send, Done or something of the application's own. Which one is not known
/// here and is not asked: the frame carries the id and nothing else.
final class RemoteImeEnterCommand extends RemoteControlCommand {
  const RemoteImeEnterCommand({required super.id});

  @override
  RemoteCommandKind get kind => RemoteCommandKind.imeEnter;

  @override
  Duration get estimatedWork => remoteImeEnterEstimatedWork;

  @override
  List<Object?> get props => [id];

  @override
  String toString() => 'RemoteImeEnterCommand($id)';
}

/// Puts a finger down at [point] on the tablet and keeps it down past Android's
/// long press timeout: the start of a touch session named [touch].
///
/// It is the touch's `seq` 0, and carries none. Its `ok` only says the finger is
/// still down, has been down long enough for Android to read a long press, and
/// the touch goes on: never that anything was picked up.
final class RemoteTouchHoldCommand extends RemoteControlCommand {
  const RemoteTouchHoldCommand({
    required super.id,
    required this.touch,
    required this.point,
  });

  /// Names the finger, and is shared by every message about it. Opaque to the
  /// tablet, and meaningless outside this peer connection.
  final String touch;

  /// Where the press started, as it was recognised: not wherever the pointer
  /// drifted, by less than the drag threshold, while it was being held.
  final NormalizedRemotePoint point;

  @override
  RemoteCommandKind get kind => RemoteCommandKind.touchHold;

  @override
  Duration get estimatedWork => remoteTouchEstimatedWork;

  @override
  List<Object?> get props => [id, touch, point];

  /// The ids only: coordinates are not logged.
  @override
  String toString() => 'RemoteTouchHoldCommand($id, $touch)';
}

/// Moves the finger of [touch] to [point] without lifting it.
///
/// Also what a keepalive is: the same position again, which moves nothing on the
/// tablet and tells it the sender is still there. A move that is taken is never
/// answered; one that is not is answered with its own [id].
final class RemoteTouchMoveCommand extends RemoteControlCommand {
  const RemoteTouchMoveCommand({
    required super.id,
    required this.touch,
    required this.seq,
    required this.point,
  }) : assert(seq >= 1);

  final String touch;

  /// Greater than any `seq` sent before for [touch].
  final int seq;

  final NormalizedRemotePoint point;

  @override
  RemoteCommandKind get kind => RemoteCommandKind.touchMove;

  @override
  Duration get estimatedWork => remoteTouchMoveEstimatedWork;

  @override
  List<Object?> get props => [id, touch, seq, point];

  /// The ids only: coordinates are not logged.
  @override
  String toString() => 'RemoteTouchMoveCommand($id, $touch, seq $seq)';
}

/// Lifts the finger of [touch] at [point]. Its `ok` says Android received the end
/// of the contact: not that anything was dropped, or dropped where it was aimed.
final class RemoteTouchReleaseCommand extends RemoteControlCommand {
  const RemoteTouchReleaseCommand({
    required super.id,
    required this.touch,
    required this.seq,
    required this.point,
  }) : assert(seq >= 1);

  final String touch;
  final int seq;
  final NormalizedRemotePoint point;

  @override
  RemoteCommandKind get kind => RemoteCommandKind.touchRelease;

  @override
  Duration get estimatedWork => remoteTouchEstimatedWork;

  @override
  List<Object?> get props => [id, touch, seq, point];

  /// The ids only: coordinates are not logged.
  @override
  String toString() => 'RemoteTouchReleaseCommand($id, $touch, seq $seq)';
}

/// Takes the finger of [touch] away without lifting it: Android sees a cancel,
/// never an up, so nothing being dragged is dropped. No coordinates.
final class RemoteTouchCancelCommand extends RemoteControlCommand {
  const RemoteTouchCancelCommand({
    required super.id,
    required this.touch,
    required this.seq,
  }) : assert(seq >= 1);

  final String touch;
  final int seq;

  @override
  RemoteCommandKind get kind => RemoteCommandKind.touchCancel;

  @override
  Duration get estimatedWork => remoteTouchEstimatedWork;

  @override
  List<Object?> get props => [id, touch, seq];

  @override
  String toString() => 'RemoteTouchCancelCommand($id, $touch, seq $seq)';
}
