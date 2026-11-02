# Control channel — `remote_control_web`

How what the technician does on the picture becomes a gesture on the tablet, and
what the Atrás and Inicio buttons become, seen from the web.

The protocol itself is an agreement with `remote_control_device`, carried peer
to peer: the backend never sees it. Its source is
`remote_control_device/docs/webrtc/CONTROL_CHANNEL.md`, and this document only
repeats what the web has to honour. How the channel is created is in
[WEBRTC.md](WEBRTC.md#the-control-data-channel).

## The whole path

```text
pointer down, move, up on the picture
  -> RemoteControlGestureLayer       reads the size and the aspect ratio each time
  -> RemoteVideoGeometry.normalize   video content rect, or nothing
  -> NormalizedRemotePoint           x, y in 0..1 over the frame
  -> WebRtcRemoteTapRequested        the BLoC checks the gate again
     WebRtcRemoteSwipeRequested
  -> RemoteTapCommand                id from the generator
     RemoteSwipeCommand
  -> PendingRemoteCommands           tracked before it is sent
  -> RemoteControlChannelCodec       the only JSON in the application
  -> `control` data channel
  -> Android dispatchGesture
  -> ack
  -> RemoteControlAckReceived        typed, or never published
  -> RemoteCommandFeedback           the line under the picture
```

The buttons join that path at the event, and only the end of it differs:

```text
Atrás, Inicio
  -> WebRtcRemoteBackRequested       the BLoC checks its own gate
     WebRtcRemoteHomeRequested
  -> RemoteBackCommand               id from the same generator
     RemoteHomeCommand
  -> PendingRemoteCommands           the same map, the same deadlines
     RemoteNavigationGuard           starts now, see Back and Home
  -> RemoteControlChannelCodec
  -> `control` data channel
  -> Android performGlobalAction
  -> ack
  -> RemoteCommandFeedback           the line next to the buttons
```

Presentation knows normalized coordinates, gesture intents and a status. It does
not know `RTCDataChannel`, `RTCDataChannelMessage`, `jsonEncode` or `flutter_webrtc`.

## Protocol v1

`tap`, `swipe`, `back` and `home`. One text frame holding one JSON object, on the
existing `control` channel. No other channel is created.

```json
{"v":1,"type":"tap","id":"tap-1","x":0.5,"y":0.25}
```

```json
{"v":1,"type":"swipe","id":"swipe-2","startX":0.5,"startY":0.8,"endX":0.5,"endY":0.2,"durationMs":350}
```

```json
{"v":1,"type":"back","id":"back-3"}
```

```json
{"v":1,"type":"home","id":"home-4"}
```

```json
{"v":1,"type":"ack","id":"swipe-2","ok":true}
```

```json
{"v":1,"type":"ack","id":"tap-1","ok":false,"error":"accessibility_unavailable"}
```

In a swipe the four coordinates are the same kind of value as a tap's, and
`durationMs` is an integer in `50..2000`. The tablet refuses `350.0`, and refuses
a swipe whose start equals its end. A tap has no `durationMs`: Android holds it
for its own 50 ms. `back` and `home` carry their id and nothing else: they are not
touches, so no coordinate and no duration means anything to them.

An ack is valid when `v == 1`, `type == "ack"`, `id` is a non-empty string and
`ok` is a bool; with `ok: false`, `error` must also be a string. Anything else is
ignored without an exception, and a binary frame too. A failure code this version
does not know is still a failure (`RemoteControlError.unknown`): the tablet did
answer, and ignoring it would only leave the technician waiting for the timeout.

What `ok: true` promises depends on the command, because Android promises different
things:

```text
tap, swipe    Android reported the gesture completed, not merely that it was requested
back, home    Android accepted the global action
```

`performGlobalAction` returns a boolean and has no callback. A `back` or `home` that
was acknowledged may still be animating, and may have had no visible effect at all:
Back with nothing to go back to, for instance. So `Inicio enviado` says the tablet
took the action, never that the launcher is on screen.

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

Origin at the top-left, x grows right, y grows down. Both ends of a swipe go
through this same conversion, each with the geometry of its own moment.

### Letterbox and pillarbox are not the picture

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
renderer's current value, and never carried over to the next gesture. The tablet
can rotate during a session and the next gesture already uses the new geometry.
Nothing hardcodes an orientation or a resolution.

What cannot be avoided: between Android rotating and the browser being told, the
picture on screen is still the old frame. A gesture in that instant is aimed at
the old frame, and Android reads its display when the command runs. It is the same
limitation the tablet documents under `SCREEN_SHARING.md#noticing-a-rotation`.

## Tap or swipe

The press is followed by `RemoteControlGestureLayer`, with raw pointer events
inside Flutter: no JavaScript and nothing on the `<video>` element.

```text
pointer down   on the picture, primary button: position, point, time and
               geometry are kept. Anywhere else: this press is ignored for good
pointer move   it may become a drag; nothing is ever sent from here
pointer up     exactly one tap, one swipe, or nothing
```

Flutter keeps delivering a pointer that is down to the widget it went down on,
wherever it goes, and the web engine listens on the window. So no capture is
needed to notice a pointer leaving the picture.

### The threshold

`RemoteControlGestureLayer.dragThreshold` is **6 logical pixels** of the surface,
measured as a straight distance from where the press started.

```text
distance <  6    a tap, where the pointer was released
distance >= 6    a drag, and it stays one
```

The tablet's resolution plays no part: the threshold is about what the technician
meant. A press held still for any length of time is still a tap.

The web does not try to predict whether a drag collapses onto one physical pixel
of the tablet. If it does, the tablet answers `gesture_rejected`, which is shown
as such and never turned into a tap.

A press that became a drag and was released **less than the threshold from where
it started** sends nothing. It is not a tap, because the technician dragged; and
a stroke of almost nothing, lasting as long as the detour did, would reach the
tablet as a long press on whatever is there.

Only the two ends are sent. A curved path arrives as a straight stroke, because
the protocol has no other kind.

### What drops a press

All of these send nothing, neither a tap nor a swipe, and the next press starts
clean.

| What happened | Why |
| --- | --- |
| it started on a band or outside the picture | even if the pointer then enters the picture |
| it left the picture, even by a pixel | **never clamped** to the edge, and **not** picked up again if it comes back |
| the aspect ratio changed | see below |
| the surface changed size | its positions no longer mean the same |
| a second pointer went down | several fingers are not a gesture the tablet has |
| another mouse button | on the press, or joining it on the way |
| the wheel moved | it scrolls the page, and positions would stop being comparable |
| the system cancelled the pointer | |
| the layer went away | see [Cleanup](#cleanup) |

Leaving the picture cancels rather than clamps because the alternative runs a
gesture different from the one the technician made: a swipe that ends somewhere
they never pointed at. Coming back does not revive it because a stroke that passed
through a band was not a stroke on the tablet.

### A rotation during the press

The ratio is compared with the one the press started with at every pointer event,
and also whenever the surface is rebuilt, because a pointer standing still reports
nothing and the ratio could be back by the time it moves. Any difference drops the
press: `start` would belong to a portrait screen and `end` to a landscape one.

The comparison is exact. A resolution change that alters the ratio slightly also
drops the press, which costs the technician one gesture and never runs a wrong one.

### The duration

```text
durationMs = clamp(pointer up time - pointer down time, 50, 2000)
```

`RemoteSwipeCommand.durationMsFor`, from the timestamps of the pointer events
themselves, so it is the time the gesture took and not the time it took to reach
this code. There is no default for a normal interaction.

```text
20 ms -> 50     50 ms -> 50     180 ms -> 180     2000 ms -> 2000     3500 ms -> 2000
```

Clamping is correct here and wrong for a coordinate: the contract defines the range
it can execute, and a different duration only changes the speed of the same stroke.
A moved coordinate would touch something else.

### A finger on the picture

A touch drag would also move the console page, which sits in a scroll view. An
otherwise empty `GestureDetector` inside the layer holds the gesture arena, so the
page stays put and only the tablet moves. A mouse never scrolled the page this way.

## When a gesture is accepted

All of them, checked twice: the surface does not listen at all unless they hold,
and the BLoC checks them again when the gesture arrives. The same for both kinds.

```text
RemoteSession ACTIVE, and not being closed    REST, through the coordinator
RTCPeerConnectionState connected              WebRtcSessionBloc
control channel open                          WebRtcSessionBloc
a remote video track                          WebRtcSessionBloc
the renderer really displaying a picture      RemoteScreenView
aimed at the current session                  the event, tap or swipe
```

The picture condition cannot be read from the track: `ontrack` fires when the
answer is applied, while the tablet may still be asking for MediaProjection
consent. So until the renderer reports a size there is no pointer layer, and the
line says `Control remoto: no disponible`.

If anything is missing nothing is sent. **Gestures are not queued** while
connecting: a touch that lands seconds later, on whatever is on screen by then, is
worse than a click that did nothing.

## Back and Home

Two buttons in the assistance block, `Atrás` and `Inicio`, below the picture and
outside its pointer layer. They do not go through `RemoteControlGestureLayer` or the
coordinate conversion, and that layer knows nothing about them.

### They need no picture

```text
                                              tap, swipe     back, home
RemoteSession ACTIVE, and not being closed    yes            yes
RTCPeerConnectionState connected              yes            yes
control channel open                          yes            yes
aimed at the current session                  yes            yes
a remote video track                          yes            no
the renderer really displaying a picture      yes            no
```

`canSendRemoteNavigation` and `canSendRemoteControl` on the state say exactly that,
and the second is the first plus the track. A tap needs a picture because its
coordinates are a position on it. A Back is a global action of Android, and the
tablet runs it whether or not it is sharing its screen.

So without a picture the buttons work while the line under the surface says
`Control remoto: no disponible`. Both are right: that line is about gestures.

While any of those conditions is missing the buttons are shown disabled, and nothing
is sent. The BLoC checks again when the event arrives.

### The settle guard

Android answers as soon as it accepts the action, with the transition still running:

```text
HOME -> ack at once -> a tap right away -> it lands on the previous screen,
                                           or on the transition
```

So for **350 ms** (`remoteNavigationSettleDuration`) from the moment a Back or Home
is sent, and for as long as it is unanswered, no new command of any kind is taken
(`RemoteNavigationGuard`). It ends when **both** have happened:

```text
accepted by Android     ack ok: true
350 ms since it was sent
```

```text
ack at  80 ms    held until 350 ms
ack at 500 ms    ends there and then, with nothing added
```

| While it holds | |
| --- | --- |
| a tap, a swipe | dropped, never queued: the surface has no pointer layer for that moment, and the BLoC drops them too |
| a press that starts then | not picked up afterwards, like any press the layer did not see begin |
| another Back or Home | the buttons are disabled, and the BLoC drops them too: a double click is one action |
| FINALIZAR ASISTENCIA | not held back |
| the picture, the channel, the peer connection, Android | untouched: frames keep arriving |

It is a guess about how long a transition takes, and it does not claim otherwise. A
slower transition can outlast it; the technician can see the picture. Nothing on the
wire tells when Android finished, and nothing is sent on the wire about the guard.

A command that was not accepted **ends it at once**, because nothing is animating:

```text
accessibility_unavailable, gesture_rejected, session_not_active,
invalid_command, unsupported_command, unknown code     at the answer
timeout                                                at its deadline
channel refused the message                            at that moment
```

The answer to an older tap or swipe, whatever it says, is not an answer to the Back,
and does not end its guard.

### What they say

The line next to the buttons follows the last command when it was one of them. The
line under the picture goes back to `Control remoto: listo`, and speaks again at the
next gesture, when this one goes quiet. There is no history.

| Situation | Back | Home |
| --- | --- | --- |
| ack pending | `Enviando Atrás...` | `Enviando Inicio...` |
| `ok: true` | `Atrás enviado` | `Inicio enviado` |
| `gesture_rejected` | `No se pudo ejecutar la acción.` | the same |
| timeout | `El dispositivo no confirmó la acción.` | the same |
| `accessibility_unavailable` | `El dispositivo no tiene habilitado el control remoto.` | the same |
| `session_not_active` | `La asistencia no está activa en el dispositivo.` | the same |
| `invalid_command`, `unsupported_command`, unknown | `Control remoto no disponible` | the same |
| anything needed is missing | nothing: the buttons are disabled | the same |

`gesture_rejected` is the protocol's name for a refused global action too. The
technician did not make a gesture, so they do not read that word.

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
| ack of an older command | settles it; says nothing about the last one |

Back and Home use this same map. The line under the picture follows the **last**
tap or swipe; there is no history, and Back and Home have
[their own line](#what-they-say).

| Situation | Tap | Swipe |
| --- | --- | --- |
| ready, nothing sent yet | `Control remoto: listo` | |
| ack pending | `Enviando toque...` | `Enviando desplazamiento...` |
| `ok: true` | `Toque enviado` | `Desplazamiento enviado` |
| `gesture_rejected` | `No se pudo ejecutar el toque.` | `No se pudo ejecutar el desplazamiento.` |
| timeout | `El dispositivo no confirmó el toque.` | `El dispositivo no confirmó el desplazamiento.` |
| `accessibility_unavailable` | `El dispositivo no tiene habilitado el control remoto.` | the same |
| `session_not_active` | `La asistencia no está activa en el dispositivo.` | the same |
| `invalid_command`, `unsupported_command`, unknown | `Control remoto no disponible` | the same |
| anything needed is missing | `Control remoto: no disponible` | the same |

### No automatic retry

A command is sent at most once, whatever happens to it. A gesture may have run
with its acknowledgement lost, so sending it again could press something twice.
A swipe that expired is not repeated either: it could scroll twice, and a Back could
leave two screens behind. The technician repeats the action if they want to.

### ACK timeout

The tablet runs one gesture at a time, up to 16 waiting behind the running one, and
a swipe may take two seconds. So a valid answer can take as long as everything sent
before it, and a fixed three second wait would report as lost a swipe that is only
behind others. Each command gets its own deadline when it is sent
(`PendingRemoteCommands.deadlineFor`, a pure function):

```text
deadline = min(work of what is still pending ahead
               + its own work
               + margin,
               45 s)

work     tap 50 ms, swipe its durationMs,
         back and home 50 ms  (remoteNavigationEstimatedWork)
margin   3 s  (WebRtcSessionBloc.defaultRemoteCommandMargin)
```

The 50 ms of a Back or Home are what it counts for in that sum, not how long Android
animates it. They have no timeout of their own.

```text
a tap alone                      3.05 s    the minimum is the margin: never under 3 s
a back or a home alone           3.05 s
a home behind a swipe of 2 s     5.05 s
a swipe of 350 ms alone          3.35 s
swipe 2 s behind a swipe of 2 s  7 s
the 17th long swipe in a row     37 s
```

**45 seconds** is the ceiling (`PendingRemoteCommands.maxDeadline`): enough for
everything the tablet accepts to hold, `17 x 2 s + 3 s = 37 s`, and beyond that the
tablet answers `gesture_rejected` rather than queue.

`ahead` is only what is still unanswered at that moment, and a deadline is never
recalculated: it can only be generous, since the tablet may already have finished
part of that work. The tablet also has a five second guard per gesture against a
bridge that never answers. A queue full of those can outlive the ceiling, in which
case the command is reported as timed out and its late ack ignored.

The timeout reports and does nothing else. The tablet sends nothing on a channel
that closed or was replaced, so an answer may never come.

## What each refusal does

```text
accessibility_unavailable   a message; the session and the picture go on
session_not_active          one GET /remote-sessions/current per refused command;
                            WebRTC is left alone; REST decides what happens
gesture_rejected            a message; never turned into a tap, never sent again
invalid_command             a log line and a message: a bug or a version mismatch
unsupported_command         idem
```

The same for Back and Home, and each of them also ends the
[settle guard](#the-settle-guard). None of them closes the `RemoteSession` or the
peer connection.

## Cleanup

```text
channel closing/closed       pending cleared at once, every kind, no deadline
                             waited for, a command still pending shown as not
                             available
session leaves ACTIVE        commands stop, pending and feedback cleared
FINALIZAR pressed            idem, at the press and not at the backend's answer;
                             a press under way is dropped with the layer;
                             a close that fails gives the control back
session id changes           idem
sign out                     idem, and the peer connection goes
peer connection failed       pending and feedback released with the negotiation
new peer connection          starts with nothing pending
```

The settle guard goes in every one of those, at once and with its timer: it never
survives into another session, peer connection or channel.

The pointer layer exists only while control is available. A pointer already down
when it goes away keeps reporting to the old layer, which ignores it, and a layer
that comes back does not pick it up: only a new press starts a gesture.

## Generations

Commands belong to the negotiation that sent them, and the existing generation
guard covers them: an ack is a peer event, so one from a replaced or closed peer
connection is dropped before it can touch anything, and a deadline carries the
generation it was started in, and so does the settle time of a Back or Home. An old
`swipe-1` can therefore not resolve a new `swipe-1`, even if a generator repeated the
id, and an old `back-1` cannot end the guard of a new one.

The default generator counts `tap-1`, `swipe-2`, `back-3`, `home-4`, ... on one
counter for as long as the page lives, and does not restart with a negotiation. It is injectable
(`RemoteControlCommandIdGenerator`), and never derives an id from coordinates or
screen content.

## Testing on a device

**Do not use mobile-mcp or anything else holding a `UiAutomation` during these
tests**: it suppresses the accessibility service, and a command would never reach
`dispatchGesture`. Use `adb logcat`, `dumpsys` and `adb exec-out screencap -p`.
The toggle and the *full control* dialog are the user's, by hand, always.

### What has been observed of Back and Home on the physical tablet

Chrome and a tablet running Android 14 (800x1280), with `remote_control_device` built
from `feature/device-remote-control-navigation` (84763a9), and the accessibility toggle
and every consent done by hand. Frames were read by wrapping `RTCDataChannel` in the
page during the test, Android's side from `adb logcat` (`RemoteControlInput`) and
`dumpsys activity`. The real buttons were clicked with the mouse, and the attempts that
needed an exact time were `PointerEvent`s dispatched on the page, which go through the
same Flutter path.

```text
tap regression: AC 7 8 in the Calculator     78, ack ok, tap completed on Android
swipe regression, Settings list              the list scrolls, ack ok
Back from a Settings sub-screen              back to the list, back accepted, ack ok,
                                             Atrás enviado
Home from Settings                           launcher in front, home accepted, ack ok,
                                             Inicio enviado
open app, Back, Home, twice, no F5           same session, channel and peer connection
ack of a Back or Home                        12 to 210 ms after it was sent
a Home answered in 20-200 ms, then a tap at
  209, 307, 336, 352, 363 ms                 nothing sent
  389, 423, 504, 704 ms                      the tap is sent
second Back or Home, tap, swipe, in the
  guard of a Back or of a Home               nothing sent; a tap at 460 ms goes out
service disabled by hand, Back and Home      ack accessibility_unavailable, no navigation,
                                             message; session and picture go on
  a tap 120 ms after that refusal            sent: the guard had ended
service enabled again                        Back and Home work, same session
MediaProjection refused by hand: ACTIVE,
  control open, no picture                   buttons enabled, a click on the surface
                                             sends nothing, Back and Home navigate
FINALIZAR during the guard of a Home         not held back, buttons disabled at once,
                                             nothing more sent, peer connection closed
every command sent against Android's log     the same count of each kind
```

Sent and acknowledged, the two ends agree: 74 commands, 66 `ok: true` and 8
`accessibility_unavailable`.

The pointer layer comes back with the next frame after the guard ends, so that is the
exact edge: 350 ms and up to one frame. In a browser window that is covered, Chrome
gave this page 2 frames per second, and taps after the guard kept being lost until a
frame came. Keep the window in front when measuring this.

Covered by automated tests only, and never seen on the device: an ack of a Back or Home
later than 350 ms, `gesture_rejected` and `session_not_active` on them, their timeout,
the channel closing during the guard, and a replaced peer connection during it.

### What has been observed on the physical tablet

Chrome and a tablet running Android 14 (800x1280), with `remote_control_device` on
`feature/device-remote-control-swipe`, and the accessibility toggle and every
consent done by hand. Frames were read by wrapping `RTCDataChannel.prototype.send`
in the page during the test, and scrolling was read from the picture and from
`adb exec-out screencap`. Some strokes were real mouse drags from the browser
extension, and those needing an exact distance or duration were `PointerEvent`s
dispatched on the page, which go through the same Flutter path.

Swipes, in the Settings list and in the overview of recent apps:

```text
tap regression: AC 7 8 in the Calculator     78, ack ok, tap completed on Android
drag up, then down, Settings list            the list scrolls both ways, ack ok
drag left, then right, recent apps           the cards move both ways, ack ok
stroke of < 50 ms, 183, 1203, 3000 ms        durationMs 50, 183, 1203, 2000
ack of a 2000 ms swipe                       2096 ms after it was sent
landscape, up and down                       scrolls, aligned
portrait -> landscape -> portrait, same
  session and peer connection                correct, without an F5
with the console page scrolled               correct
5 px                                         tap
exactly 6 px                                 swipe
pressed beside the picture, entering it      nothing sent
released beside the picture                  nothing sent
left the picture and came back               nothing sent
dragged away and brought back                nothing sent
service disabled by hand                     ack accessibility_unavailable,
                                             message, session and picture go on
service enabled again                        swipes work, same session
FINALIZAR with a swipe unanswered and a      the drag sends nothing, the ack that
  drag under way                             arrives is ignored, the peer
                                             connection closes
```

A swipe just over the threshold is a swipe on the wire, and the application under
it may still read it as a press: 6 logical pixels were about 12 physical ones here,
below Android's own touch slop, and a Calculator key registered it as a click. The
web cannot know that, and does not try.

Taps, as observed before swipes existed, with the Calculator as the target, because
a wrong key shows up in the result.

```text
keys across the whole screen, landscape      correct
keys across the whole screen, portrait       correct
portrait -> landscape -> portrait, same
  session and peer connection                correct, without an F5
a click with the page scrolled               correct
clicks beside the picture, both orientations no command, no gesture
a drag over the picture, the wheel           no command
service disabled by hand                     ack accessibility_unavailable,
                                             message, session and picture go on
service enabled again                        taps work, same session
FINALIZAR, then clicks where the picture was no command
```

Covered by automated tests only, and never seen on the device: bands inside the
pointer layer, a rotation during a press, a second pointer, the wheel during a
press, a touch drag on a touch screen, `session_not_active`, `gesture_rejected`
(including a swipe collapsing onto one pixel), the timeout, a long queue behind
several swipes, the channel closing with a command pending, and a replaced peer
connection.

## Logging

```text
tap command sent <id>            swipe command sent <id>
tap confirmed <id>               swipe confirmed <id>
tap timed out <id>               swipe timed out <id>
remote tap ignored <session>     remote swipe ignored <session>
back command sent <id>           home command sent <id>
back confirmed <id>              home confirmed <id>
back timed out <id>              home timed out <id>
remote back ignored <session>    remote home ignored <session>
remote control command rejected: <code>
control message ignored <remoteSessionId>
control ack ignored <id>
```

Coordinates and frames are not logged, here or on the tablet.
