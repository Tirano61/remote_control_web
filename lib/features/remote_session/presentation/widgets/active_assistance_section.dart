import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/presentation/format/elapsed_label.dart';
import '../../../../core/presentation/widgets/console_feedback.dart';
import '../../../../core/presentation/widgets/console_section.dart';
import '../../../../core/presentation/widgets/presence_indicator.dart';
import '../../../remote_control/domain/entities/remote_control_command.dart';
import '../../../remote_control/domain/entities/remote_control_status.dart';
import '../../../remote_control/presentation/widgets/remote_control_gesture_layer.dart';
import '../../../remote_control/presentation/widgets/remote_text_dialog.dart';
import '../../../technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import '../../../technician_realtime/domain/entities/technician_realtime_status.dart';
import '../../../technician_realtime/presentation/bloc/technician_realtime/technician_realtime_bloc.dart';
import '../../../webrtc/domain/entities/webrtc_connection_state.dart';
import '../../../webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';
import '../../../webrtc/presentation/remote_screen/remote_video_renderer.dart';
import '../../../webrtc/presentation/widgets/remote_screen_view.dart';
import '../../domain/entities/remote_session.dart';
import '../bloc/remote_session/remote_session_bloc.dart';

/// "ASISTENCIA REMOTA" block of the console.
///
/// It is shown only when the backend says there is a live session, and it takes
/// the top of the page: an assistance in progress is the most important thing
/// on screen.
///
/// The realtime channel is described in plain words. Namespaces, rooms,
/// handshakes and acknowledgements are implementation details the technician
/// has no use for.
///
/// The three lines it shows answer three different questions, and they are
/// only allowed to disagree while something is genuinely in between:
///
/// ```text
/// Estado                       what the backend says the session is
/// Canal de asistencia          whether signaling is usable
/// Conexión remota establecida  whether the peers reached each other
/// ```
///
/// Once the peers are connected the console confirms it with
/// `POST /remote-sessions/:id/activate`, so "Conectando con el dispositivo..."
/// next to "Conexión remota establecida" is a transient window and no longer
/// the resting state it used to be.
///
/// The tablet's screen is the main element of the block, between the device
/// it belongs to and the diagnostics above. It is a capability next to the
/// connection: an assistance without a picture yet — MediaProjection consent
/// still pending on the tablet — is a valid assistance, and every line and
/// button stays exactly where it was.
class ActiveAssistanceSection extends StatelessWidget {
  const ActiveAssistanceSection({
    required this.remoteVideoRendererFactory,
    super.key,
  });

  /// Builds the renderer of the remote screen. The only implementation that
  /// knows WebRTC lives in `data`; this widget never sees it.
  final RemoteVideoRendererFactory remoteVideoRendererFactory;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RemoteSessionBloc, RemoteSessionState>(
      builder: (context, state) => switch (state) {
        // One widget for CONNECTING and ACTIVE alike, so the activation of
        // the session never tears the remote screen down.
        RemoteSessionLive() => _LiveAssistance(
          key: const Key('active_assistance_section'),
          state: state,
          remoteVideoRendererFactory: remoteVideoRendererFactory,
        ),
        // Nothing is open, but something went wrong while finding that out.
        RemoteSessionFailure(:final failure) => _AssistanceProblem(
          message: failure.message,
        ),
        RemoteSessionIdle(:final failure) when failure != null =>
          _AssistanceProblem(message: failure.message),
        // No live session: the dashboard looks the way it normally does.
        _ => const SizedBox.shrink(),
      },
    );
  }
}

class _LiveAssistance extends StatelessWidget {
  const _LiveAssistance({
    required this.state,
    required this.remoteVideoRendererFactory,
    super.key,
  });

