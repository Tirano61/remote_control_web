import 'package:equatable/equatable.dart';

import 'normalized_remote_point.dart';

/// What a global action counts for in the tablet's queue. Not how long Android
/// takes to animate it: nothing says that, and nothing here waits for it.
const Duration remoteNavigationEstimatedWork = Duration(milliseconds: 50);

/// How long after a global action was sent the screen is assumed to be still on
/// its way somewhere else. See `RemoteNavigationGuard`.
const Duration remoteNavigationSettleDuration = Duration(milliseconds: 350);

/// The longest text the tablet takes, in UTF-16 code units: what [String.length]
/// counts in Dart, so an emoji may well count as two.
const int maxRemoteTextLength = 4096;

/// How long a text can keep the tablet's queue busy. The tablet gives up on the
/// operation after five seconds, so that is what an answer may legitimately take.
const Duration remoteSetTextEstimatedWork = Duration(seconds: 5);

/// The kinds of command the protocol defines.
enum RemoteCommandKind {
  tap,
  swipe,
  back,
  home,
  recents,
  setText;

  /// A touch on the picture.
  bool get isGesture => this == tap || this == swipe;

  /// A global action of Android.
  bool get isNavigation => this == back || this == home || this == recents;

  /// How the ids of this kind start.
  String get idPrefix => this == setText ? 'text' : name;

  /// How the log calls this kind.
  String get logName => this == setText ? 'set_text' : name;
}

/// Something the technician asks the tablet to do over the `control` channel.
///
/// Sealed on purpose: the protocol is an agreement with `remote_control_device`,
/// and a command exists here only once both sides implement it. Today that is
/// the tap, the swipe, Back, Home, Recents and the text, and nothing else.
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
