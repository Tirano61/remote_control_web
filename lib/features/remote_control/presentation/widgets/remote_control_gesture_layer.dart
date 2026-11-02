import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../domain/entities/normalized_remote_point.dart';
import '../../domain/entities/remote_control_command.dart';
import '../../domain/geometry/remote_video_geometry.dart';

/// See [RemoteControlGestureLayer.onSwipe].
typedef RemoteSwipeCallback =
    void Function({
      required NormalizedRemotePoint start,
      required NormalizedRemotePoint end,
      required int durationMs,
    });

/// Turns what the pointer does over the picture of the tablet into one gesture
/// on the tablet, reported when the pointer goes up and never before.
///
/// ```text
/// down        on the picture, primary button: the press starts
/// move        beyond the threshold it is a drag from then on
/// up, no drag a tap
/// up, drag    a swipe from where it was pressed to where it was released
/// ```
///
/// It covers the whole video surface and only reacts over the picture itself:
/// a band left by `contain` is not anything on the tablet. A press that started
/// on one is never picked up, and a press that reaches one is dropped for good,
/// even if the pointer comes back: both ends of a stroke must be points the
/// technician really aimed at, and the path between them is not sent.
///
/// The aspect ratio is read at every pointer event and never carried over to the
/// next gesture, so the first one after a rotation already uses the new geometry.
/// One that changes during a press drops the press: its two ends would belong to
/// different screens.
///
/// Raw pointer events, because the two ends and the time between them are the
/// gesture. They keep arriving here when the pointer leaves the widget, for as
/// long as it stays down, so no capture of any kind is needed.
class RemoteControlGestureLayer extends StatefulWidget {
  const RemoteControlGestureLayer({
    required this.videoAspectRatio,
    required this.onTap,
    required this.onSwipe,
    super.key,
  });

  /// How far the pointer has to travel to be a drag and not a shaky click, in
  /// logical pixels of this surface: the tablet's resolution says nothing about
  /// what the technician meant. Exactly this far is already a drag.
  static const double dragThreshold = 6;

  /// The aspect ratio of the picture right now, or `null` while there is none.
  final double? Function() videoAspectRatio;

  final ValueChanged<NormalizedRemotePoint> onTap;

  /// Called with both ends of a drag and how long it took, within the range the
  /// tablet executes.
  final RemoteSwipeCallback onSwipe;

  @override
  State<RemoteControlGestureLayer> createState() =>
      _RemoteControlGestureLayerState();
}

class _RemoteControlGestureLayerState extends State<RemoteControlGestureLayer> {
  bool _isOverPicture = false;

  /// The press being followed. `null` also means dropped: whatever that pointer
  /// does until it goes up is ignored.
  _RemotePress? _press;

  @override
  void didUpdateWidget(RemoteControlGestureLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Here too, and not only at the next pointer event: a pointer standing still
    // says nothing, and the ratio could be back by the time it moves again.
    if (_press?.videoAspectRatio != widget.videoAspectRatio()) _press = null;
  }

  @override
  void dispose() {
    // A pointer already down keeps reporting to the callbacks of this state.
    _press = null;
    super.dispose();
  }

  NormalizedRemotePoint? _pointAt(Offset position) {
    final videoAspectRatio = widget.videoAspectRatio();
    final size = context.size;
    if (videoAspectRatio == null || size == null) return null;
    return RemoteVideoGeometry.normalize(
      pointerX: position.dx,
      pointerY: position.dy,
      containerWidth: size.width,
      containerHeight: size.height,
      videoAspectRatio: videoAspectRatio,
    );
  }

  /// Where [position] is on the tablet, for as long as [press] still makes sense:
  /// the same geometry it started with, and the pointer on the picture.
  NormalizedRemotePoint? _pointOfPress(_RemotePress press, Offset position) {
    if (widget.videoAspectRatio() != press.videoAspectRatio ||
        context.size != press.surfaceSize) {
      return null;
    }
    return _pointAt(position);
  }

  void _onHover(PointerHoverEvent event) {
    final isOverPicture = _pointAt(event.localPosition) != null;
    if (isOverPicture != _isOverPicture) {
      setState(() => _isOverPicture = isOverPicture);
    }
  }

  void _onExit(PointerExitEvent event) {
    if (_isOverPicture) setState(() => _isOverPicture = false);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_press != null) {
      // A second finger. Several of them is not a gesture the tablet has.
      _press = null;
      return;
    }
    if (event.buttons != kPrimaryButton) return;

    final point = _pointAt(event.localPosition);
    if (point == null) return;
    _press = _RemotePress(
      pointer: event.pointer,
      position: event.localPosition,
      point: point,
      timeStamp: event.timeStamp,
      videoAspectRatio: widget.videoAspectRatio(),
      surfaceSize: context.size,
    );
  }

  void _onPointerMove(PointerMoveEvent event) {
    final press = _press;
    if (press == null || press.pointer != event.pointer) return;

    if (event.buttons != kPrimaryButton ||
        _pointOfPress(press, event.localPosition) == null) {
      _press = null;
      return;
    }
    press.follow(event.localPosition);
  }

  void _onPointerUp(PointerUpEvent event) {
    final press = _press;
    if (press == null || press.pointer != event.pointer) return;
    _press = null;

    final end = _pointOfPress(press, event.localPosition);
    if (end == null) return;
    press.follow(event.localPosition);

    if (!press.isDrag) {
      widget.onTap(end);
      return;
    }
    // Dragged away and brought back: not a tap, and a stroke of almost nothing
    // would reach the tablet as a long press on whatever is there.
    if (press.distanceTo(event.localPosition) <
        RemoteControlGestureLayer.dragThreshold) {
      return;
    }
    widget.onSwipe(
      start: press.point,
      end: end,
      durationMs: RemoteSwipeCommand.durationMsFor(
        event.timeStamp - press.timeStamp,
      ),
    );
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (_press?.pointer == event.pointer) _press = null;
  }

  /// The wheel scrolls the page under a pointer that is down, and the positions
  /// that follow would no longer be relative to where the press started.
  void _onPointerSignal(PointerSignalEvent event) => _press = null;

  /// Nothing to do with the drag itself: what it does is keep the arena, so that
  /// a finger on the picture moves the tablet and not the page around it.
  static void _holdDrag(DragStartDetails details) {}

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _isOverPicture ? SystemMouseCursors.click : MouseCursor.defer,
      onHover: _onHover,
      onExit: _onExit,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerMove: _onPointerMove,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        onPointerSignal: _onPointerSignal,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: _holdDrag,
          onHorizontalDragStart: _holdDrag,
        ),
      ),
    );
  }
}

/// A pointer that went down on the picture and has not come up.
final class _RemotePress {
  _RemotePress({
    required this.pointer,
    required this.position,
    required this.point,
    required this.timeStamp,
    required this.videoAspectRatio,
    required this.surfaceSize,
  });

  final int pointer;

  /// Where it went down, on the surface and on the tablet.
  final Offset position;
  final NormalizedRemotePoint point;

  /// When it went down, on the clock of the pointer events themselves: the time
  /// the technician's gesture took, not the time it took to reach this code.
  final Duration timeStamp;

  /// The geometry it started with, which its end has to share.
  final double? videoAspectRatio;
  final Size? surfaceSize;

  /// Whether it ever got as far as a drag. It stays one, wherever it goes next.
  bool isDrag = false;

  double distanceTo(Offset other) => (other - position).distance;

  void follow(Offset other) {
    if (distanceTo(other) >= RemoteControlGestureLayer.dragThreshold) {
      isDrag = true;
    }
  }
}