  final RemoteSessionLive state;
  final RemoteVideoRendererFactory remoteVideoRendererFactory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bloc = context.read<RemoteSessionBloc>();
    final RemoteSession session = state.session;
    final device = session.device;

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: ConsoleSection(
        title: 'ASISTENCIA REMOTA',
        subtitle: session.status.label,
        trailing: device == null
            ? null
            : PresenceIndicator(isOnline: device.isOnline, compact: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Everything that has to be on screen, inside one budget. What is
            // not the picture is laid out first, whatever it takes at this width,
            // and the picture gets what is left. So the bar stays in the window
            // without moving the page, and not because of a guess about how tall
            // it wrapped.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: _remoteControlBudget(
                  MediaQuery.sizeOf(context).height,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (state.failure != null) ...[
                    ConsoleBanner(
                      key: const Key('remote_session_error_banner'),
                      message: state.failure!.message,
                      isError: true,
                      onDismiss: () =>
                          bloc.add(const RemoteSessionNoticeDismissed()),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('remote_session_retry_button'),
                        // An activation that failed on the way out is retried
                        // as what it was. Everything else is recovered by
                        // re-reading the backend, which is the console's usual
                        // answer.
                        onPressed: () => bloc.add(
                          state.canRetryActivation
                              ? RemoteSessionActivationRequested(session.id)
                              : const RemoteSessionRefreshRequested(),
                        ),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('REINTENTAR'),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  // On one line: a pixel spent here is a pixel less of picture.
                  Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        session.deviceLabel,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (session.devicePublicId != null)
                        Text(
                          session.devicePublicId!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Keyed by the session: another assistance gets another
                  // renderer and no text dialog, and the slot is matched by key
                  // however many optional lines around it come and go.
                  Flexible(
                    key: ValueKey('remote_screen_${session.id}'),
                    child: _RemoteControls(
                      key: ValueKey('remote_controls_${session.id}'),
                      remoteSessionId: session.id,
                      rendererFactory: remoteVideoRendererFactory,
                      finishButton: FilledButton.icon(
                        key: const Key('close_remote_session_button'),
                        // Disabled while the close is in flight: the backend
                        // answers `409` to a second one, and the user should
                        // not have to see that.
                        onPressed: state.isClosing
                            ? null
                            : () =>
                                  bloc.add(const RemoteSessionCloseRequested()),
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.error,
                          foregroundColor: theme.colorScheme.onError,
                        ),
                        icon: state.isClosing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.stop_circle_outlined),
                        label: const Text('FINALIZAR ASISTENCIA'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (session.isConnecting) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(
                    'Estado: ${session.status.description}',
                    style: theme.textTheme.bodyLarge,
                  ),
                ),
              ],
            ),
            // Stamped by the backend when it moved the session to `ACTIVE`.
            // Never computed here: the console does not own that instant.
            if (session.connectedAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  key: const Key('remote_session_connected_at'),
                  'Conectado desde: ${timeOfDay(session.connectedAt!)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 6),
            const _AssistanceChannelStatus(),
            const SizedBox(height: 6),
            const _RemoteConnectionStatus(),
            _ControlPauseNotice(state: state),
          ],
        ),
      ),
    );
  }

  /// How tall what has to stay on screen may get together, for a window of
  /// [viewportHeight].
  ///
  /// There is a floor, because in a very low window the bar has to be scrolled
  /// to anyway and a picture of nothing would help nobody.
  static double _remoteControlBudget(double viewportHeight) => math.max(
    viewportHeight - _chromeAboveTheBudget - _spareHeight,
    _minBudget,
  );

  /// What the page puts on top and no width changes: the app bar (56), the
  /// padding of the page (20) and of the section (18), and the title of the
  /// section with its subtitle and their gap (60).
  static const double _chromeAboveTheBudget = 154;

  /// So the bar never touches the edge of the window.
  static const double _spareHeight = 16;

  static const double _minBudget = 360;
}

/// The picture and what operates it, with the text dialog on top of the picture
/// for as long as it is open.
///
/// The dialog is held in this state, not in a route, so it needs nothing to take it
/// down when the assistance ends: this widget goes away with the session, and the
/// text with it. While the assistance goes on, it closes as soon as the technician
/// can no longer see what it would write on.
///
/// Open, it holds back every other command, so that nothing the technician does
/// moves the focus they confirmed on the picture. FINALIZAR ASISTENCIA is the one
/// thing it never holds back, and it is outside the part of the screen it covers.
class _RemoteControls extends StatefulWidget {
  const _RemoteControls({
    required this.remoteSessionId,
    required this.rendererFactory,
    required this.finishButton,
    super.key,
  });

  final String remoteSessionId;
  final RemoteVideoRendererFactory rendererFactory;
  final Widget finishButton;

  @override
  State<_RemoteControls> createState() => _RemoteControlsState();
}

class _RemoteControlsState extends State<_RemoteControls> {
  bool _isTextDialogOpen = false;

  void _setTextDialogOpen(bool isOpen) {
    if (_isTextDialogOpen == isOpen) return;
    setState(() => _isTextDialogOpen = isOpen);
  }

  /// A negotiation that ended and a new one in its place are also covered: the
  /// states in between never offer a text.
  bool _canOfferText(WebRtcSessionState state) =>
      state.remoteSessionId == widget.remoteSessionId &&
      state.canOfferRemoteText;

