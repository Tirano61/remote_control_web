import 'package:equatable/equatable.dart';

import 'normalized_remote_point.dart';

/// The kinds of command the protocol defines.
enum RemoteCommandKind { tap, swipe }

/// Something the technician asks the tablet to do over the `control` channel.
///
/// Sealed on purpose: the protocol is an agreement with `remote_control_device`,
/// and a command exists here only once both sides implement it. Today that is
/// the tap and the swipe, and nothing else.
sealed class RemoteControlCommand extends Equatable {
  const RemoteControlCommand({required this.id});

  /// Chosen by this side and opaque to the device, which only echoes it in its
  /// acknowledgement. It never carries coordinates or screen content.
  final String id;

  RemoteCommandKind get kind;

  /// How long the gesture keeps the tablet's queue busy once it starts: what any
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
