import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../domain/entities/normalized_remote_point.dart';
import '../../domain/geometry/remote_video_geometry.dart';

/// Turns clicks on the picture of the tablet into positions on the tablet.
///
/// It covers the whole video surface and only reacts over the picture itself:
/// a click on a band left by `contain` is not a touch on anything, so it reports
/// nothing. A press that turned into a drag is not a tap either, which is why
/// this acts on the pointer going up and leaves the slop to the recognizer.
///
/// Both the size and the aspect ratio are read when the pointer event happens
/// and never kept, so the click after a rotation already uses the new geometry.
class RemoteTapLayer extends StatefulWidget {
  const RemoteTapLayer({
    required this.videoAspectRatio,
    required this.onTap,
    super.key,
  });

  /// The aspect ratio of the picture right now, or `null` while there is none.
  final double? Function() videoAspectRatio;

  final ValueChanged<NormalizedRemotePoint> onTap;

  @override
  State<RemoteTapLayer> createState() => _RemoteTapLayerState();
}

class _RemoteTapLayerState extends State<RemoteTapLayer> {
  bool _isOverPicture = false;

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

  void _onHover(PointerHoverEvent event) {
    final isOverPicture = _pointAt(event.localPosition) != null;
    if (isOverPicture != _isOverPicture) {
      setState(() => _isOverPicture = isOverPicture);
    }
  }

  void _onExit(PointerExitEvent event) {
    if (_isOverPicture) setState(() => _isOverPicture = false);
  }

  void _onTapUp(TapUpDetails details) {
    final point = _pointAt(details.localPosition);
    if (point != null) widget.onTap(point);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: _isOverPicture ? SystemMouseCursors.click : MouseCursor.defer,
      onHover: _onHover,
      onExit: _onExit,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: _onTapUp,
      ),
    );
  }
}
