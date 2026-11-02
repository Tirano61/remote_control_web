import 'package:equatable/equatable.dart';

import 'normalized_remote_point.dart';

/// Something the technician asks the tablet to do over the `control` channel.
///
/// Sealed on purpose: the protocol is an agreement with `remote_control_device`,
/// and a command exists here only once both sides implement it. Today that is
/// the tap and nothing else.
sealed class RemoteControlCommand extends Equatable {
  const RemoteControlCommand({required this.id});

  /// Chosen by this side and opaque to the device, which only echoes it in its
  /// acknowledgement. It never carries coordinates or screen content.
  final String id;
}

/// A single touch at [point].
final class RemoteTapCommand extends RemoteControlCommand {
  const RemoteTapCommand({required super.id, required this.point});

  final NormalizedRemotePoint point;

  @override
  List<Object?> get props => [id, point];

  /// The id only: coordinates are not logged.
  @override
  String toString() => 'RemoteTapCommand($id)';
}
