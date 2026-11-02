import 'package:equatable/equatable.dart';

import '../entities/normalized_remote_point.dart';

/// Where the picture really is inside its container, in the container's
/// coordinates.
final class RemoteVideoContentRect extends Equatable {
  const RemoteVideoContentRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  @override
  List<Object?> get props => [left, top, width, height];
}

/// From a position on the console to a position on the tablet.
///
/// The picture is drawn with `contain`, so the container may hold empty bands
/// around it. The coordinates the tablet understands are relative to the frame,
/// not to the container, and a click on a band is not a touch on anything.
///
/// Everything is computed from the values passed in, with nothing kept between
/// calls: a rotation changes the aspect ratio and the next click simply uses it.
class RemoteVideoGeometry {
  const RemoteVideoGeometry._();

  /// How far outside the picture a pointer may be and still count as being on
  /// its edge, in logical pixels.
  ///
  /// Only there for rounding: computing the rectangle of a video that exactly
  /// fills its container can put the edge at `1e-14`. It is many orders of
  /// magnitude below anything a pointer can do, so no click on a band gets in.
  static const double _edgeTolerance = 1e-6;

  /// The rectangle `contain` draws the video in, or `null` if the values
  /// describe no picture.
  static RemoteVideoContentRect? containRect({
    required double containerWidth,
    required double containerHeight,
    required double videoAspectRatio,
  }) {
    if (!_isPositiveAndFinite(containerWidth) ||
        !_isPositiveAndFinite(containerHeight) ||
        !_isPositiveAndFinite(videoAspectRatio)) {
      return null;
    }

    if (videoAspectRatio > containerWidth / containerHeight) {
      // Proportionally wider: full width, bands above and below.
      final renderedHeight = containerWidth / videoAspectRatio;
      return RemoteVideoContentRect(
        left: 0,
        top: (containerHeight - renderedHeight) / 2,
        width: containerWidth,
        height: renderedHeight,
      );
    }

    // Proportionally taller, or the same: full height, bands at the sides.
    final renderedWidth = containerHeight * videoAspectRatio;
    return RemoteVideoContentRect(
      left: (containerWidth - renderedWidth) / 2,
      top: 0,
      width: renderedWidth,
      height: containerHeight,
    );
  }

  /// The position on the tablet under a pointer, or `null` when the pointer is
  /// not on the picture.
  ///
  /// Not mirrored: the renderer draws with `mirror = false`, so X is not
  /// inverted. A band is never moved to the nearest edge: the only clamp here
  /// absorbs rounding, after the pointer was found to be on the picture.
  static NormalizedRemotePoint? normalize({
    required double pointerX,
    required double pointerY,
    required double containerWidth,
    required double containerHeight,
    required double videoAspectRatio,
  }) {
    if (!pointerX.isFinite || !pointerY.isFinite) return null;

    final rect = containRect(
      containerWidth: containerWidth,
      containerHeight: containerHeight,
      videoAspectRatio: videoAspectRatio,
    );
    if (rect == null) return null;

    final videoX = pointerX - rect.left;
    final videoY = pointerY - rect.top;
    if (videoX < -_edgeTolerance ||
        videoY < -_edgeTolerance ||
        videoX > rect.width + _edgeTolerance ||
        videoY > rect.height + _edgeTolerance) {
      return null;
    }

    return NormalizedRemotePoint(
      (videoX / rect.width).clamp(0.0, 1.0),
      (videoY / rect.height).clamp(0.0, 1.0),
    );
  }

  static bool _isPositiveAndFinite(double value) => value.isFinite && value > 0;
}
