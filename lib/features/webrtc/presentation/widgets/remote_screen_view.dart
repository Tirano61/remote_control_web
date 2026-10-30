import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/entities/remote_video_track.dart';
import '../remote_screen/remote_video_renderer.dart';

/// Shown while there is no picture of the tablet yet.
const String kWaitingForRemoteScreenNotice =
    'Esperando pantalla del dispositivo...';

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
/// The surface is visual only. It does not listen to pointers or keys; remote
/// control is a later stage.
class RemoteScreenView extends StatefulWidget {
  const RemoteScreenView({
    required this.track,
    required this.rendererFactory,
    required this.maxHeight,
    super.key,
  });

  /// The screen to show, or `null` while none is arriving.
  final RemoteVideoTrack? track;

  final RemoteVideoRendererFactory rendererFactory;

  /// The tallest the surface may get. The width comes from the parent.
  final double maxHeight;

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
    _renderer = widget.rendererFactory();
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
    unawaited(_renderer.dispose());
    super.dispose();
  }

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

        return LayoutBuilder(
          builder: (context, constraints) {
            final size = _fit(
              aspectRatio: aspectRatio,
              maxWidth: constraints.maxWidth,
              maxHeight: widget.maxHeight,
            );

            return Center(
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
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
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
