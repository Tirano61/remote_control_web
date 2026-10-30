import 'package:flutter/widgets.dart';

import '../../domain/entities/remote_video_track.dart';

/// What [RemoteVideoRenderer.attach] did with a track.
enum RemoteVideoAttachResult {
  /// The track is now the one on screen.
  attached,

  /// The handle is not one this renderer can display — it was produced by a
  /// different WebRTC implementation, or by a test. Nothing was shown and
  /// nothing was thrown.
  unsupportedTrack,

  /// Another attach or a detach came in while this one was still preparing.
  /// The newest request wins; this one was dropped.
  superseded,

  /// The renderer was already disposed.
  disposed,

  /// WebRTC refused to bind the track. The renderer stays usable.
  failed,
}

/// Displays the tablet's screen, as presentation sees it.
///
/// It is the seam between the opaque [RemoteVideoTrack] handle and a real
/// video renderer. Presentation drives its lifecycle — create, attach, detach,
/// dispose — and asks it for a widget, but never learns what is behind it: no
/// `RTCVideoRenderer`, no `MediaStream`, no `MediaStreamTrack` and no
/// `RTCVideoView` appears in this interface. The only implementation that
/// knows `flutter_webrtc` lives in `data`, next to the peer connection
/// adapter, and is handed to presentation by the composition root.
///
/// It is a presentation port rather than a domain one because what it
/// produces is a widget.
///
/// ```text
/// create      one per remote screen surface, never one per build
/// initialize  idempotent; attach waits for it
/// attach      the track becomes the one on screen (replacing any other)
/// detach      nothing is shown any more; the renderer stays reusable
/// dispose     everything released, once; the renderer is unusable after
/// ```
///
/// Listeners are notified whenever what [buildView] would show changes: a
/// track attached or detached, or the video reporting new dimensions.
abstract interface class RemoteVideoRenderer implements Listenable {
  /// Prepares the underlying renderer. Only the first call does any work.
  Future<void> initialize();

  /// Shows [track], replacing whatever was shown before.
  ///
  /// Never throws: an incompatible handle or a refusal from WebRTC is
  /// reported through the result instead.
  Future<RemoteVideoAttachResult> attach(RemoteVideoTrack track);

  /// Stops showing the current track, if any. The track itself is not
  /// stopped: it belongs to the peer connection.
  Future<void> detach();

  /// Releases the renderer. Idempotent.
  Future<void> dispose();

  /// The track currently on screen, or `null`.
  RemoteVideoTrack? get track;

  /// Whether [buildView] has a track to show right now.
  bool get isDisplaying;

  /// Width / height of the video as it is being received, once the first
  /// frames have told what it is; `null` before that and while nothing is
  /// displayed.
  ///
  /// It follows the stream: a tablet that rotates, or a capture that changes
  /// resolution, reports a new value.
  double? get aspectRatio;

  /// The view of the current track. Only meaningful while [isDisplaying].
  ///
  /// The view fills the space it is given and letterboxes the video into it
  /// (`contain`): the image is never cropped, stretched or mirrored.
  Widget buildView(BuildContext context);
}

/// Creates one renderer per remote screen surface. Injected from the
/// composition root, replaced by a fake in tests.
typedef RemoteVideoRendererFactory = RemoteVideoRenderer Function();