  @override
  Widget build(BuildContext context) {
    final sessions = context.read<WebRtcSessionBloc>();

    return BlocListener<WebRtcSessionBloc, WebRtcSessionState>(
      listenWhen: (_, current) => !_canOfferText(current),
      listener: (_, _) => _setTextDialogOpen(false),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: Stack(
              children: [
                _RemoteScreen(
                  remoteSessionId: widget.remoteSessionId,
                  rendererFactory: widget.rendererFactory,
                  isHeldBack: _isTextDialogOpen,
                ),
                if (_isTextDialogOpen)
                  Positioned.fill(
                    child: BlocBuilder<WebRtcSessionBloc, WebRtcSessionState>(
                      builder: (context, state) => RemoteTextDialog(
                        canSend: state.canSendRemoteText,
                        onSend: (text) {
                          _setTextDialogOpen(false);
                          sessions.add(
                            WebRtcRemoteTextRequested(
                              remoteSessionId: widget.remoteSessionId,
                              text: text,
                            ),
                          );
                        },
                        onCancel: () => _setTextDialogOpen(false),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Under the picture and outside its pointer layer, never on top of it.
          Wrap(
            key: const Key('remote_control_bar'),
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _RemoteNavigationControls(
                remoteSessionId: widget.remoteSessionId,
                isHeldBack: _isTextDialogOpen,
                onTextPressed: () =>
                    _setTextDialogOpen(_canOfferText(sessions.state)),
              ),
              widget.finishButton,
            ],
          ),
        ],
      ),
    );
  }
}

/// The tablet's screen, while a peer connection for this session exists.
///
/// ```text
/// negotiating, no track yet    "Esperando pantalla del dispositivo..."
/// track received               the live picture
/// failed / closed / none       nothing: the line below says why
/// ```
///
/// The surface only exists while a negotiation for *this* `RemoteSession` is
/// alive. When it ends — the peer connection failed or closed, WebRTC was
/// terminated, the session closed or changed — the surface leaves the tree
/// and its renderer is disposed with it, so no frame of an obsolete peer can
/// stay on screen.
///
/// Whether the tablet refused MediaProjection is not something the web is
/// told: no message of the protocol says so. The placeholder therefore keeps
/// waiting rather than guessing a cause.
class _RemoteScreen extends StatelessWidget {
  const _RemoteScreen({
    required this.remoteSessionId,
    required this.rendererFactory,
    required this.isHeldBack,
  });

  final String remoteSessionId;
  final RemoteVideoRendererFactory rendererFactory;

  /// The text dialog is open: the picture stays, and takes no gesture.
  final bool isHeldBack;

  /// However tall the window gets. How much room there is comes from the
  /// parent, which takes what operates the picture out of it first.
  static const double _maxHeight = 900;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WebRtcSessionBloc, WebRtcSessionState>(
      buildWhen: (previous, current) =>
          _isShown(previous) != _isShown(current) ||
          !identical(previous.remoteVideoTrack, current.remoteVideoTrack) ||
          previous.canSendRemoteControl != current.canSendRemoteControl ||
          previous.canSendRemoteNavigation != current.canSendRemoteNavigation ||
          previous.remoteControl.lastCommand !=
              current.remoteControl.lastCommand ||
          previous.remoteControl.isSettling !=
              current.remoteControl.isSettling ||
          previous.remoteControl.isTextPending !=
              current.remoteControl.isTextPending ||
          previous.remoteControl.lastTouch != current.remoteControl.lastTouch,
      builder: (context, state) {
        if (!_isShown(state)) return const SizedBox.shrink();
        final canSend = state.canSendRemoteControl;
        // Not listening while a global action, an IME action or a long press
        // settles: a press that starts on a picture on its way somewhere else is
        // not picked up afterwards, and one held down when a long press goes out
        // is over: its release is neither a tap nor a swipe. The line below says
        // nothing about it, because it lasts an instant. The same while a text
        // is on its way, or being written.
        //
        // A touch session does not stop it: the surface is what follows the
        // pointer of that touch, and it must stay to report its moves and its
        // release. What else the pointer tries meanwhile is refused by the BLoC.
        final isListening =
            canSend &&
            !isHeldBack &&
            !state.remoteControl.isSettling &&
            !state.remoteControl.isTextPending;
        final lastCommand = state.remoteControl.lastCommand;
        final isGesture = lastCommand == null || lastCommand.kind.isGesture;
        final sessions = context.read<WebRtcSessionBloc>();
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: RemoteScreenView(
            track: state.remoteVideoTrack,
            rendererFactory: rendererFactory,
            maxHeight: _maxHeight,
            onRemoteTap: isListening
                ? (point) => context.read<WebRtcSessionBloc>().add(
                    WebRtcRemoteTapRequested(
                      remoteSessionId: remoteSessionId,
                      point: point,
                    ),
                  )
                : null,
            onRemoteSwipe: isListening
                ? ({required start, required end, required durationMs}) =>
                      context.read<WebRtcSessionBloc>().add(
                        WebRtcRemoteSwipeRequested(
                          remoteSessionId: remoteSessionId,
                          start: start,
                          end: end,
                          durationMs: durationMs,
                        ),
                      )
                : null,
            onRemoteLongPress: isListening
                ? (point) => context.read<WebRtcSessionBloc>().add(
                    WebRtcRemoteLongPressRequested(
                      remoteSessionId: remoteSessionId,
                      point: point,
                    ),
                  )
                : null,
            // Whether a hold becomes a touch_hold or the legacy long_press is
            // the BLoC's decision: the surface only reports the pointer. These
            // may run while the surface is being disposed, so they do not look
            // anything up in the tree.
            onRemoteTouch: isListening
                ? RemoteTouchCallbacks(
                    onHold: (pointer, point) => _addIfOpen(
                      sessions,
                      WebRtcRemoteTouchHoldRequested(
                        remoteSessionId: remoteSessionId,
                        pointer: pointer,
                        point: point,
                      ),
                    ),
                    onMove: (pointer, point) => _addIfOpen(
                      sessions,
                      WebRtcRemoteTouchMoved(
                        remoteSessionId: remoteSessionId,
                        pointer: pointer,
                        point: point,
                      ),
                    ),
                    onRelease: (pointer, point) => _addIfOpen(
                      sessions,
                      WebRtcRemoteTouchReleased(
                        remoteSessionId: remoteSessionId,
                        pointer: pointer,
                        point: point,
                      ),
                    ),
                    onCancel: (pointer) => _addIfOpen(
                      sessions,
                      WebRtcRemoteTouchCancelled(
                        remoteSessionId: remoteSessionId,
                        pointer: pointer,
                      ),
                    ),
                  )
                : null,
            onPictureChanged: (isDisplayed) {
              if (sessions.isClosed) return;
              sessions.add(
                WebRtcRemotePictureChanged(
                  remoteSessionId: remoteSessionId,
                  isDisplayed: isDisplayed,
                ),
              );
            },
            controlStatusBuilder: (context, hasPicture) => _RemoteControlLine(
              isAvailable: canSend && hasPicture,
              lastTouch: state.remoteControl.lastTouch,
              lastCommand: isGesture ? lastCommand : null,
              lastAction: !isGesture && state.canSendRemoteNavigation
                  ? lastCommand
                  : null,
            ),
          ),
        );
      },
    );
  }

