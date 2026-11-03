import 'package:equatable/equatable.dart';

import 'normalized_remote_point.dart';

/// What a global action counts for in the tablet's queue. Not how long Android
/// takes to animate it: nothing says that, and nothing here waits for it.
const Duration remoteNavigationEstimatedWork = Duration(milliseconds: 50);

/// How long after a global action was sent the screen is assumed to be still on
/// its way somewhere else. See `RemoteNavigationGuard`.
const Duration remoteNavigationSettleDuration = Duration(milliseconds: 350);

/// The kinds of command the protocol defines.
enum RemoteCommandKind {
  tap,
  swipe,
  back,
  home,
  recents;

  /// A global action of Android, as opposed to a touch on the picture.
  bool get isNavigation => this != tap && this != swipe;
}

/// Something the technician asks the tablet to do over the `control` channel.
///
/// Sealed on purpose: the protocol is an agreement with `remote_control_device`,
/// and a command exists here only once both sides implement it. Today that is
/// the tap, the swipe, Back, Home and Recents, and nothing else.
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
