# Control channel — `remote_control_web`

How a click on the console becomes a touch on the tablet, seen from the web.

The protocol itself is an agreement with `remote_control_device`, carried peer
to peer: the backend never sees it. Its source is
`remote_control_device/docs/webrtc/CONTROL_CHANNEL.md`, and this document only
repeats what the web has to honour. How the channel is created is in
[WEBRTC.md](WEBRTC.md#the-control-data-channel).

## The whole path

```text
pointer up on the picture
  -> RemoteTapLayer                  reads the size and the aspect ratio now
  -> RemoteVideoGeometry.normalize   video content rect, or nothing
  -> NormalizedRemotePoint           x, y in 0..1 over the frame
  -> WebRtcRemoteTapRequested        the BLoC checks the gate again
  -> RemoteTapCommand                id from the generator
  -> PendingRemoteCommands           tracked before it is sent
  -> RemoteControlChannelCodec       the only JSON in the application
  -> `control` data channel
  -> Android dispatchGesture
  -> ack
  -> RemoteControlAckReceived        typed, or never published
  -> RemoteTapFeedback               the line under the picture
```

Presentation knows normalized coordinates, tap intents and a status. It does not
know `RTCDataChannel`, `RTCDataChannelMessage`, `jsonEncode` or `flutter_webrtc`.

## Protocol v1

Only `tap`. One text frame holding one JSON object, on the existing `control`
channel. No other channel is created.

```json
{"v":1,"type":"tap","id":"tap-1","x":0.5,"y":0.25}
```

```json
{"v":1,"type":"ack","id":"tap-1","ok":true}
```

```json
{"v":1,"type":"ack","id":"tap-1","ok":false,"error":"accessibility_unavailable"}
```

An ack is valid when `v == 1`, `type == "ack"`, `id` is a non-empty string and
`ok` is a bool; with `ok: false`, `error` must also be a string. Anything else is
ignored without an exception, and a binary frame too. A failure code this version
does not know is still a failure (`RemoteControlError.unknown`): the tablet did
answer, and ignoring it would only leave the technician waiting for the timeout.

`ok: true` means Android reported the gesture **completed**, not that it was
requested.

## From a pointer to a coordinate

The picture is drawn with `contain` and `mirror = false`. So the coordinates the
tablet understands are relative to the frame, not to the widget, and X is never
inverted.

```text
containerRatio = Wc / Hc
videoRatio     = Wv / Hv

video proportionally wider:           renderedWidth  = Wc
                                      renderedHeight = Wc / videoRatio
                                      offsetX = 0
                                      offsetY = (Hc - renderedHeight) / 2

video proportionally taller or equal: renderedHeight = Hc
                                      renderedWidth  = Hc * videoRatio
                                      offsetX = (Wc - renderedWidth) / 2
                                      offsetY = 0

videoX = pointerX - offsetX           x = videoX / renderedWidth
videoY = pointerY - offsetY           y = videoY / renderedHeight
```

Origin at the top-left, x grows right, y grows down.

### Letterbox and pillarbox clicks are ignored

A click on a band is not a touch on anything. It produces no command, no channel
message and no gesture, and it is **never** moved to the nearest edge of the
picture.

The only clamp absorbs rounding, after the pointer was found to be on the
picture. Computing the rectangle of a video that exactly fills its box can put
its edge at `1e-14`, so a tolerance of `1e-6` logical pixels applies to that edge
and nothing else.

Where bands actually are, today: `RemoteScreenView` shapes its surface after the
video, so the bands are normally the empty space beside the surface, which has
no pointer layer at all. Bands inside the layer exist in the instant between a
new geometry and the rebuild, and the geometry is computed for that case too.

### Rotation needs no signal

The size and the aspect ratio are read when the pointer event happens, from the
renderer's current value, and never kept. The tablet can rotate during a session
and the next click already uses the new geometry. Nothing hardcodes an orientation
or a resolution.

What cannot be avoided: between Android rotating and the browser being told, the
picture on screen is still the old frame. A click in that instant is aimed at the
old frame, and Android reads its display when the command runs. It is the same
limitation the tablet documents under `SCREEN_SHARING.md#noticing-a-rotation`.

### What counts as a tap

A press and release without a drag, with the primary button, acting on the
pointer going **up**: the slop is the gesture recognizer's. A drag sends nothing.
Keys, the wheel and every other gesture send nothing either.

## When a click is accepted

All of them, checked twice: the surface does not listen at all unless they hold,
and the BLoC checks them again when the click arrives.

```text
RemoteSession ACTIVE, and not being closed    REST, through the coordinator
RTCPeerConnectionState connected              WebRtcSessionBloc
control channel open                          WebRtcSessionBloc
a remote video track                          WebRtcSessionBloc
the renderer really displaying a picture      RemoteScreenView
the click is aimed at the current session     WebRtcRemoteTapRequested
```

The picture condition cannot be read from the track: `ontrack` fires when the
answer is applied, while the tablet may still be asking for MediaProjection
consent. So until the renderer reports a size there is no pointer layer, and the
line says `Control remoto: no disponible`.

If anything is missing nothing is sent. **Clicks are not queued** while connecting:
a touch that lands seconds later, on whatever is on screen by then, is worse than
a click that did nothing.

## Pending commands

```text
commandId -> pending command (with its deadline)
```

| Event | Result |
| --- | --- |
| ack for a pending id | settles only that command |
| ack for an unknown id | ignored |
| second ack for an id | ignored |
| ack after the timeout | ignored; the timeout stands |
| ack of an older tap | settles it; says nothing about the last tap |

The line under the picture follows the **last** tap. There is no history.

| Situation | Line |
| --- | --- |
| ready, no tap yet | `Control remoto: listo` |
| ack pending | `Enviando toque...` |
| `ok: true` | `Toque enviado` |
| `accessibility_unavailable` | `El dispositivo no tiene habilitado el control remoto.` |
| `session_not_active` | `La asistencia no está activa en el dispositivo.` |
| `gesture_rejected` | `No se pudo ejecutar el toque.` |
| timeout | `El dispositivo no confirmó el toque.` |
| `invalid_command`, `unsupported_command`, unknown | `Control remoto no disponible` |
| anything needed is missing | `Control remoto: no disponible` |

### No automatic retry

A command is sent at most once, whatever happens to it. A gesture may have run
with its acknowledgement lost, so sending it again could press something twice.
The technician clicks again if they want to.

### ACK timeout

Three seconds, per command (`WebRtcSessionBloc.defaultRemoteCommandTimeout`). The
tablet sends nothing on a channel that closed or was replaced, so an answer may
never come. The timeout reports and does nothing else.

## What each refusal does

```text
accessibility_unavailable   a message; the session and the picture go on
session_not_active          one GET /remote-sessions/current per refused tap;
                            WebRTC is left alone; REST decides what happens
gesture_rejected            a message
invalid_command             a log line and a message: a bug or a version mismatch
unsupported_command         idem
```

None of them closes the `RemoteSession` or the peer connection.

## Cleanup

```text
channel closing/closed       pending cleared at once, no deadline waited for,
                             a tap still pending shown as not available
session leaves ACTIVE        clicks stop, pending and feedback cleared
FINALIZAR pressed            idem, at the press and not at the backend's answer;
                             a close that fails gives the control back
session id changes           idem
sign out                     idem, and the peer connection goes
peer connection failed       pending and feedback released with the negotiation
new peer connection          starts with nothing pending
```

## Generations

Commands belong to the negotiation that sent them, and the existing generation
guard covers them: an ack is a peer event, so one from a replaced or closed peer
connection is dropped before it can touch anything, and a deadline carries the
generation it was started in. An old `tap-1` can therefore not resolve a new
`tap-1`, even if a generator repeated the id.

The default generator counts `tap-1`, `tap-2`, ... for as long as the page lives,
and does not restart with a negotiation. It is injectable
(`RemoteControlCommandIdGenerator`), and never derives an id from coordinates or
screen content.

## Testing on a device

**Do not use mobile-mcp or anything else holding a `UiAutomation` during these
tests**: it suppresses the accessibility service, and a command would never reach
`dispatchGesture`. Use `adb logcat`, `dumpsys` and `adb exec-out screencap -p`.
The toggle and the *full control* dialog are the user's, by hand, always.

## Logging

```text
tap command sent <id>
tap confirmed <id>
tap timed out <id>
remote control command rejected: <code>
control message ignored <remoteSessionId>
control ack ignored <id>
remote tap ignored <remoteSessionId>
```

Coordinates and frames are not logged, here or on the tablet.