  /// A live negotiation of the session on screen. A WebRTC state about any
  /// other session is never displayed under this one.
  bool _isShown(WebRtcSessionState state) =>
      state.hasNegotiation && state.remoteSessionId == remoteSessionId;

  static void _addIfOpen(WebRtcSessionBloc bloc, WebRtcSessionEvent event) {
    if (!bloc.isClosed) bloc.add(event);
  }
}

/// One discreet line under the picture: whether gestures reach the tablet, what
/// became of the last one, and at its end, right above the buttons, what became
/// of the last global action or text. Never the text itself: it is not there.
///
/// Above the buttons rather than among them, so that a message coming and going
/// never moves a button from under the pointer.
///
/// A refusal is not an emergency. The picture keeps arriving and the assistance
/// goes on, so nothing here takes over the screen.
class _RemoteControlLine extends StatelessWidget {
  const _RemoteControlLine({
    required this.isAvailable,
    required this.lastTouch,
    required this.lastCommand,
    required this.lastAction,
  });

  final bool isAvailable;

  /// The last touch session, when it is more recent than any gesture.
  final RemoteTouchFeedback? lastTouch;
  final RemoteCommandFeedback? lastCommand;
  final RemoteCommandFeedback? lastAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outcome = lastCommand?.outcome;
    final touch = lastTouch;
    final isProblem =
        isAvailable &&
        (touch != null
            ? touch.phase == RemoteTouchPhase.failed
            : outcome != null &&
                  outcome != RemoteCommandOutcome.pending &&
                  outcome != RemoteCommandOutcome.confirmed);
    final color = isProblem
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    final action = lastAction;

