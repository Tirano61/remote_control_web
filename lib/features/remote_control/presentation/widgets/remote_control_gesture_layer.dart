import 'dart:async';

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

/// A position of the pointer that a held touch follows.
typedef RemoteTouchPointCallback =
    void Function(int pointer, NormalizedRemotePoint point);

/// What a press held still becomes when its receiver follows it to the end: a
/// remote touch. See [RemoteControlGestureLayer.onTouch].
///
/// Every call names the console's pointer, so that whoever receives them can
/// tell one press from the next.
final class RemoteTouchCallbacks {
  const RemoteTouchCallbacks({
    required this.onHold,
    required this.onMove,
    required this.onRelease,
    required this.onCancel,
  });

  /// Held still for the long press timeout, where it started. Once.
  final RemoteTouchPointCallback onHold;

  /// Every move after that, clamped to the picture.
  final RemoteTouchPointCallback onMove;

  /// Went up there, clamped to the picture. Nothing follows.
  final RemoteTouchPointCallback onRelease;

  /// Can no longer go on. Nothing follows.
  final void Function(int pointer) onCancel;
}

/// Turns what the pointer does over the picture of the tablet into one gesture
/// on the tablet: a tap, a swipe or a long press, never two of them.
///
/// ```text
/// down          on the picture, primary button: the press starts, and so does
///               the long press timeout
/// move          beyond the threshold it is a drag from then on, and can no
///               longer be a long press
/// timeout,      still down, never a drag: a long press where it went down,
///   no drag     reported there and then. Whatever that pointer does next,
///               moving or going up, reports nothing else, unless [onTouch]
///               follows it (below)
/// up, no drag   a tap
/// up, drag      a swipe from where it was pressed to where it was released
/// ```
///
/// With [onTouch], a press held still is not over when it is reported: it is a
/// remote touch, and the pointer is followed until it goes up.
///
/// ```text
/// timeout       onTouch.onHold where it went down, instead of onLongPress
/// move          onTouch.onMove, clamped to the picture: a held finger may be
///               pushed to the edge, and a band is the edge, never a cancel
/// up            onTouch.onRelease, clamped the same way
/// cancelled     onTouch.onCancel: the browser cancelled the pointer, a second
///               one went down, the wheel turned, another button was pressed,
///               the geometry changed, or this surface went away
/// ```
///
/// Nothing of that applies before the timeout: a press that has not been held
/// yet is a tap or a swipe exactly as above, dropped on a band and never clamped.
///
/// A tap and a swipe are reported when the pointer goes up and never before. A
/// long press cannot wait for it: the technician holds the pointer down to see
/// the menu it opens. How long the technician has to hold still is
/// [longPressTimeout], Flutter's own; how long Android holds the touch is the
/// tablet's business, and nothing here says it.
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
    required this.onLongPress,
    this.onTouch,
    super.key,
  });

  /// How far the pointer has to travel to be a drag and not a shaky click, in
  /// logical pixels of this surface: the tablet's resolution says nothing about
  /// what the technician meant. Exactly this far is already a drag.
  static const double dragThreshold = 6;

  /// How long a press has to stay down, and closer than [dragThreshold] to where
  /// it started, to be a long press: Flutter's standard timeout.
  static const Duration longPressTimeout = kLongPressTimeout;

  /// The aspect ratio of the picture right now, or `null` while there is none.
  final double? Function() videoAspectRatio;

  final ValueChanged<NormalizedRemotePoint> onTap;

  /// Called with both ends of a drag and how long it took, within the range the
  /// tablet executes.
  final RemoteSwipeCallback onSwipe;

  /// Called once with where a press started, as soon as it has been held still
  /// for [longPressTimeout], while the pointer is still down. Whoever receives
  /// it still decides whether it can go out: nothing here knows about sessions,
  /// channels or pending commands.
  final ValueChanged<NormalizedRemotePoint> onLongPress;

  /// When given, a press held still is followed as a remote touch rather than
  /// reported once: see the table above. [onLongPress] is then never called.
  final RemoteTouchCallbacks? onTouch;

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
    if (_press?.videoAspectRatio != widget.videoAspectRatio()) {
      _drop();
      return;
    }
    // A held touch keeps the tablet's finger down while the pointer stands
    // still, so a new size cannot wait for the next move to be noticed. It is
    // only known once this frame is laid out.
    if (_press?.isTouch ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkTouchSize());
    }
  }

  void _checkTouchSize() {
    final press = _press;
    if (!mounted || press == null || !press.isTouch) return;
    if (context.size != press.surfaceSize) _drop();
  }

  @override
  void dispose() {
    // A pointer already down keeps reporting to the callbacks of this state, and
    // a long press timeout must not outlive it. A held touch is cancelled: its
    // finger must not stay down on the tablet behind a surface that is gone.
    _drop();
    super.dispose();
  }

  /// Forgets the press, and whatever it was still about to report. A held touch
  /// is cancelled: nothing is dropped where the pointer happens to be.
  void _drop() {
    final press = _press;
    _press = null;
    if (press == null) return;
    press.cancelLongPress();
    if (press.isTouch) widget.onTouch?.onCancel(press.pointer);
  }

  /// Where [position] is on the tablet for the held touch [press]: clamped to
  /// the picture, as long as the geometry is still the one it started with.
  NormalizedRemotePoint? _touchPointOf(_RemotePress press, Offset position) {
    final videoAspectRatio = widget.videoAspectRatio();
    final size = context.size;
    if (videoAspectRatio == null ||
        size == null ||
        videoAspectRatio != press.videoAspectRatio ||
        size != press.surfaceSize) {
      return null;
    }
    return RemoteVideoGeometry.clampToPicture(
      pointerX: position.dx,
      pointerY: position.dy,
      containerWidth: size.width,
      containerHeight: size.height,
      videoAspectRatio: videoAspectRatio,
    );
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
      // A second finger. Several of them is not a gesture the tablet has, and a
      // held touch is cancelled rather than turned into a pinch.
      _drop();
      return;
    }
    if (event.buttons != kPrimaryButton) return;

    final point = _pointAt(event.localPosition);
    if (point == null) return;
    final press = _RemotePress(
      pointer: event.pointer,
      position: event.localPosition,
      point: point,
      timeStamp: event.timeStamp,
      videoAspectRatio: widget.videoAspectRatio(),
      surfaceSize: context.size,
    );
    press.longPressTimer = Timer(
      RemoteControlGestureLayer.longPressTimeout,
      () => _onLongPressTimeout(press),
    );
    _press = press;
  }

  /// [press] has been down for the whole long press timeout.
  ///
  /// Everything it depends on is read again now: the geometry it started with,
  /// and where it started still being on the picture. The point sent is that
  /// one, not wherever the pointer drifted by less than the threshold since.
  void _onLongPressTimeout(_RemotePress press) {
    press.longPressTimer = null;
    if (!mounted || !identical(_press, press) || press.isDrag) return;
    if (_pointOfPress(press, press.position) == null) {
      _drop();
      return;
    }
    press.isLongPress = true;
    final onTouch = widget.onTouch;
    if (onTouch == null) {
      widget.onLongPress(press.point);
      return;
    }
    // Where it started, and not where it drifted by less than the threshold.
    press.isTouch = true;
    onTouch.onHold(press.pointer, press.point);
  }

  void _onPointerMove(PointerMoveEvent event) {
    final press = _press;
    if (press == null || press.pointer != event.pointer) return;
    if (press.isTouch) {
      _followTouch(press, event);
      return;
    }
    // Reported already: wherever it goes now, it is not a drag after a long press.
    if (press.isLongPress) return;

    if (event.buttons != kPrimaryButton ||
        _pointOfPress(press, event.localPosition) == null) {
      _drop();
      return;
    }
    press.follow(event.localPosition);
  }

  /// The held touch moved: wherever the pointer is, even off the picture.
  void _followTouch(_RemotePress press, PointerMoveEvent event) {
    final point = event.buttons == kPrimaryButton
        ? _touchPointOf(press, event.localPosition)
        : null;
    if (point == null) {
      // Another button, or another geometry: not the touch it started as.
      _drop();
      return;
    }
    widget.onTouch?.onMove(press.pointer, point);
  }

  void _onPointerUp(PointerUpEvent event) {
    final press = _press;
    if (press == null || press.pointer != event.pointer) return;
    if (press.isTouch) {
      final point = _touchPointOf(press, event.localPosition);
      if (point == null) {
        _drop();
        return;
      }
      _press = null;
      press.cancelLongPress();
      widget.onTouch?.onRelease(press.pointer, point);
      return;
    }
    _drop();
    // The long press was the gesture: going up is not a tap as well.
    if (press.isLongPress) return;

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
    if (_press?.pointer == event.pointer) _drop();
  }

  /// The wheel scrolls the page under a pointer that is down, and the positions
  /// that follow would no longer be relative to where the press started. A held
  /// touch is cancelled for the same reason.
  void _onPointerSignal(PointerSignalEvent event) => _drop();

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

  /// Running from the moment it went down until it becomes a drag, goes up, is
  /// dropped or fires.
  Timer? longPressTimer;

  /// Whether it was reported as a long press. Nothing else is reported for it,
  /// unless it [isTouch].
  bool isLongPress = false;

  /// Whether it was reported as the hold of a remote touch, which this press
  /// goes on with until it goes up or is cancelled.
  bool isTouch = false;

  double distanceTo(Offset other) => (other - position).distance;

  /// Measured from where it went down, never added up move after move: a hand
  /// that trembles is not travelling.
  void follow(Offset other) {
    if (distanceTo(other) >= RemoteControlGestureLayer.dragThreshold) {
      isDrag = true;
      cancelLongPress();
    }
  }

  void cancelLongPress() {
    longPressTimer?.cancel();
    longPressTimer = null;
  }
}
