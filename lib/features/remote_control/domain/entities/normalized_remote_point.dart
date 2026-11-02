import 'package:equatable/equatable.dart';

/// A position on the tablet's screen, independent of any resolution.
///
/// ```text
/// origin  top-left of the remote frame
/// x       0.0 .. 1.0, grows right
/// y       0.0 .. 1.0, grows down
/// ```
///
/// Android turns it into a pixel with the geometry of its display at the moment
/// the command runs, so nothing here knows about orientation or size.
final class NormalizedRemotePoint extends Equatable {
  const NormalizedRemotePoint(this.x, this.y)
    : assert(x >= 0 && x <= 1),
      assert(y >= 0 && y <= 1);

  final double x;
  final double y;

  @override
  List<Object?> get props => [x, y];
}