    return Row(
      children: [
        Icon(Icons.touch_app_outlined, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            key: const Key('remote_control_status'),
            !isAvailable
                ? 'Control remoto: no disponible'
                : touch != null
                ? _touchLabel(touch)
                : _label(lastCommand),
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
        if (action != null) ...[
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              key: const Key('remote_navigation_status'),
              switch (action.kind) {
                RemoteCommandKind.setText => _textLabel(action.outcome),
                RemoteCommandKind.imeEnter => _imeEnterLabel(action.outcome),
                _ => _navigationLabel(action),
              },
              textAlign: TextAlign.end,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _isActionProblem(action.outcome)
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }

  static bool _isActionProblem(RemoteCommandOutcome outcome) =>
      outcome != RemoteCommandOutcome.pending &&
      outcome != RemoteCommandOutcome.confirmed;

  static String _navigationLabel(RemoteCommandFeedback last) {
    final name = switch (last.kind) {
      RemoteCommandKind.back => 'Atrás',
      RemoteCommandKind.home => 'Inicio',
      RemoteCommandKind.recents => 'Recientes',
      // Never asked for: these have their own start of the line, and a text its
      // own words.
      RemoteCommandKind.tap ||
      RemoteCommandKind.swipe ||
      RemoteCommandKind.longPress ||
      RemoteCommandKind.setText ||
      RemoteCommandKind.imeEnter ||
      RemoteCommandKind.touchHold ||
      RemoteCommandKind.touchMove ||
      RemoteCommandKind.touchRelease ||
      RemoteCommandKind.touchCancel => last.kind.name,
    };
    return switch (last.outcome) {
      RemoteCommandOutcome.pending => 'Enviando $name...',
      RemoteCommandOutcome.confirmed => '$name enviado',
      RemoteCommandOutcome.accessibilityUnavailable =>
        'El dispositivo no tiene habilitado el control remoto.',
      RemoteCommandOutcome.sessionNotActive =>
        'La asistencia no está activa en el dispositivo.',
      RemoteCommandOutcome.gestureRejected ||
      // Never the answer to a global action: a text and the IME action have
      // their own words for these.
      RemoteCommandOutcome.textTargetUnavailable ||
      RemoteCommandOutcome.textRejected ||
      RemoteCommandOutcome.imeActionUnavailable ||
      RemoteCommandOutcome.imeActionRejected ||
      RemoteCommandOutcome.touchEnded => 'No se pudo ejecutar la acción.',
      RemoteCommandOutcome.timedOut => 'El dispositivo no confirmó la acción.',
      RemoteCommandOutcome.incompatible ||
      RemoteCommandOutcome.channelClosed ||
      RemoteCommandOutcome.notSent => 'Control remoto no disponible',
    };
  }

  static String _textLabel(RemoteCommandOutcome outcome) => switch (outcome) {
    RemoteCommandOutcome.pending => 'Enviando texto...',
    RemoteCommandOutcome.confirmed => 'Texto enviado',
    RemoteCommandOutcome.textTargetUnavailable =>
      'No hay un campo de texto editable enfocado.',
    RemoteCommandOutcome.textRejected => 'El dispositivo rechazó el texto.',
    RemoteCommandOutcome.accessibilityUnavailable =>
      'El dispositivo no tiene habilitado el control remoto.',
    RemoteCommandOutcome.sessionNotActive =>
      'La asistencia no está activa en el dispositivo.',
    RemoteCommandOutcome.gestureRejected ||
    // Never the answer to a text.
    RemoteCommandOutcome.imeActionUnavailable ||
    RemoteCommandOutcome.imeActionRejected ||
    RemoteCommandOutcome.touchEnded => 'No se pudo ejecutar la acción.',
    RemoteCommandOutcome.timedOut => 'El dispositivo no confirmó el texto.',
    RemoteCommandOutcome.notSent ||
    RemoteCommandOutcome.channelClosed => 'No se pudo enviar el texto.',
    RemoteCommandOutcome.incompatible => 'Control remoto no disponible',
  };

  /// What became of the IME action. Never which action it was, or what it did:
  /// the web knows neither. `ok` only says Android accepted it.
  static String _imeEnterLabel(RemoteCommandOutcome outcome) =>
      switch (outcome) {
        RemoteCommandOutcome.pending => 'Ejecutando acción...',
        RemoteCommandOutcome.confirmed => 'Acción enviada',
        RemoteCommandOutcome.textTargetUnavailable =>
          'No hay un campo de texto editable enfocado.',
        RemoteCommandOutcome.imeActionUnavailable =>
          'El campo enfocado no ofrece una acción de teclado.',
        RemoteCommandOutcome.imeActionRejected =>
          'El dispositivo rechazó la acción del campo.',
        RemoteCommandOutcome.accessibilityUnavailable =>
          'El dispositivo no tiene habilitado el control remoto.',
        RemoteCommandOutcome.sessionNotActive =>
          'La asistencia no está activa en el dispositivo.',
        // Never the answer to an IME action.
        RemoteCommandOutcome.gestureRejected ||
        RemoteCommandOutcome.textRejected ||
        RemoteCommandOutcome.touchEnded => 'No se pudo ejecutar la acción.',
        RemoteCommandOutcome.timedOut =>
          'El dispositivo no confirmó la acción.',
        RemoteCommandOutcome.notSent ||
        RemoteCommandOutcome.channelClosed => 'No se pudo enviar la acción.',
        RemoteCommandOutcome.incompatible => 'Control remoto no disponible',
      };

  /// What became of a long press. `ok` says Android completed the gesture, not
  /// that a menu opened or anything got selected: the web does not know.
  static String _longPressLabel(RemoteCommandOutcome outcome) =>
      switch (outcome) {
        RemoteCommandOutcome.pending => 'Manteniendo pulsado...',
        RemoteCommandOutcome.confirmed => 'Pulsación prolongada enviada',
        RemoteCommandOutcome.accessibilityUnavailable =>
          'El dispositivo no tiene habilitado el control remoto.',
        RemoteCommandOutcome.sessionNotActive =>
          'La asistencia no está activa en el dispositivo.',
        RemoteCommandOutcome.gestureRejected =>
          'El dispositivo rechazó la pulsación prolongada.',
        // Never the answer to a gesture.
        RemoteCommandOutcome.textTargetUnavailable ||
        RemoteCommandOutcome.textRejected ||
        RemoteCommandOutcome.imeActionUnavailable ||
        RemoteCommandOutcome.imeActionRejected ||
        RemoteCommandOutcome.touchEnded =>
          'No se pudo ejecutar la pulsación prolongada.',
        RemoteCommandOutcome.timedOut =>
          'El dispositivo no confirmó la pulsación prolongada.',
        RemoteCommandOutcome.incompatible ||
        RemoteCommandOutcome.channelClosed ||
        RemoteCommandOutcome.notSent => 'Control remoto no disponible',
      };

  /// Where the last touch session is. An `ok` to its hold only says the finger
  /// is down past the long press timeout, and an `ok` to its release that the
  /// contact ended: never that anything was picked up, moved or dropped. That is
  /// only on the picture.
  static String _touchLabel(RemoteTouchFeedback touch) => switch (touch.phase) {
    RemoteTouchPhase.holding => 'Manteniendo pulsado...',
    RemoteTouchPhase.held => 'Pulsación mantenida',
    RemoteTouchPhase.dragging => 'Arrastrando...',
    RemoteTouchPhase.releasing => 'Soltando...',
    RemoteTouchPhase.released =>
      touch.hasMoved ? 'Arrastre finalizado' : 'Pulsación finalizada',
    RemoteTouchPhase.cancelling => 'Cancelando contacto remoto...',
    RemoteTouchPhase.cancelled => 'Contacto remoto cancelado',
    RemoteTouchPhase.failed => switch (touch.failure) {
      RemoteCommandOutcome.touchEnded =>
        'El contacto remoto terminó antes de completar la acción.',
      RemoteCommandOutcome.accessibilityUnavailable =>
        'El dispositivo no tiene habilitado el control remoto.',
      RemoteCommandOutcome.sessionNotActive =>
        'La asistencia no está activa en el dispositivo.',
      RemoteCommandOutcome.gestureRejected =>
        'El dispositivo rechazó el contacto remoto.',
      RemoteCommandOutcome.timedOut =>
        'El dispositivo no confirmó el final del contacto remoto.',
      RemoteCommandOutcome.incompatible ||
      RemoteCommandOutcome.channelClosed ||
      RemoteCommandOutcome.notSent => 'Control remoto no disponible',
      _ => 'No se pudo completar el contacto remoto.',
    },
  };

  static String _label(RemoteCommandFeedback? last) {
    if (last == null) return 'Control remoto: listo';
    if (last.kind == RemoteCommandKind.longPress) {
      return _longPressLabel(last.outcome);
    }
    final isSwipe = last.kind == RemoteCommandKind.swipe;
    // Only a tap or a swipe gets here: global actions have their own end of
    // the line.
    return switch (last.outcome) {
      RemoteCommandOutcome.pending =>
        isSwipe ? 'Enviando desplazamiento...' : 'Enviando toque...',
      RemoteCommandOutcome.confirmed =>
        isSwipe ? 'Desplazamiento enviado' : 'Toque enviado',
      RemoteCommandOutcome.accessibilityUnavailable =>
        'El dispositivo no tiene habilitado el control remoto.',
      RemoteCommandOutcome.sessionNotActive =>
        'La asistencia no está activa en el dispositivo.',
      RemoteCommandOutcome.gestureRejected ||
      // Never the answer to a gesture: a text and the IME action have their own
      // end of the line.
      RemoteCommandOutcome.textTargetUnavailable ||
      RemoteCommandOutcome.textRejected ||
      RemoteCommandOutcome.imeActionUnavailable ||
      RemoteCommandOutcome.imeActionRejected ||
      RemoteCommandOutcome.touchEnded =>
        isSwipe
            ? 'No se pudo ejecutar el desplazamiento.'
            : 'No se pudo ejecutar el toque.',
      RemoteCommandOutcome.timedOut =>
        isSwipe
            ? 'El dispositivo no confirmó el desplazamiento.'
            : 'El dispositivo no confirmó el toque.',
      RemoteCommandOutcome.incompatible ||
      RemoteCommandOutcome.channelClosed ||
      RemoteCommandOutcome.notSent => 'Control remoto no disponible',
    };
  }
}

/// Android's Back, Home and Recents, the button that opens the text dialog, and
/// Acción, which runs the IME action of the focused field.
///
/// They sit outside the picture and outside its pointer layer. Back, Home and
/// Recents do not depend on the picture either: these are global actions, so they
/// work while the tablet is not sharing its screen, which is exactly when the line
/// under the picture says that gestures are not available.
///
/// Those three are disabled until the session is `ACTIVE`, the peers are connected
/// and `control` is open, and for as long as a previous one is settling, which is
/// what makes a double click one action.
///
/// Texto asks for more, because the technician has to be able to see where the text
/// lands: `WebRtcSessionState.canSendRemoteText`. Acción asks for exactly the same,
/// for the same reason: `WebRtcSessionState.canSendRemoteImeEnter`. It is the only
/// way an IME action ever goes out: a tap on a field or a text that went out never
/// sends one.
/// What the Acción button says it does. It names examples, never the action: the
/// web does not know which one the focused field declares.
const String kRemoteImeEnterHelp =
    'Ejecuta la acción disponible del campo enfocado, por ejemplo Buscar, Ir, '
    'Siguiente o Enviar.';

class _RemoteNavigationControls extends StatelessWidget {
  const _RemoteNavigationControls({
    required this.remoteSessionId,
    required this.isHeldBack,
    required this.onTextPressed,
  });

  final String remoteSessionId;

  /// The text dialog is open.
  final bool isHeldBack;

  final VoidCallback onTextPressed;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<WebRtcSessionBloc, WebRtcSessionState>(
      builder: (context, state) {
        final isThisSession =
            state.remoteSessionId == remoteSessionId && !isHeldBack;
        final isEnabled =
            isThisSession &&
            state.canSendRemoteNavigation &&
            !state.remoteControl.isSettling &&
            !state.remoteControl.isTextPending &&
            // A finger is down on the tablet: Back, Home or Recents would act
            // under it. FINALIZAR is not one of these and stays available.
            !state.remoteControl.isTouchActive;
        final bloc = context.read<WebRtcSessionBloc>();

        // Five of these have to wrap into as few rows as they can: every row
        // they take is taken from the picture.
        return OutlinedButtonTheme(
          data: OutlinedButtonThemeData(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10),
            ),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('remote_back_button'),
                onPressed: isEnabled
                    ? () => bloc.add(
                        WebRtcRemoteBackRequested(
                          remoteSessionId: remoteSessionId,
                        ),
                      )
                    : null,
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('Atrás'),
              ),
              OutlinedButton.icon(
                key: const Key('remote_home_button'),
                onPressed: isEnabled
                    ? () => bloc.add(
                        WebRtcRemoteHomeRequested(
                          remoteSessionId: remoteSessionId,
                        ),
                      )
                    : null,
                icon: const Icon(Icons.home_outlined, size: 18),
                label: const Text('Inicio'),
              ),
              OutlinedButton.icon(
                key: const Key('remote_recents_button'),
                onPressed: isEnabled
                    ? () => bloc.add(
                        WebRtcRemoteRecentsRequested(
                          remoteSessionId: remoteSessionId,
                        ),
                      )
                    : null,
                icon: const Icon(Icons.crop_square, size: 18),
                label: const Text('Recientes'),
              ),
              OutlinedButton.icon(
                key: const Key('remote_text_button'),
                onPressed: isThisSession && state.canSendRemoteText
                    ? onTextPressed
                    : null,
                icon: const Icon(Icons.keyboard_outlined, size: 18),
                label: const Text('Texto'),
              ),
              // Never called Enter: it is not a key, and which action the field
              // runs is not known here.
              Tooltip(
                key: const Key('remote_ime_enter_tooltip'),
                message: kRemoteImeEnterHelp,
                child: OutlinedButton.icon(
                  key: const Key('remote_ime_enter_button'),
                  onPressed: isThisSession && state.canSendRemoteImeEnter
                      ? () => bloc.add(
                          WebRtcRemoteImeEnterRequested(
                            remoteSessionId: remoteSessionId,
                          ),
                        )
                      : null,
                  icon: const Icon(Icons.keyboard_return, size: 18),
                  label: const Text('Acción'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// One line telling the technician whether the assistance channel is ready.
///
/// It merges two different facts — the connection and the join — into the only
/// thing the user cares about: can this assistance work right now.
class _AssistanceChannelStatus extends StatelessWidget {
  const _AssistanceChannelStatus();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocBuilder<SignalingJoinBloc, SignalingJoinState>(
      builder: (context, joinState) {
        final isReady = joinState is SignalingJoined;
        final hasProblem = joinState is SignalingUnavailable;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              isReady
                  ? Icons.link
                  : hasProblem
                  ? Icons.link_off
                  : Icons.more_horiz,
              size: 18,
              color: hasProblem
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                key: const Key('assistance_channel_status'),
                isReady
                    ? 'Canal de asistencia establecido.'
                    : hasProblem
                    ? 'El canal de asistencia no está disponible.'
                    : 'Preparando el canal de asistencia...',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: hasProblem
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (hasProblem)
              TextButton(
                key: const Key('signaling_retry_button'),
                onPressed: () => _retry(context, joinState),
                child: const Text('REINTENTAR'),
              ),
          ],
        );
      },
    );
  }

  /// A refused join is never retried automatically, so the only way back is an
  /// explicit request from the user.
  void _retry(BuildContext context, SignalingUnavailable state) {
    final connectionId = context
        .read<TechnicianRealtimeBloc>()
        .state
        .connectionId;
    if (connectionId == null) return;
    context.read<SignalingJoinBloc>().add(
      SignalingJoinRequested(
        remoteSessionId: state.remoteSessionId,
        connectionId: connectionId,
        force: true,
      ),
    );
  }
}

/// Shown while the console cannot confirm that the assistance on screen is
/// still the technician's: the connection with the server is lost, or the last
/// attempt to check the assistance failed.
///
/// Remote control is withheld meanwhile — the decision is the console's, this
/// only says why. It never claims the assistance ended: it may still be open,
/// and the backend decides.
const String kControlPausedBySocketNotice =
    'Sin conexión con el servidor. El control remoto está en pausa hasta '
    'confirmar que la asistencia sigue activa.';

const String kControlPausedUnverifiedNotice =
    'No se pudo confirmar que la asistencia sigue activa. El control remoto '
    'está en pausa.';

class _ControlPauseNotice extends StatelessWidget {
  const _ControlPauseNotice({required this.state});

  final RemoteSessionLive state;

  @override
  Widget build(BuildContext context) {
    // Only an ACTIVE assistance has remote control to pause.
    if (state is! RemoteSessionActive || state.isClosing) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);

    return BlocBuilder<TechnicianRealtimeBloc, TechnicianRealtimeStatus>(
      buildWhen: (previous, current) =>
          previous.isConnected != current.isConnected,
      builder: (context, status) {
        final message = !status.isConnected
            ? kControlPausedBySocketNotice
            : !state.isVerified
            ? kControlPausedUnverifiedNotice
            : null;
        if (message == null) return const SizedBox.shrink();
        // The error banner already offers REINTENTAR while it is shown.
        final canRetry =
            status.isConnected && !state.isVerified && state.failure == null;

        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Icon(
                Icons.pause_circle_outline,
                size: 18,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  key: const Key('remote_control_paused_notice'),
                  message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
              if (canRetry)
                TextButton(
                  key: const Key('remote_control_paused_retry_button'),
                  onPressed: () => context.read<RemoteSessionBloc>().add(
                    const RemoteSessionRefreshRequested(),
                  ),
                  child: const Text('REINTENTAR'),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The peer connection failed and the console has an attempt planned.
const String kWebRtcRecoveringNotice =
    'Se perdió la conexión con el dispositivo. Reintentando...';

/// The peer connection failed and no automatic attempt is left.
const String kWebRtcFailedNotice = 'No se pudo establecer la conexión remota.';

/// The offer was relayed long ago and the tablet has not answered. Most often
/// its user is still looking at Android's screen sharing dialog, so it is not
/// worded as an error.
const String kWebRtcUnansweredNotice =
    'El dispositivo todavía no respondió. Si la tablet pide permiso para '
    'compartir la pantalla, debe aceptarse allí.';

/// One line telling the technician whether the browser reached the tablet.
///
/// It reports the WebRTC negotiation, which is a different fact from both the
/// `RemoteSession` status above it and the signaling channel next to it. The
/// two agree in the end — a connection established here is what makes the
/// session `ACTIVE` — but they are read from different places and one of them
/// is always the first to know.
///
/// Nothing of the negotiation itself is shown: no SDP, no candidate, no state
/// machine. The technician needs to know whether it works, not how.
class _RemoteConnectionStatus extends StatelessWidget {
  const _RemoteConnectionStatus();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocBuilder<WebRtcSessionBloc, WebRtcSessionState>(
      builder: (context, state) {
        // Nothing to say yet: no assistance, or the tablet has not entered the
        // room. The line above is the one that talks about that.
        if (state is WebRtcIdle || state is WebRtcClosed) {
          return const SizedBox.shrink();
        }

        final isEstablished = state.isConnected && state.isControlChannelOpen;
        final hasFailed = state is WebRtcFailed;
        final isUnanswered =
            !hasFailed && (state.isAnswerOverdue || state.isTabletSilent);
        final isRecovering = hasFailed && state.isRecoveryScheduled;
        final remoteSessionId = state.remoteSessionId;
        final isError = hasFailed && !isRecovering;

        final message = isEstablished
            ? 'Conexión remota establecida'
            : isRecovering
            ? kWebRtcRecoveringNotice
            : hasFailed
            ? kWebRtcFailedNotice
            : isUnanswered
            ? kWebRtcUnansweredNotice
            : 'Conectando con el dispositivo...';

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isEstablished
                      ? Icons.cast_connected
                      : isError
                      ? Icons.error_outline
                      : isUnanswered
                      ? Icons.hourglass_empty
                      : Icons.sync,
                  size: 18,
                  color: isError
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    key: const Key('webrtc_status'),
                    message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: isError
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            // Always there when a new attempt could help, also while one is
            // planned: the technician may know the network is back.
            if (state.canRetryConnection && remoteSessionId != null)
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: TextButton.icon(
                  key: const Key('webrtc_retry_button'),
                  onPressed: () => context.read<WebRtcSessionBloc>().add(
                    WebRtcConnectionRetryRequested(remoteSessionId),
                  ),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('REINTENTAR CONEXIÓN'),
                ),
              ),
            // Debug builds only, and deliberately shallow: the two facts a
            // developer needs while bringing WebRTC up, and nothing that could
            // leak an SDP, a candidate or a token.
            if (kDebugMode) ...[
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Text(
                  key: const Key('webrtc_debug_status'),
                  'WebRTC: ${_peerLabel(state)} · '
                  'Canal de control: ${_channelLabel(state.controlChannelState)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  static String _peerLabel(WebRtcSessionState state) => switch (state) {
    WebRtcPreparing() => 'preparando',
    WebRtcOffering() => 'ofreciendo',
    WebRtcConnecting() => 'conectando',
    WebRtcConnected() => 'conectado',
    WebRtcInterrupted() => 'interrumpido',
    WebRtcFailed() => 'fallido',
    WebRtcClosed() => 'cerrado',
    WebRtcIdle() => 'inactivo',
  };

  static String _channelLabel(WebRtcDataChannelState state) => switch (state) {
    WebRtcDataChannelState.connecting => 'abriendo',
    WebRtcDataChannelState.open => 'abierto',
    WebRtcDataChannelState.closing => 'cerrando',
    WebRtcDataChannelState.closed => 'cerrado',
  };
}

/// Compact error shown when the state of the assistance could not be read or a
/// start was refused. It never hides the rest of the console.
class _AssistanceProblem extends StatelessWidget {
  const _AssistanceProblem({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<RemoteSessionBloc>();

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConsoleBanner(
            key: const Key('remote_session_error_banner'),
            message: message,
            isError: true,
            onDismiss: () => bloc.add(const RemoteSessionNoticeDismissed()),
          ),
          TextButton.icon(
            key: const Key('remote_session_retry_button'),
            onPressed: () => bloc.add(const RemoteSessionRefreshRequested()),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('REINTENTAR'),
          ),
        ],
      ),
    );
  }
}
