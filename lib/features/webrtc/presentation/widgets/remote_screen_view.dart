import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../remote_control/domain/entities/normalized_remote_point.dart';
import '../../../remote_control/presentation/widgets/remote_control_gesture_layer.dart';
import '../../domain/entities/remote_video_track.dart';
import '../remote_screen/remote_video_renderer.dart';

/// Shown while there is no picture of the tablet yet.
const String kWaitingForRemoteScreenNotice =
    'Esperando pantalla del dispositivo...';

/// See [RemoteScreenView.controlStatusBuilder].
typedef RemoteControlStatusBuilder =
    Widget Function(BuildContext context, bool hasPicture);

/// The tablet's screen, live.
///
/// It owns the lifecycle of exactly one [RemoteVideoRenderer], obtained from
/// the injected factory when the widget is mounted:
///
/// ```text
/// initState       create + initialize, attach the track if there is one
/// track changes   attach the new one (it replaces the old) or detach
/// dispose         dispose — the renderer never outlives this widget
/// ```
///
/// A rebuild never creates anything: the renderer is created once per
/// mounted widget, and a parent that wants a fresh one — a different remote
/// session, for instance — gives this widget a different key.
///
/// The pointer is only listened to over a real picture and when [onRemoteTap]
/// and [onRemoteSwipe] are given. The placeholder, the bands left by `contain`
/// and anything outside the surface never produce a gesture. Keys are not
/// listened to at all.
class RemoteScreenView extends StatefulWidget {
  const RemoteScreenView({
    required this.track,
    required this.rendererFactory,
    required this.maxHeight,
    this.onRemoteTap,
    this.onRemoteSwipe,
    this.controlStatusBuilder,
    this.onPictureChanged,
    super.key,
  }) : assert(
         (onRemoteTap == null) == (onRemoteSwipe == null),
         'Remote control is either available or not.',
       );

  /// The screen to show, or `null` while none is arriving.
  final RemoteVideoTrack? track;

  final RemoteVideoRendererFactory rendererFactory;

  /// The tallest the surface may get, however much room the parent has. The
  /// width comes from the parent, and so does any tighter limit on the height.
  final double maxHeight;

  /// Called with the position on the tablet under a click. `null` while remote
  /// control cannot be used, which leaves the surface visual only.
  final ValueChanged<NormalizedRemotePoint>? onRemoteTap;

  /// Called with a drag across the picture once it is over. `null` exactly when
  /// [onRemoteTap] is.
  final RemoteSwipeCallback? onRemoteSwipe;

  /// Builds what is said about remote control under the surface. Only this
  /// widget knows whether a picture is really being displayed: a track exists
  /// well before its first frame, as long as the tablet waits for consent.
  final RemoteControlStatusBuilder? controlStatusBuilder;

  /// Told whether a picture is really being displayed, each time the renderer has
  /// something new to say and, with `false`, when this surface goes away. It may
  /// be called during a build, so whoever listens must not rebuild from it directly.
  final ValueChanged<bool>? onPictureChanged;

  /// Proportions of the empty frame before the video has said what its own
  /// are. Only the placeholder uses it: the picture is always laid out with
  /// the aspect ratio the stream reports.
  static const double placeholderAspectRatio = 16 / 9;

  @override
  State<RemoteScreenView> createState() => _RemoteScreenViewState();
}

class _RemoteScreenViewState extends State<RemoteScreenView> {
  late final RemoteVideoRenderer _renderer;

  @override
  void initState() {
    super.initState();
    _renderer = widget.rendererFactory()..addListener(_reportPicture);
    unawaited(_renderer.initialize().catchError((Object _) {}));
    final track = widget.track;
    if (track != null) unawaited(_renderer.attach(track));
  }

  @override
  void didUpdateWidget(RemoteScreenView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final track = widget.track;
    if (identical(track, oldWidget.track)) return;
    // A new track replaces the previous one on the same renderer: never two
    // renderers, never two pictures on top of each other.
    unawaited(track == null ? _renderer.detach() : _renderer.attach(track));
  }

  @override
  void dispose() {
    _renderer.removeListener(_reportPicture);
    widget.onPictureChanged?.call(false);
    unawaited(_renderer.dispose());
    super.dispose();
  }

  void _reportPicture() => widget.onPictureChanged?.call(
    _renderer.isDisplaying && _renderer.aspectRatio != null,
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _renderer,
      builder: (context, _) {
        final isDisplaying = _renderer.isDisplaying;
        final videoAspectRatio = _renderer.aspectRatio;
        final aspectRatio =
            videoAspectRatio ?? RemoteScreenView.placeholderAspectRatio;
        // Bound to the picture: until the first frames tell its size, the
        // track is attached but nothing can be seen yet.
        final isWaiting = !isDisplaying || videoAspectRatio == null;
        final onRemoteTap = widget.onRemoteTap;
        final onRemoteSwipe = widget.onRemoteSwipe;
        final controlStatusBuilder = widget.controlStatusBuilder;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Whatever comes under the surface is laid out first, so the height
            // the parent can spare goes to the picture after that line is paid.
            Flexible(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = _fit(
                    aspectRatio: aspectRatio,
                    maxWidth: constraints.maxWidth,
                    maxHeight: math.min(
                      widget.maxHeight,
                      constraints.maxHeight,
                    ),
                  );

                  return Center(
                    heightFactor: 1,
                    child: SizedBox(
                      key: const Key('remote_screen_surface'),
                      width: size.width,
                      height: size.height,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: ColoredBox(
                          color: Colors.black,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // First and always in the same slot, so that a new
                              // size or the placeholder going away never rebuilds
                              // the view from scratch.
                              if (isDisplaying)
                                KeyedSubtree(
                                  key: const Key('remote_screen_video'),
                                  child: _renderer.buildView(context),
                                ),
                              if (isWaiting) const _WaitingForScreen(),
                              if (!isWaiting &&
                                  onRemoteTap != null &&
                                  onRemoteSwipe != null)
                                RemoteControlGestureLayer(
                                  key: const Key('remote_screen_gesture_layer'),
                                  videoAspectRatio: () => _renderer.aspectRatio,
                                  onTap: onRemoteTap,
                                  onSwipe: onRemoteSwipe,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (controlStatusBuilder != null) ...[
              const SizedBox(height: 8),
              controlStatusBuilder(context, !isWaiting),
            ],
          ],
        );
      },
    );
  }

  /// The largest box of [aspectRatio] that fits both bounds: `contain`, done
  /// by the layout so that the picture is never stretched or cropped.
  static Size _fit({
    required double aspectRatio,
    required double maxWidth,
    required double maxHeight,
  }) {
    final width = math.min(maxWidth, maxHeight * aspectRatio);
    return Size(width, width / aspectRatio);
  }
}

class _WaitingForScreen extends StatelessWidget {
  const _WaitingForScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.tablet_android, color: Colors.white54, size: 32),
            const SizedBox(height: 10),
            Text(
              kWaitingForRemoteScreenNotice,
              key: const Key('remote_screen_waiting'),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
