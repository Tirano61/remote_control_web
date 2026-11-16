# Control channel — `remote_control_web`

How what the technician does on the picture becomes a gesture on the tablet (a tap, a
swipe, or a held touch that can drag, which an older tablet gets as a long press), and
what the Atrás, Inicio and Recientes buttons, the Texto dialog and the Acción button
become, seen from the web.

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
     WebRtcRemoteLongPressRequested  (its own, stricter gate)
  -> RemoteTapCommand                id from the generator
     RemoteSwipeCommand
     RemoteLongPressCommand          and RemoteSettleGuard starts now
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
Atrás, Inicio, Recientes
  -> WebRtcRemoteBackRequested       the BLoC checks its own gate
     WebRtcRemoteHomeRequested
     WebRtcRemoteRecentsRequested
  -> RemoteBackCommand               id from the same generator
     RemoteHomeCommand
     RemoteRecentsCommand
  -> PendingRemoteCommands           the same map, the same deadlines
     RemoteSettleGuard               starts now, see the settle guard
  -> RemoteControlChannelCodec
  -> `control` data channel
  -> Android performGlobalAction
  -> ack
  -> RemoteCommandFeedback           the end of the line above the buttons
```

A text joins it at the event too, and only from an explicit press in its dialog:

```text
técnico sees the field focused on the picture -> Texto -> writes -> Enviar texto
  -> RemoteTextDialog                the editor is emptied and closed right here
  -> WebRtcRemoteTextRequested       the BLoC checks its own, stricter gate
  -> RemoteSetTextCommand            id from the same generator
  -> PendingRemoteCommands           keeps the id, the kind and the work: not the text
  -> RemoteControlChannelCodec
  -> `control` data channel
  -> Android ACTION_SET_TEXT on the node with input focus
  -> ack
  -> RemoteCommandFeedback           the end of the line above the buttons
```

The IME action joins it at the event too, and only from a press of Acción:

```text
técnico sees the field focused on the picture -> Acción
  -> WebRtcRemoteImeEnterRequested   the BLoC checks the same gate as a text
  -> RemoteImeEnterCommand           id from the same generator, and nothing else
  -> PendingRemoteCommands           the same map, the same deadlines
     RemoteSettleGuard               starts now, as for a global action
  -> RemoteControlChannelCodec
  -> `control` data channel
  -> Android ACTION_IME_ENTER on the node with input focus
  -> ack
  -> RemoteCommandFeedback           the end of the line above the buttons
```

A press held still takes its own path, because it does not end when it is recognised:

```text
held still for kLongPressTimeout, pointer still down
  -> RemoteControlGestureLayer       onTouch.onHold, then every move, then the release
  -> WebRtcRemoteTouchHoldRequested  the BLoC checks the long press gate
     WebRtcRemoteTouchMoved          one event per pointer move, clamped to the picture
     WebRtcRemoteTouchReleased
     WebRtcRemoteTouchCancelled
  -> RemoteTouchSession              seq, ids, throttling, keepalive, 30 s, deadlines:
                                     not PendingRemoteCommands
  -> RemoteTouchHoldCommand ...      touch_hold, touch_move, touch_release, touch_cancel
  -> RemoteControlChannelCodec
  -> `control` data channel
  -> Android dispatchGesture, willContinue / continueStroke
  -> acks for the hold, a refused move, the release, the cancel
  -> RemoteTouchFeedback             the line under the picture
```

Presentation knows normalized coordinates, gesture intents and a status. It does
not know `RTCDataChannel`, `RTCDataChannelMessage`, `jsonEncode` or `flutter_webrtc`.

## Protocol v1

`tap`, `swipe`, `long_press`, `back`, `home`, `recents`, `set_text`, `ime_enter`, and
the four messages of a touch session, `touch_hold`, `touch_move`, `touch_release` and
`touch_cancel` (see [Hold and drag](#hold-and-drag-touch-sessions)). One text frame holding
one JSON object, on the existing `control` channel. No other channel is created.

```json
{"v":1,"type":"tap","id":"tap-1","x":0.5,"y":0.25}
```

```json
{"v":1,"type":"swipe","id":"swipe-2","startX":0.5,"startY":0.8,"endX":0.5,"endY":0.2,"durationMs":350}
```

```json
{"v":1,"type":"long_press","id":"long-3","x":0.5,"y":0.25}
```

```json
{"v":1,"type":"back","id":"back-3"}
```

```json
{"v":1,"type":"home","id":"home-4"}
```

```json
{"v":1,"type":"recents","id":"recents-5"}
```

```json
{"v":1,"type":"set_text","id":"text-6","text":"Hola mundo"}
```

```json
{"v":1,"type":"ime_enter","id":"enter-7"}
```

```json
{"v":1,"type":"touch_hold","id":"hold-9","touch":"t-8","x":0.41,"y":0.52}
{"v":1,"type":"touch_move","id":"mv-10","touch":"t-8","seq":1,"x":0.43,"y":0.55}
{"v":1,"type":"touch_release","id":"rel-14","touch":"t-8","seq":5,"x":0.6,"y":0.7}
{"v":1,"type":"touch_cancel","id":"cxl-14","touch":"t-8","seq":5}
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
for its own 50 ms. A `long_press` has `x` and `y`, the same kind of value as a tap's,
and nothing else: no `durationMs`, no end, no pointer type, no button. The tablet holds
it for `ViewConfiguration.getLongPressTimeout() + 100 ms`, its own decision. `back`, `home` and `recents` carry their id and nothing else: they
are not touches, so no coordinate and no duration means anything to them. In a
`set_text`, `text` is required and has `0..4096` UTF-16 code units. An `ime_enter`
carries its id and nothing else: no `text`, no `keyCode`, no `actionId`, no position.

An ack is valid when `v == 1`, `type == "ack"`, `id` is a non-empty string and
`ok` is a bool; with `ok: false`, `error` must also be a string. Anything else is
ignored without an exception, and a binary frame too. A failure code this version
does not know is still a failure (`RemoteControlError.unknown`): the tablet did
answer, and ignoring it would only leave the technician waiting for the timeout.

What `ok: true` promises depends on the command, because Android promises different
things:

```text
tap, swipe,          Android reported the gesture completed, not merely that it was
long_press           requested
back, home, recents  Android accepted the global action
set_text             the focused node accepted ACTION_SET_TEXT
ime_enter            the focused node accepted ACTION_IME_ENTER, and nothing about
                     what the application then did
touch_hold           the finger is still down, past Android's long press timeout, and
                     the touch goes on: nothing about what is under it
touch_move           never answered when it is taken
touch_release        the final stroke completed: Android received the end of the
                     contact, not that anything was dropped
touch_cancel         the touch is over on the tablet, cancelled or already ended
```

`performGlobalAction` returns a boolean and has no callback. A global action that was
acknowledged may still be animating, and may have had no visible effect at all: Back
with nothing to go back to, for instance. So `Inicio enviado` says the tablet took the
action, never that the launcher is on screen, and `Recientes enviado` never that the
overview has finished appearing. The field is not read back either, so `Texto enviado`
does not say what the field ended up holding: an application may filter what it is
given. `Acción enviada` does not say that a search ran, a form went, the focus moved or
the screen changed. `Pulsación prolongada enviada` does not say that a menu opened or
anything got selected: the gesture ran, and what the application made of it only the
picture can show.

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
through this same conversion, each with the geometry of its own moment, and so does
the point of a long press: a tap and a long press on the same spot send the same
`x` and `y`.

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

## Tap, swipe or long press

The press is followed by `RemoteControlGestureLayer`, with raw pointer events
inside Flutter: no JavaScript and nothing on the `<video>` element. One surface,
three gestures, and never two of them for the same press:

```text
click                       -> tap
drag                        -> swipe
hold the pointer still      -> long press
```

```text
pointer down   on the picture, primary button: position, point, time and
               geometry are kept, and the long press timer starts.
               Anywhere else: this press is ignored for good
pointer move   it may become a drag, which stops the timer; nothing is ever
               sent from here
timer fires    still down and never a drag: one long press, sent there and
               then; that pointer sends nothing else
pointer up     exactly one tap, one swipe, or nothing; nothing at all after a
               long press
```

```text
pointer down
   |
   +-- released before the timeout, without moving   -> TAP, at the release
   |
   +-- moved >= 6 px before the timeout               -> SWIPE, at the release
   |
   +-- held still for kLongPressTimeout               -> touch_hold, at once, and the
                                                         pointer is followed until it
                                                         goes up (LONG_PRESS on a tablet
                                                         that does not run touches)
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
meant. A press held still is a tap if it is released before the
[long press timeout](#long-press), and a long press if it is not.

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

All of these send nothing, neither a tap, a swipe nor a long press, and the next
press starts clean. When they happen before the long press timeout they cancel its
timer with the press.

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

### Long press

Since the [touch sessions](#hold-and-drag-touch-sessions), this is what a hold becomes on
a tablet that answered `touch_hold` with `unsupported_command`, and only there: the
legacy path, kept whole, model, codec, gate, settle guard and messages. What follows
describes it as it always worked, and the recognition is shared by both.

There is no button for it. Holding the pointer still on the picture is a long press,
with a mouse or a finger:

```text
the web decides WHEN    the technician means a long press: the pointer stayed down,
                        closer than 6 px to where it went down, for kLongPressTimeout
the device decides      how long Android holds it: getLongPressTimeout() + 100 ms.
HOW LONG                No durationMs ever goes on the wire
```

**Recognition.** `RemoteControlGestureLayer.longPressTimeout` is Flutter's own
`kLongPressTimeout` (500 ms), not a constant of this project. A `Timer` starts at pointer
down, on the picture, with the primary button, and only then.

**Movement.** The same threshold, the same distance: a straight line from where the press
started, never small moves added up. `>= 6 px` before the timeout makes it a drag, stops
the timer for good and leaves the swipe to run as before. Under 6 px, however much the
pointer trembles, the timer keeps going.

```text
down, move 2 px, move 3 px, hold          long press
down, 5.99 px away, hold                   long press
down, 6 px away before the timeout         swipe, never a long press
down, 5 px and back ten times, hold        long press: 50 px travelled, never 6 away
```

**When it fires** it checks again that the press is the same one, still down, never a
drag, with the geometry it started with and its starting point still on the picture. The
point sent is **where the press went down**, not wherever the pointer drifted to by less
than the threshold since. Then the BLoC checks everything else again, at that moment and
not at pointer down: see [when it is accepted](#a-long-press-asks-for-more). If anything
is missing the hold sends nothing, and its release is not a tap either.

**After it fires** that pointer is done. Moving it, leaving the picture, a second finger,
a cancel or the release send nothing more: no tap, no swipe, no second long press, and
no drag after the long press, which the protocol does not have. In practice the layer is
gone at once anyway, held back by the [settle guard](#the-settle-guard), and a pointer
already down is not picked up by a layer that comes back.

**Before it fires**, what drops a press drops the long press with it: the release
(which is a tap or a swipe), a cancel, a second pointer, another button, the wheel, a
rotation, a resize, leaving the picture, the layer going away. A second pointer drops
the press, as it always did: it never starts a timer of its own, never takes over the
press and never makes it multitouch.

**On a band** of `contain`, nothing: the press never starts, and neither does a timer.

#### A long press asks for more

Exactly what an `ime_enter` asks for (`canSendRemoteLongPress`):

```text
RemoteSession ACTIVE, and not being closed    yes
RTCPeerConnectionState connected              yes
control channel open                          yes
aimed at the current session                  yes
a remote video track                          yes
the renderer really displaying a picture      yes, in the BLoC too
no command pending                            yes: not even a tap
no settle guard active                        yes
```

Unlike a tap it does not queue behind another command: the hold is recognised on the
picture the technician sees, and a tap or a swipe still running could have moved it.
A hold recognised while one of these is missing is dropped, never sent later.

#### Once sent

It is tracked like any other command, and its kind `settlesScreen`, so the
[settle guard](#the-settle-guard) starts when it is sent: nothing else goes out, a tap,
a swipe, another long press, Back, Home, Recents, a text or an `ime_enter`, until it is
answered. `FINALIZAR ASISTENCIA` is not held back. The guard keeps its own rule, answered
**and** 350 ms after it was sent; the tablet answers a long press only once Android
completed it, roughly 600 ms after it went out, so in practice the answer is what ends
the wait, and nothing is added after it.

A long press may open a menu, a selection or a popup, which is why it settles at all.

Its work counts as `remoteLongPressEstimatedWork = 5 s`, the tablet's own guard over a
gesture (it takes long presses of up to 4 s), so with nothing ahead its deadline is
**8 s**. A long press that times out is reported and never sent again.

| Situation | Long press |
| --- | --- |
| recognised, ack pending | `Manteniendo pulsado...` |
| `ok: true` | `Pulsación prolongada enviada` |
| `gesture_rejected` | `El dispositivo rechazó la pulsación prolongada.` |
| `accessibility_unavailable` | `El dispositivo no tiene habilitado el control remoto.` |
| `session_not_active` | `La asistencia no está activa en el dispositivo.` |
| timeout | `El dispositivo no confirmó la pulsación prolongada.` |
| `invalid_command`, `unsupported_command`, unknown | `Control remoto no disponible` |

Never `Menú abierto` or `Elemento seleccionado`: the acknowledgement does not show that.

It carries `x` and `y` and nothing else, and its answer carries no content, node, text,
cursor, selection, package or accessibility metadata. The log has its id and, on a
refusal, the public error code.

## Hold and drag: touch sessions

A press held still is not over when it is recognised. It is one remote finger, put down
by `touch_hold`, that follows the pointer for as long as the pointer stays down, and is
lifted by `touch_release` or taken away by `touch_cancel`:

```text
web hold recognition          -> touch_hold     the finger goes down where the press started
move after the hold           -> touch_move     a stream, at most ~30 a second
up                            -> touch_release  the finger is lifted where the pointer is
cancel                        -> touch_cancel   the finger is taken away: never a release
```

```text
the web decides    WHEN there is a hold or a drag: the pointer stayed down, closer than
                   6 px, for kLongPressTimeout; it moved afterwards; it went up
the device keeps   ONE continuous Android pointer: one ACTION_DOWN, moves, one ACTION_UP
                   or ACTION_CANCEL, however many strokes it takes
```

Held still and released, it is what a long press always was on the tablet, with the
finger kept down until the technician lets go. Held and moved, it drags: a launcher icon
follows the pointer while it is down, and is dropped where it is released. There is no
Drag button, and recognition is exactly the [long press's](#long-press): the same timeout,
the same 6 px, the same point (where the press went down, not where it drifted). Before
the timeout a press is a tap or a swipe, unchanged.

### No waiting for the hold's answer

```text
touch_hold sent
   |-- keepalive starts now, not at the ack
   |-- moves go out as the pointer moves, before the ack if need be
   |-- the release goes out the moment the pointer goes up, before the ack if need be
   '-- the cancel too
```

The tablet keeps what arrives while it is still holding: the latest position and the
release. A move before the ack makes the finger move once the hold is over; a release
before the ack gives a complete long press, then the release. The acks of the hold and
of the release can therefore arrive close together, and each is matched by its own id.

### RemoteTouchSession

Not a `PendingRemoteCommand`: a touch is not one command waiting for one answer. It keeps

```text
touchId, holdId, the console pointer, generation, RemoteSession, channel identity
next seq, the initial point, the last observed point, the last sent point and when
the stage, what the hold's answer was, the support known when it started
the ids of its moves (bounded at 1024: 30 s at 30 Hz is ~900), its release, its cancel
its timers: keepalive, throttle, lifetime, answer deadline
```

and nothing else: no frame, no command after it was handed over, nothing of the screen.
Its timers only report, as `PendingRemoteCommands`'s deadlines do: what they cause
happens in its own BLoC event, guarded by generation and touch.

```text
starting     touch_hold sent, not answered        moves and keepalives go out
active       touch_hold answered ok               moves and keepalives go out
releasing    touch_release sent                   nothing goes out; its answer ends it
cancelling   touch_cancel sent                    nothing goes out; its answer ends it
dead         over, whichever way                  no timer, no id, nothing goes out
```

### Moves, keepalive and seq

```text
a move goes out      >= 33 ms after the last message sent AND >= 0.002 away from the
                     last position sent (normalized, straight distance)
otherwise            kept locally: the latest position replaces it, nothing piles up,
                     and it goes out when the 33 ms are over if it is still far enough
keepalive            the last position again, 250 ms after the last message sent,
                     from the touch_hold on, held still or not, answered or not
seq                  1, 2, 3... for every move, keepalive, release and cancel;
                     touch_hold is 0 and carries none; never reused, never lower
ids                  one per message from the usual generator: hold-N, mv-N, rel-N,
                     cxl-N; the touch is named apart, t-N, from the same counter
```

The tablet cancels a touch after 1 s without a valid message; a keepalive every 250 ms
keeps a finger held still alive. A keepalive to the pixel the finger is on moves nothing
there. The keepalive is one timer, restarted at each message, never a periodic timer
per move. It stops with the release or the cancel.

A browser sends far more than 30 pointer moves a second; at most about 30 messages a
second leave, the last of them always the latest position.

### Off the picture during a touch

Once the hold went out, a pointer that leaves the picture is **clamped** to the nearest
edge of the picture's own rectangle (`RemoteVideoGeometry.clampToPicture`), then
normalized: `x` and `y` never leave `0..1`, and a band of `contain` is the edge, never
part of the tablet's screen. That is what lets an icon be dragged to the border. It
does not cancel the touch, unlike a swipe.

Before the hold nothing changes: a press that leaves the picture is dropped, never
clamped, exactly as in [What drops a press](#what-drops-a-press).

### What cancels it

```text
PointerCancel from the browser            touch_cancel
a second pointer                          touch_cancel; one finger, never a pinch
the wheel                                 touch_cancel
another button pressed                    touch_cancel
the aspect ratio or the surface size      touch_cancel; the drag is never re-projected
  changes (a rotation)                      onto the new geometry
the surface goes away                     touch_cancel, if the channel can carry it
the picture stops being displayed         touch_cancel
30 s since the touch_hold                 touch_cancel; never a longer touch than the
                                            tablet's own limit
```

`touch_cancel` carries the next `seq` and no coordinates. Its answer ends the touch, and
nothing settles after it: nothing was dropped. Unanswered, the touch ends locally after
the same deadline as a release; the tablet's watchdog ends it on its side.

### When the channel, the peer or the session goes

```text
FINALIZAR ASISTENCIA        a touch_cancel if the channel is open, best effort and never
  (or the session leaves       awaited; the touch is gone locally at once; the close goes
   ACTIVE in any way)          on as usual
assistance terminated,      the same best-effort cancel, then the negotiation is released
  new negotiation
channel closing/closed      gone at once, nothing sent: nothing could carry it
peer failed or closed       idem
```

The tablet abandons the touch on its own in every one of these. No timer of a touch
survives its generation.

### Nothing else while it lasts

From the `touch_hold` to the answer that ends the touch, nothing else goes out: no tap,
swipe, legacy long press, Back, Home, Recents, text, `ime_enter`, and no second touch.
Back, Home and Recents are disabled, and so are Texto and Acción
(`RemoteControlStatus.isTouchActive`); the BLoC refuses them anyway. FINALIZAR is not
held back. The surface keeps listening, because it is what follows the touch's pointer.

The touch is not counted in `pendingCommands`, and none of its messages is a pending
command: it is its own kind of pending.

### Acks

| Answer | What the web does |
| --- | --- |
| `touch_hold` ok | support = supported; `Pulsación mantenida`, or `Arrastrando...` if it already moved. No settle guard: the finger is still down |
| `touch_hold` `unsupported_command` | see [the fallback](#an-older-tablet-the-legacy-long-press) |
| `touch_hold` any other error | the touch is over, its message; never retried |
| `touch_move` refused (`touch_ended`, ...) | the touch is over: timers stop, nothing more is sent, later moves of that pointer are ignored until it goes up, the controls come back; never retried |
| `touch_release` ok | the touch is over; `Arrastre finalizado` (or `Pulsación finalizada` if it never moved). Settle guard as below |
| `touch_release` error | the touch is over, its message, the settle guard released |
| `touch_cancel`, any | the touch is over; `Contacto remoto cancelado` |
| no answer to a release or a cancel in 8 s | the touch is over; a release that timed out says so |

`touch_ended` is the one code for every reason a touch can end on the tablet; the web
says *El contacto remoto terminó antes de completar la acción.* and does nothing else.
After a cancel, a refusal of the hold or of a move is expected and ignored: the cancel's
own answer ends it.

### The settle guard

Not at the hold: the touch goes on. The release `settlesScreen`, exactly like a long press
did: the guard starts when the release is sent and ends at
`max(its ack, release sent + 350 ms)`. A cancel does not settle. Keepalives and moves are
never held back by anything while the touch lasts.

### An older tablet: the legacy long press

```text
unknown       the first hold of a negotiation goes out as touch_hold
supported     a touch_hold was answered ok
unsupported   a touch_hold was answered unsupported_command
```

Per negotiation, and forgotten with the peer connection, the generation, the
`RemoteSession` and the channel. Nothing but those two answers teaches it: not a timeout,
`accessibility_unavailable`, `session_not_active`, `gesture_rejected`, `touch_ended` or a
closed channel. No `capabilities` message exists or was added.

On `unsupported_command`:

```text
1  support = unsupported for this negotiation
2  the touch ends here; nothing is cancelled on the tablet, where it never ran
3  if the hold was real (not cancelled): exactly one long_press, where the press started
4  every later hold of the negotiation is a long_press straight away, without a touch_hold
```

The older tablet did not run the `touch_hold`, so this never produces two long presses.
A hold that moved while the answer was on its way still gets the long press where it
started: **an older tablet cannot drag**, and nothing simulates a drag with a swipe. The
moves and the release it was sent are answered too, and ignored. From then on a hold is
the [legacy long press](#long-press), and moving after it sends nothing.

### What it says

| Situation | Line under the picture |
| --- | --- |
| `touch_hold` sent | `Manteniendo pulsado...` |
| `touch_hold` ok, not moved | `Pulsación mantenida` |
| moves went out | `Arrastrando...` |
| `touch_release` sent | `Soltando...` |
| `touch_release` ok | `Arrastre finalizado`, or `Pulsación finalizada` if it never moved |
| `touch_cancel` sent / answered | `Cancelando contacto remoto...` / `Contacto remoto cancelado` |
| `touch_ended` | `El contacto remoto terminó antes de completar la acción.` |
| `accessibility_unavailable` | `El dispositivo no tiene habilitado el control remoto.` |
| `session_not_active` | `La asistencia no está activa en el dispositivo.` |
| `gesture_rejected` | `El dispositivo rechazó el contacto remoto.` |
| release unanswered | `El dispositivo no confirmó el final del contacto remoto.` |

Never `Objeto tomado`, `Elemento seleccionado`, `Objeto movido correctamente` or
`Drop aceptado`: no acknowledgement says that, only the picture does.

## When a gesture is accepted

All of them, checked twice: the surface does not listen at all unless they hold,
and the BLoC checks them again when the gesture arrives. The same for a tap and a
swipe; a long press asks for
[a little more](#a-long-press-asks-for-more).

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

## Back, Home and Recents

Three buttons in the assistance block, `Atrás`, `Inicio` and `Recientes`, below the
picture and outside its pointer layer. They do not go through
`RemoteControlGestureLayer` or the coordinate conversion, and that layer knows nothing
about them.

### The bar stays on screen

The buttons, `Atrás`, `Inicio`, `Recientes`, `Texto` and `Acción`, and
`FINALIZAR ASISTENCIA` are one bar, right under the picture and
never on top of it: there it would cover part of the tablet and take clicks from the
pointer layer. The rest of the block, the diagnostics, goes below the bar.

```text
ASISTENCIA REMOTA
device name  public id
+-----------------------------------------------+
|                    picture                    |
+-----------------------------------------------+
gestures: Control remoto: listo   Recientes enviado
[Atrás] [Inicio] [Recientes] [Texto] [Acción]   [FINALIZAR ASISTENCIA]
Estado, Canal de asistencia, Conexión remota
```

It used to be a share of the window, 70%, which at 855 px left the buttons under the
fold. Now everything that has to stay on screen shares one budget, in
`_LiveAssistance`:

```text
budget = max(window height - 154 - 16, 360)

154   the app bar, the paddings of the page and the section, and the section's title
16    so that the bar never touches the edge of the window
360   the floor: in a very low window the bar has to be scrolled to anyway, and a
      picture of nothing would help nobody
```

Inside it, a `Column` lays out first what is not the picture: an error banner if there
is one, the device line, the status line and the bar, whatever each of them takes at
this width. The picture gets what is left, up to 900 px, and `RemoteScreenView` takes
the largest box of the video's proportions that fits. So nothing has to guess how many
rows the bar wrapped into, and an error banner takes its height from the picture.

The picture stays `contain`, with its own proportions: only its size changes, and the
pointer conversion reads the size at every event. A window resized during a press drops
that press, like any surface that changed size.

When the buttons do not fit one row they wrap, and `FINALIZAR ASISTENCIA` goes to its
own. Their horizontal padding is 10 px so that, with `Acción` added, the whole bar still
takes a single row in a 1280 px window.

### They need no picture

```text
                                              tap, swipe     back, home, recents
RemoteSession ACTIVE, and not being closed    yes            yes
RTCPeerConnectionState connected              yes            yes
control channel open                          yes            yes
aimed at the current session                  yes            yes
a remote video track                          yes            no
the renderer really displaying a picture      yes            no
```

`canSendRemoteNavigation` and `canSendRemoteControl` on the state say exactly that,
and the second is the first plus the track. A tap needs a picture because its
coordinates are a position on it. A global action is not a position, and the tablet
runs it whether or not it is sharing its screen.

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

An IME action is the same kind of thing: Android accepts `ACTION_IME_ENTER` at once,
and the application may then start a search, move the focus or open another screen.

A long press likewise: it may open a menu, a selection or a popup.

So for **350 ms** (`remoteSettleDuration`) from the moment a global action, an
`ime_enter` or a `long_press` is sent, and for as long as it is unanswered, no new command of any kind is
taken (`RemoteSettleGuard`, formerly `RemoteNavigationGuard`: one guard, one 350 ms, for
every command whose kind `settlesScreen`). It ends when **both** have happened:

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
| a tap, a swipe, a long press | dropped, never queued: the surface has no pointer layer for that moment, and the BLoC drops them too |
| a press that starts then | not picked up afterwards, like any press the layer did not see begin |
| another Back, Home or Recents | the buttons are disabled, and the BLoC drops them too: a double click is one action |
| a text, an IME action | the buttons are disabled, and the BLoC drops them too |
| FINALIZAR ASISTENCIA | not held back |
| the picture, the channel, the peer connection, Android | untouched: frames keep arriving |

It is a guess about how long a transition takes, and it does not claim otherwise. A
slower transition can outlast it; the technician can see the picture. Nothing on the
wire tells when Android finished, and nothing is sent on the wire about the guard.

A command that was not accepted **ends it at once**, because nothing is animating:

```text
accessibility_unavailable, gesture_rejected, session_not_active,
text_target_unavailable, ime_action_unavailable,
ime_action_rejected, invalid_command,
unsupported_command, unknown code                      at the answer
timeout                                                at its deadline
channel refused the message                            at that moment
```

The answer to an older tap or swipe, whatever it says, is not an answer to the Back,
and does not end its guard.

### What they say

The end of the line under the picture, right above the buttons, follows the last command
when it was one of them. It is not among the buttons so that a message coming and going
never moves one from under the pointer. The start of that line goes back to
`Control remoto: listo`, and speaks again at the next gesture, when this one goes quiet.
There is no history.

| Situation | Back | Home | Recents |
| --- | --- | --- | --- |
| ack pending | `Enviando Atrás...` | `Enviando Inicio...` | `Enviando Recientes...` |
| `ok: true` | `Atrás enviado` | `Inicio enviado` | `Recientes enviado` |
| `gesture_rejected` | `No se pudo ejecutar la acción.` | the same | the same |
| timeout | `El dispositivo no confirmó la acción.` | the same | the same |
| `accessibility_unavailable` | `El dispositivo no tiene habilitado el control remoto.` | the same | the same |
| `session_not_active` | `La asistencia no está activa en el dispositivo.` | the same | the same |
| `invalid_command`, `unsupported_command`, unknown | `Control remoto no disponible` | the same | the same |
| anything needed is missing | nothing: the buttons are disabled | the same | the same |

`gesture_rejected` is the protocol's name for a refused global action too. The
technician did not make a gesture, so they do not read that word.

## Text

`set_text` replaces the **whole content** of whichever field has input focus on the
tablet. It names no field: the web receives neither the name of the field, its current
content, its application nor a node id, and asks for none of them.

### Always explicit

```text
TAP on the field -> the technician sees it focused -> Texto -> writes -> Enviar texto
```

An acknowledged tap says the touch was delivered, not that the application has moved
the focus yet, and a text sent in that instant could find no focus or replace the
content of the previous field. So nothing tries to infer it: there is **no text sent
after a tap, no fixed delay, and no chain of any kind**. The confirmation is the
technician looking at the picture, and the dialog tells them to.

### When it is available

More than the tablet asks for, on purpose.

```text
                                              back, home,   tap,    set_text
                                              recents       swipe
RemoteSession ACTIVE, and not being closed    yes           yes     yes
RTCPeerConnectionState connected              yes           yes     yes
control channel open                          yes           yes     yes
aimed at the current session                  yes           yes     yes
a remote video track                          no            yes     yes
the renderer really displaying a picture      no            yes     yes, in the BLoC too
no global action settling                     yes           yes     yes
no text unanswered                            yes           yes     yes
nothing else pending                          no            no      yes
```

**The device capability does not require video; the web UX deliberately does.** The
tablet knows which node has input focus and the web knows nothing about it, so the
picture is the only way the technician has to check where the text lands.
`canSendRemoteText` says that on the state, and `RemoteScreenView` tells the BLoC
whether its renderer is displaying a picture (`WebRtcRemotePictureChanged`), so that
condition is checked twice like the others.

**Nothing pending ahead of it**, because a swipe or a Back still running could move the
focus away from the field the technician saw. It is checked when the button is enabled
and again when the event arrives, and the text is never put in a queue behind them.

Missing any of them, the button is disabled. A request that arrives anyway is dropped,
reported as `No se pudo enviar el texto.` and not given back: the technician writes it
again. Privacy over convenience, in this first version.

### While it is unanswered

No tap, no swipe, no Back, Home or Recents, and no other text: everything is dropped,
never queued. `FINALIZAR ASISTENCIA` is not held back, and the picture, the channel and
the peer connection are untouched.

It ends the moment the text is resolved, with **no settle time**: the 350 ms are about
an animated transition, and a text has none.

```text
ack ok, text_target_unavailable, text_rejected, accessibility_unavailable,
session_not_active, any other refusal           at the answer
timeout                                         at its deadline
channel refused the message                     at that moment
channel closed, peer failed, session closed     at that moment
```

### The dialog

`Texto` sits with the other buttons in the bar. `RemoteTextDialog` shows
`Enviar texto al campo enfocado`, asks the technician to confirm the field on the
picture, and warns that the content will be replaced. It never claims to know the
content.

```text
Enviar texto    needs at least one character, and at most 4096
Vaciar campo    sends "" and asks nothing else: the label says what it does
Cancelar, Esc   sends nothing
```

**It has no barrier and no route.** It sits over the side of the picture, inside the
widget that owns the picture and the bar:

| Why | |
| --- | --- |
| the picture stays bright and visible | it is what the technician is told to check. The dialog sits at the right of the section, so it covers the right edge of a portrait picture and more of a landscape one; a field it covers has to be checked before opening it |
| FINALIZAR ASISTENCIA stays reachable | it is never held back, and a barrier would have had to let it through |
| it ends with its owner | no route can be left behind by a session that ended or by a sign out |

Having no barrier, it holds back the rest itself: while it is open the picture has no
pointer layer and the other buttons are disabled, so nothing the technician does moves
the focus they confirmed. The person holding the tablet can still move it, and the web
cannot see that happen except on the picture.

**It closes, and its text goes, as soon as a text could not be offered**, whichever
comes first:

```text
FINALIZAR pressed (at the press)        the session closed from the tablet
sign out                                a peer connection failed or was replaced
the connection interrupted              the channel closed
the picture gone                        another session
```

Android rotating does not close it, as long as the renderer keeps displaying: only the
proportions changed.

### Length

Dart's `String.length` counts UTF-16 code units, the same as the contract, so an emoji
may count as two. It is checked with exactly that (`RemoteSetTextCommand.fits`), and not
with `LengthLimitingTextInputFormatter`, which counts differently and would cut a paste
without saying so.

```text
counter    123 / 4096
over it    an error, Enviar texto disabled, and nothing cut
```

The text goes out as it was written. No trimming, no Unicode normalization, no change of
case. Accents, emoji, spaces and line breaks are ordinary text. A line break is part of
the string, not a remote Enter.

### What it says

The end of the line under the picture, like Back, Home and Recents.

| Situation | |
| --- | --- |
| ack pending | `Enviando texto...` |
| `ok: true` | `Texto enviado` |
| `text_target_unavailable` | `No hay un campo de texto editable enfocado.` |
| `text_rejected` | `El dispositivo rechazó el texto.` |
| `accessibility_unavailable` | `El dispositivo no tiene habilitado el control remoto.` |
| `session_not_active` | `La asistencia no está activa en el dispositivo.` |
| `gesture_rejected`, too many commands queued | `No se pudo ejecutar la acción.` |
| timeout | `El dispositivo no confirmó el texto.` |
| could not be handed to the channel | `No se pudo enviar el texto.` |
| `invalid_command`, `unsupported_command`, unknown | `Control remoto no disponible` |

The text itself appears in none of them. After any failure the technician focuses the
field on the picture, opens Texto again and writes it again.

### Remote text privacy

The text may be a password, a token or personal data, and the web does not know which:
it does not try to detect a password field, and does not ask the tablet.

```text
the web does not receive     what the field holds, or any metadata of the node
it does not persist          SharedPreferences, localStorage, sessionStorage, the URL,
                             the state of a BLoC, history or analytics
it does not log              the text, the frame, the controller, or a command printed
it does not show             the text, once it has been sent
```

The text has to cross the `control` channel to reach the tablet, which is the operation
itself. It is not deliberately kept after that:

```text
in the editor        emptied at the press of Enviar or Vaciar, without waiting for the
                     ack, and at Cancelar; gone when the dialog is removed for any reason
in the event         handed to the BLoC and not stored
in the command       gone once handed to the channel
while waiting        PendingRemoteCommand: id, kind and estimated work, and no text;
                     the deadline closes over the id alone
```

A failed send never brings it back. Dart strings cannot be wiped, so "gone" means no
longer referenced, not overwritten: until the garbage collector runs it may still be
in the memory of the page.

The browser is kept out of the editor with `autocorrect: false`,
`enableSuggestions: false` and `autofillHints: null`. **Null, not left out.** The default
of `TextField` is an empty list, which still enables autofill: the textarea gets
`autocomplete="on"` inside a form, and the web engine leaves that element in the page,
**with the text in it**, after the widget is gone, waiting for an autofill context to end.
Emptying the controller does not reach it, because the connection is already closed.
This only shows in a browser, so a test holds the `null` in place.

## IME action (Acción)

`ime_enter` runs the IME action of whichever field has input focus on the tablet:
Android's `ACTION_IME_ENTER` on that node. The web presents it as **Acción**.

**It is not "press Enter".** No key is simulated and nothing is written. The field runs
the action it declares for the keyboard's action key, which may look like `Buscar`, `Ir`,
`Siguiente`, `Enviar`, `Listo` or something of the application's own. **The web does not
know which one**, and does not ask: the tablet sends no label, no field name, no content,
no package and no password state, and the frame carries the id and nothing else.

### Always explicit

```text
TAP on the field -> the technician sees it focused -> (Texto) -> Acción
```

The only way an `ime_enter` goes out is a press of `Acción`. There is **no action sent
after a tap, none after a text, acknowledged or not, no fixed delay and no chain**. A tap
says nothing about where the focus ended up, and a text sent is not a request to submit
it. Tests hold this in place for both.

### When it is available

Exactly what a text asks for, for the same reason (`canSendRemoteImeEnter`):

```text
RemoteSession ACTIVE, and not being closed    yes
RTCPeerConnectionState connected              yes
control channel open                          yes
aimed at the current session                  yes
a remote video track                          yes
the renderer really displaying a picture      yes, in the BLoC too
no global action or IME action settling       yes
no text unanswered                            yes
nothing else pending                          yes
the text dialog closed                        yes
```

**The tablet would run it with no picture at all; the web deliberately does not.** The
action lands on whichever field has focus, and may search, move to another field or send
something: the picture is the only way the technician has to check which field that is.
So without video `Acción` is disabled while `Atrás`, `Inicio` and `Recientes` still work.

**Nothing pending ahead of it**: a tap, a swipe, a text or a global action still running
could move the focus away from the field the technician saw. It is never queued behind
them: the button is disabled, and a request that arrives anyway is dropped, with no id
taken and nothing reported.

### The guard

From the moment it is sent, the [settle guard](#the-settle-guard): no tap, swipe, Back,
Home, Recents, text or second `ime_enter` goes out, and none is queued.
`FINALIZAR ASISTENCIA` is not held back.

```text
ack ok at  40 ms     held until 350 ms
ack ok at 600 ms     ends at 600 ms

ime_action_unavailable, ime_action_rejected, text_target_unavailable,
accessibility_unavailable, session_not_active, any other refusal    at the answer
timeout                                                            at its deadline
channel refused the message                                        at that moment
channel closed, peer failed, session closed, FINALIZAR, sign out   at that moment
```

A refusal ends it at once: Android did not take the action, so nothing is moving.
Nothing is ever sent again on its own.

### Timeout

`performImeEnter` goes through the same accessibility bridge as a text, with the same
five second guard on the tablet (`gestureTimeout`), so it counts as
`remoteImeEnterEstimatedWork = 5 s`. With nothing ahead and the 3 s margin, its deadline
is always **8 s**, under the 45 s ceiling.

### What it says

| Situation | |
| --- | --- |
| ack pending | `Ejecutando acción...` |
| `ok: true` | `Acción enviada` |
| `text_target_unavailable` | `No hay un campo de texto editable enfocado.` |
| `ime_action_unavailable` | `El campo enfocado no ofrece una acción de teclado.` |
| `ime_action_rejected` | `El dispositivo rechazó la acción del campo.` |
| `accessibility_unavailable` | `El dispositivo no tiene habilitado el control remoto.` |
| `session_not_active` | `La asistencia no está activa en el dispositivo.` |
| timeout | `El dispositivo no confirmó la acción.` |
| could not be handed to the channel | `No se pudo enviar la acción.` |
| `invalid_command`, `unsupported_command`, unknown | `Control remoto no disponible` |

Never `Búsqueda ejecutada`, `Mensaje enviado` or `Enter presionado`: the web does not
know what the action was or what it did. The button's tooltip says what it does without
claiming to know which action it is: `Ejecuta la acción disponible del campo enfocado,
por ejemplo Buscar, Ir, Siguiente o Enviar.`

`text_target_unavailable` is shared with the text, because the target is the same: no
window, nothing with input focus, or a focused node that is not editable or enabled.
`ime_action_unavailable` is different: the field is there and is fine, and declares no
IME action. Not every `EditText` exposes `ACTION_IME_ENTER`, and below Android 11 none
does.

### Privacy

An `ime_enter` carries no text, and its answer carries no content, label or metadata of
the node. The log has its id and, on a refusal, the public error code: nothing else.

## Pending commands

```text
commandId -> what is kept of the command (id, kind, work), with its deadline
```

The command object is not kept, so a text is not either.

| Event | Result |
| --- | --- |
| ack for a pending id | settles only that command |
| ack for an unknown id | ignored |
| second ack for an id | ignored |
| ack after the timeout | ignored; the timeout stands |
| ack of an older command | settles it; says nothing about the last one |

Back, Home and Recents use this same map. The line under the picture follows the
**last** tap or swipe; there is no history, and the global actions have
[their own end of it](#what-they-say).

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
leave two screens behind. A text that expired may well have landed, and sending it
again could overwrite a field that has changed since. The technician repeats the
action if they want to.

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
         back, home and recents 50 ms  (remoteNavigationEstimatedWork)
         set_text 5 s  (remoteSetTextEstimatedWork)
         ime_enter 5 s  (remoteImeEnterEstimatedWork)
         long_press 5 s  (remoteLongPressEstimatedWork)
margin   3 s  (WebRtcSessionBloc.defaultRemoteCommandMargin)
```

The 50 ms of a global action are what it counts for in that sum, not how long Android
animates it. They have no timeout of their own. The 5 s of a text are the guard the
tablet has over that operation: an application that stopped responding can legitimately
hold it that long. Since a text goes out with nothing ahead, its deadline is always
8 s.

```text
a tap alone                      3.05 s    the minimum is the margin: never under 3 s
a back, a home or a recents alone  3.05 s
a home behind a swipe of 2 s     5.05 s
a swipe of 350 ms alone          3.35 s
a text                           8 s
an ime_enter                     8 s
a long_press                     8 s
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
text_target_unavailable     a message; never sent again: the technician focuses the
                            field and writes it again
text_rejected               idem
ime_action_unavailable      a message; never sent again, nothing stands in for it
ime_action_rejected         idem
touch_ended                 the touch is over, a message; never retried, no new touch
                            started on its own
```

The same for a long press, Back, Home, Recents and `ime_enter`, and each of them also ends the
[settle guard](#the-settle-guard). `gesture_rejected` on a text means the tablet's queue
was full. None of them closes the `RemoteSession` or the peer connection.

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

A touch session goes with its channel, its peer connection, its session and its
generation, every timer included, with a best-effort `touch_cancel` when the channel is
still open: see [When the channel, the peer or the session goes](#when-the-channel-the-peer-or-the-session-goes).
The support learned for touches goes with them.

The long press timer belongs to the press, and goes with it: at the release, a cancel,
anything that drops the press, and when the layer is disposed. The layer is disposed when
the session leaves `ACTIVE`, FINALIZAR is pressed, the peer connection fails, `control`
closes, the negotiation is replaced, the picture goes away or a settle guard starts. No
timer outlives it, and the BLoC checks the gate again anyway when a long press arrives.

## Generations

Commands belong to the negotiation that sent them, and the existing generation
guard covers them: an ack is a peer event, so one from a replaced or closed peer
connection is dropped before it can touch anything, and a deadline carries the
generation it was started in, and so does the settle time of a global action. An old
`swipe-1` can therefore not resolve a new `swipe-1`, even if a generator repeated the
id, and an old `back-1`, `recents-1` or `enter-1` cannot end the guard of a new one.

The default generator counts `tap-1`, `swipe-2`, `long-3`, `back-4`, `home-5`,
`recents-6`, `text-7`, `enter-8`, `t-9`, `hold-10`, `mv-11`, `rel-12`, `cxl-13`, ... on one
counter for as long as the page lives, and does not restart with a negotiation. It is injectable
(`RemoteControlCommandIdGenerator`), and never derives an id from coordinates or
screen content.

## Testing on a device

**Do not use mobile-mcp or anything else holding a `UiAutomation` during these
tests**: it suppresses the accessibility service, and a command would never reach
`dispatchGesture`. Use `adb logcat`, `dumpsys` and `adb exec-out screencap -p`.
The toggle and the *full control* dialog are the user's, by hand, always.

### What has been observed of touch sessions on the physical tablet

Chrome and the LUCKYSTAR T10A (**Android 16**, SDK 36, 1200x1920), with a debug
`remote_control_device` built from `feature/device-remote-control-drag` (4a1f34f) against
the LAN backend (`http://192.168.18.101:3000`) and installed with `adb install -r` (SHA-256
`8b6751e3...75b2`), which kept its enrolment (645-589-107). The web ran from
`feature/web-remote-control-drag`, release build served from `build/web`. PERMITIR, the
screen-sharing dialog, the accessibility toggle and the rotation were done by hand; no
mobile-mcp and nothing holding a `UiAutomation`. Frames were read by wrapping
`RTCDataChannel` in the page (type, id, `touch`, `seq`, coordinates rounded to 3 decimals,
and the ack). Holds and drags were driven with pointer events dispatched in the page on
the real picture, through the production gesture layer; taps, swipes and the buttons were
real clicks. Android's side from `adb exec-out screencap -p` and `dumpsys`.

```text
disclosure before PERMITIR      "Tocar, mantener pulsado, deslizar y arrastrar elementos
                                 sobre la pantalla." with the other four lines
tap on Settings (dock)          tap-9 only, ack ok 67 ms later, Settings opened
drag up on the launcher         swipe-11 only, at the release; the app drawer opened
hold 1.5 s still, wallpaper     touch_hold hold-3 502 ms after pointer down; keepalives
                                seq 1, 2 at 753, 1004 ms; hold ok at 1052 ms; seq 3; release
                                seq 4 at pointer up, ok 66 ms later; the launcher's
                                wallpaper menu; "Pulsación finalizada"; 0 tap, 0 long_press
drag Gemini two columns right   hold 503 ms, first real move 1003 ms, BEFORE the hold's ok
  (page 1, row of Gemini)       (1029 ms); 47 touch_move; touch_release 1 ms after pointer
                                up, ok 34 ms later; the icon followed the pointer while it
                                was down (launcher in drag mode, "Quitar" on top) and was
                                dropped two columns right
progressive movement            frames at ~1.4 / 2.0 / 2.7 / 3.4 s of another drag: the
                                icon moves with the pointer, before any release
cancel during a drag (Meet)     the launcher showed Meet over the free cell 5; pointercancel
                                -> touch_cancel cxl-333 seq 37, no coordinates, ok 47 ms
                                later; Meet went back to cell 2: NOTHING DROPPED;
                                "Contacto remoto cancelado"
after the cancel                tap-334 (Settings opened), home-335, a long press
                                (hold-337 / rel-341, both ok) and further drags: all normal,
                                same session, no finger left down
cancel while held still         touch_cancel cxl-375 seq 4, ok 18 ms; no tap, no drop
keepalive 3.5 s still, then     11 keepalives in the 3.5 s, at most 252 ms apart, no
  drag                          touch_ended; the drag that followed still moved the icon
10 short drags (central icon)   10 touch_hold, 170 touch_move, 10 touch_release; 10/10
                                hold ok, 10/10 release ok; 0 touch_ended, 0 tap, 0 swipe,
                                0 long_press; the icon stayed in its cell
final frame                     the picture showed exactly the T10A's layout
rotation during a still hold    the tablet answered keepalive mv-704 touch_ended (display
                                changed); nothing else sent for it; the picture turned
                                1920x1200; 0 drop; the line said "El contacto remoto
                                terminó antes de completar la acción."; a hold in landscape
                                worked (hold-706 / rel-709 ok)
accessibility off by hand       touch_hold hold-712 answered accessibility_unavailable in
                                15 ms; no touch created, nothing else sent; the message;
                                session and picture went on; on again: holds ok
FINALIZAR during a drag         "Arrastrando...", Atrás..Acción disabled, FINALIZAR enabled;
                                the click -> touch_cancel cxl-794 seq 21 1 ms later, ok
                                17 ms later; session closed, channel closed, no media
                                projection, the capture indicator gone; no drop; the
                                later pointer up sent nothing; touched by hand afterwards,
                                the tablet responded normally
```

The cancel by mismatch, the device's workaround for a pointer kept down by
`willContinue`, is what these frames and pictures show working: `touch_cancel` never
dropped anything and never left the pointer held.

What the launcher, not the protocol, did, and what the technician will meet on it:

```text
drop cell        while dragging, Launcher3 shrinks the workspace around its centre and
                 draws the icon off the finger; the cell it drops on is its own reading,
                 so a drag of one column from a side column can fall back in place, and
                 releasing at the starting point of a side icon moved it one column
page change      holding an icon near an edge for about a second turns the page; holding
                 longer turns two; a drop then lands on that page, or goes back
widget           a long press released on the clock widget leaves it in resize mode
```

Those drags reorganised the tablet's home screen (Gemini and Play Store ended up in other
rows); the owner chose to leave it that way. Nothing was removed, uninstalled or sent to
the top drop targets.

Not reproduced on the device: the fallback to `long_press` (no tablet without touch
sessions is available, and the T10A was not downgraded), the 30 s limit, a peer
connection or channel failing during a touch. The automated tests cover them.

Two things seen that are about the test, not the product. A pointer event dispatched with
`pointerType: 'mouse'` shares Flutter web's single mouse device with the real mouse: the
real mouse moving with no button while the dispatched one was "down" made the engine
synthesize an up, which the surface rightly sent as a release where the real mouse was
(clamped to `1, 0`). With a real mouse that cannot happen; the rest of the holds were
dispatched as `touch`. And a page resize in the middle of a hold dropped the press before
its timeout, which is the geometry rule doing its job.

Also seen, outside this stage: after PERMITIR the console did not show the request as
accepted until ACTUALIZAR was pressed.

### What has been observed of the long press on the physical tablet

Chrome and the LUCKYSTAR T10A (**Android 16**, SDK 36, 1200x1920 portrait), with a debug
`remote_control_device` built from `feature/device-remote-control-long-press` (66b62c8)
against the LAN backend (`http://192.168.18.101:3000`) and installed with `adb install -r`
(SHA-256 `ad48df5b...0db0`), which kept its enrolment (645-589-107). The web ran from
`feature/web-remote-control-long-press`, served from `build/web`. PERMITIR, the
screen-sharing dialog, the accessibility toggle and the rotation were done by hand. Frames
were read by wrapping `RTCDataChannel` in the page (type and id, and the whole frame for
`long_press` and its ack). Holds were driven with pointer events dispatched in the page on
the real picture, because a hold of a set length is not something a click tool does; taps
and the buttons were real clicks. Android's side from `dumpsys` and
`adb exec-out screencap -p`.

```text
disclosure before PERMITIR          "Tocar, mantener pulsado y deslizar sobre la pantalla."
                                    with the other four lines, buttons on screen
hold 1.2 s on Settings (launcher)   {"v":1,"type":"long_press","id":"long-2",
                                     "x":0.8922942206654991,"y":0.882661996497373}
                                    sent 502 ms after pointer down, while still down;
                                    {"v":1,"type":"ack","id":"long-2","ok":true} 525 ms
                                    later; "Pulsación prolongada enviada"; the launcher's
                                    menu (Información de app, Widgets, Wi-Fi, Batería) on
                                    the tablet and, still, on the picture
release at 1204 ms                  nothing sent; the launcher stayed on top: no tap
short click on Settings             tap-4 only, ack ok in 69 ms, Settings opened
drag up on the launcher             swipe-6 only, at the release; the app drawer opened
hold on Chrome with 2-5 px of noise long-8 at 503 ms, at the point it went down; Chrome's
                                    menu (Nueva pestaña, incógnito)
10 holds in a row, Back between     10 long_press, 10 ack ok, sent at 501-503 ms and
  (dock icons and Gemini)           answered 517-523 ms later; 0 tap, 0 swipe, no double;
                                    the launcher on top at the end, no menu left open
landscape, hold on Calendar         long-30 x 0.5, y 0.822 = (960, 987) of 1920x1200: the
                                    icon's centre; Calendar's menu (Nuevo evento, Nueva
                                    tarea); no tap after
service disabled by hand, hold      accessibility_unavailable 16 ms after it was sent, the
                                    message, no effect; session, picture, channel go on
service enabled again, hold         long-33 ack ok, menu shown
FINALIZAR 216 ms after long-35      the session closed and the channel with it; nothing
  went out, before its ack          sent afterwards; no media projection left
FINALIZAR 267 ms after pointer      nothing sent at all, before or after the release at
  down, held until 2 s              2 s; the session closed, channel closed, no media
                                    projection, the capture indicator gone
```

The recognition time on the web was `kLongPressTimeout`, 500 ms, plus a frame. Android's
own duration (`getLongPressTimeout() + 100 ms`) is what the roughly 520 ms between the frame
and its `ok` are made of: the device answers once `dispatchGesture` completed.

`gesture_rejected` was **not reproduced on the device**: nothing natural and safe makes
Android cancel a single-point gesture, and no hook was built for it. The automated tests
cover it.

### What has been observed of the IME action on the physical tablet

Chrome and a LUCKYSTAR T10A running **Android 16** (SDK 36, 1200x1920 portrait), with a
debug `remote_control_device` built from its `main` (cf23d85, which merges
`feature/device-remote-control-ime-enter` and then `feature/device-ime-enter-disclosure`)
against the LAN backend and installed with `adb install -r` (SHA-256 `2888bc8f...917d2d`).
The tablet had never been enrolled: a new Device was created with `POST /devices` and
`POST /devices/:id/enrollment`, and activated on the tablet with its `publicId` and code.
The accessibility toggle, PERMITIR and the screen-sharing dialog were done by hand. The web
ran from `feature/web-remote-control-ime-enter`. One `RemoteSession` for the commands, with
no F5. Frames were read by wrapping `RTCDataChannel` in the page (type and id only, and the
whole frame for `ime_enter` and its ack); Android's side from `dumpsys` and
`adb exec-out screencap -p`. The buttons were clicked with the mouse, except where noted.

```text
disclosure before PERMITIR (second request)   five lines, the fifth "Usar la acción disponible
                                              del teclado en el campo seleccionado, por ejemplo
                                              Buscar, Ir, Siguiente o Enviar.", all of it and
                                              both buttons on screen without scrolling
regressions, same session: Home, swipe up on
  the launcher, Back, tap on Settings         the real effect, ack ok (28 to 461 ms)
tap on "Buscar en Configuración", 6 s         field focused, keyboard up with its search key;
                                              no ime_enter sent
set_text "wifi", then 7 s                     "wifi" in the field, results listed, ack ok in
                                              103 ms; no ime_enter sent
Acción                                        {"v":1,"type":"ime_enter","id":"enter-7"}
                                              {"v":1,"type":"ack","id":"enter-7","ok":true}
                                              in 62 ms, "Acción enviada"; Settings ran its
                                              search action: the keyboard closed
                                              (mInputShown=false) and the results took the
                                              whole screen, on the tablet and on the picture
Acción again on the same field                text_target_unavailable: the search action had
                                              taken the input focus away from the field
Acción on the launcher                        text_target_unavailable in 36 ms, "No hay un
                                              campo de texto editable enfocado.", nothing else
service disabled by hand, Acción              accessibility_unavailable in 25 ms, the message,
                                              no effect; session, picture and channel go on
service enabled again                         Home, tap, Back work, same session
Acción on an empty search field               ack ok, nothing visible: Settings does nothing
                                              with an empty query
```

The settle guard, driven with pointer events dispatched in the page on the real buttons and
picture, because the answer is faster than a hand:

```text
ack ok at 50 ms     Inicio 111, Atrás 162, Recientes 211, tap 245, drag 266, Texto 305,
                    Acción 337 ms: nothing sent; Acción at 475 ms sent
ime_enter frame held 500 ms in the page, ack ok at 549 ms
                    Atrás at 405 ms: nothing sent; Atrás at 591 ms sent, ack ok
refused at 52 ms    (text_target_unavailable) Inicio at 105 ms sent: no settle time
FINALIZAR 89 ms after an Acción answered ok
                    nothing sent afterwards, the request COMPLETED, the control channel
                    closed, no media projection left on the tablet and its capture
                    indicator gone
```

What Android 16 on this tablet showed:

```text
FOCUS_INPUT             as expected: the focused search field was found, and lost its
                        focus once its own search action ran
ACTION_IME_ENTER        exposed by the Settings search field; accepted
AccessibilityService    enabled by hand, bound with capabilities 33 (window content +
                        gestures) and no event types; no shortcut assigned
MediaProjection         the system dialog offers "Compartir pantalla completa" by default
log level               log.tag=E on this build drops every Log.i, so the tablet's own
                        RemoteControlInput lines never reach logcat. Its side was read from
                        the acks, dumpsys and the screen. Not a bug of either project
```

`ime_action_unavailable` was **not reproduced on the device**: no natural, safe field without
`ACTION_IME_ENTER` was at hand, and none was built for it. The automated tests cover it.

### What has been observed of text on the physical tablet

Chrome and a tablet running Android 14 (800x1280), with a debug `remote_control_device`
built from its `main` (2ee1646) and installed with `adb install -r`, and the accessibility
toggle and every consent done by hand. One `RemoteSession` throughout, with no F5. The
target was the search field of Settings. Frames were read by wrapping `RTCDataChannel` in
the page, Android's side from `adb logcat` (`RemoteControlInput`) and `dumpsys`, and the
field from the picture and from `adb exec-out screencap -p`. The real buttons were clicked
with the mouse.

```text
disclosure before PERMITIR                    text entry and "replacing its content" listed
regressions, same session: Home, tap on an
  app, swipe both ways on a list, Back        the real effect, ack ok
tap on the field, then 5 s of waiting         field focused and keyboard up, on the picture
                                              and on Android; no set_text sent
"Hola mundo"                                  in the field, set_text accepted, ack ok,
                                              Texto enviado
"Segundo texto" over it                       the field holds exactly that; the application
                                              reacted to it (Sin resultados)
"áéíóú ñ — Hola 👋"                           in the field as sent, 17 code units
Vaciar campo                                  "text":"", ack ok, the field back to its hint;
                                              with an empty editor Enviar texto sent nothing
launcher, nothing focused                     ack text_target_unavailable, set_text
                                              targetUnavailable, the message, launcher intact
service disabled by hand, field focused       ack accessibility_unavailable, set_text
                                              unavailable, the message, the field still empty;
                                              session and picture go on
service enabled again                         tap, a text and Back work, same session
frame held 4 s in the page: tap, Back, Home,
  Recents and Texto clicked within 391 ms     nothing sent, buttons disabled, Enviando texto...
  the ack                                     Texto enviado, buttons back, the next tap sent
text in the dialog, FINALIZAR                 dialog gone, no field in the DOM at 150 ms, no
                                              set_text; peer connection and channel closed
```

Over that session 21 commands were sent and 21 answered, 19 `ok: true` and 2 refusals, and
Android's log has the same count of each kind. A `set_text` was answered in 26 to 290 ms.

Unique strings sent through the dialog appeared in the field and nowhere else: not in the
50000 lines of logcat recorded during the session, the browser console, the output of
`flutter run`, the HTML or either storage. The frame itself carries the text: that is the
operation.

What the session also showed:

```text
a stale picture on a still screen  decoded frames stopped counting on the launcher, and the
                                   picture stayed on a frame from the middle of the Home
                                   transition until the screen next changed. This build
                                   predates the fix described below
the keyboard follows the field     its suggestions changed with the text: the application
                                   and its keyboard handle what was sent like anything typed
```

A still screen producing no frames does not make the picture wrong by itself: the last
frame sent would be the right one. The problem observed was that the final frame of a
transition could be lost before reaching the browser. With Android visually still
afterwards, no other frame came to correct the image, and the technician could keep seeing
an earlier state.

`remote_control_device` has since combined two changes, and the web client did not change:

```text
enableCpuOveruseDetection = false
one-shot settle frame               SurfaceTextureHelper.forceFrame(),
                                    700 ms after the last real frame
```

The settle gives the final state a second chance to be transmitted. It is sent once per
quiet period, so it is not a keepalive. CPU adaptation is disabled deliberately, to avoid
severe restrictions such as `max_fps=2` on this screen share. No single cause is claimed to
explain every freeze.

This was validated on the physical tablet, with Chrome and a visible tab: 460 actions with
no freeze and `max_fps=2` never applied. That is a bound and not a proof, and a settle that
is itself lost is not sent again, so a focus seen on the picture can still be older than it
looks. The measurements and limits are in "The final frame" of
`docs/webrtc/SCREEN_SHARING.md` in `remote_control_device`.

Two of the seven drags made in the session sent nothing and left no trace, with the
pointer on the picture. The next four, recorded at the level of pointer events, all went
out, so the cause was not found. A SWIPE was not attempted during the guard: it uses the
pointer layer a tap showed to be gone, and the automated tests cover it.

Alone in the browser, with a throwaway page and no backend: the textarea has
`autocomplete="off"` and `autocorrect="off"` and is in no form, and Esc cancels.

Covered by automated tests only, and never seen on the device: `text_rejected`,
`gesture_rejected` and `session_not_active` on a text, its timeout and a late ack, the
channel closing or the peer failing while it is pending or with the dialog open, a
rotation with the dialog open, the limit of 4096, and a line break reaching a multiline
field. A password field was deliberately not tried: do not use real passwords for this.

### What has been observed of Recents on the physical tablet

Chrome and a tablet running Android 14 (800x1280), with a debug `remote_control_device`
built for this test from the tree of `feature/device-remote-control-recents` (f72304c,
the same tree as its `main`) and installed with `adb install -r`, and the accessibility
toggle and every consent done by hand. The APK that was on the tablet predated Recents.
Frames were read by wrapping `RTCDataChannel` in the page, Android's side from `adb
logcat` (`RemoteControlInput`), `dumpsys activity` and `adb exec-out screencap -p`. The
real buttons were clicked with the mouse, and the attempts that needed an exact time
were `PointerEvent`s dispatched on the page.

```text
regressions, same session: tap on an app and
  on a Settings row, swipe on the Settings list,
  Back from a sub-screen, Home                the real effect on the tablet, ack ok
Recents from Settings                         the overview on the tablet, recents
                                              accepted, ack ok, Recientes enviado
ack of a Recents                              17 to 85 ms after it was sent
tap on a card of the overview                 that app in front
Home, Recents, tap, Back, Recents, Home,
  no F5                                       same session, channel and peer connection
in the guard of a Recents: tap at 90 ms,
  swipe 212, Back 243, Home 260, Recents 279  nothing sent
in the guard of a Recents answered at 17 ms:
  a tap at 301 ms, a tap at 450 ms            the first dropped, the second sent
service disabled by hand, Recents             ack accessibility_unavailable, no overview,
                                              message; session and picture go on
  a tap 141 ms after sending that Recents     sent: the refusal had ended the guard
service enabled again                         Recents works, same session
MediaProjection refused by hand: ACTIVE,
  control open, no picture                    buttons enabled, a click on the surface
                                              sends nothing, Recents opens the overview,
                                              Home and Back are acknowledged
FINALIZAR 86 ms after a Recents               not held back, buttons disabled, nothing
                                              more sent, peer connection and channel closed
```

Over those two sessions: 27 commands sent and 27 answered, 24 `ok: true` and 3
`accessibility_unavailable`. The window, with no scrolling of the page unless it says so:

```text
1920x855    the bar in one row, ending at 836 px; picture 580 px tall, portrait
1384x847    the same; picture 573 px tall, and the bar there with no picture too
744x715     the bar in one row
504x715     FINALIZAR on its own row, nothing overflowing, all of it on screen
1084x545    the bar in one row, on screen
1084x435    below the floor of the budget: the bar has to be scrolled to
```

Pressing Recents in the overview is Android's own toggle: it left the overview for the
previous app. The web only sends the action.

Covered by automated tests only, and never seen on the device: an ack of a Recents later
than 350 ms, `gesture_rejected` and `session_not_active` on it, its timeout, the channel
closing during its guard, and a replaced peer connection during it.

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
recents command sent <id>        recents confirmed <id>
recents timed out <id>           remote recents ignored <session>
set_text command sent <id>       set_text confirmed <id>
set_text timed out <id>          set_text rejected <id>: <code>
remote text ignored <session>
ime_enter command sent <id>      ime_enter confirmed <id>
ime_enter timed out <id>         ime_enter rejected <id>: <code>
remote ime_enter ignored <session>
long_press command sent <id>     long_press confirmed <id>
long_press timed out <id>        long_press rejected <id>: <code>
remote long_press ignored <session>
touch_hold sent hold-7 touch=t-6         touch_hold confirmed hold-7
touch_move sent mv-8 seq=1 [keepalive] +250ms
touch_release sent rel-15 seq=8 +1200ms  touch_release confirmed rel-15
touch_cancel sent cxl-9 seq=3 +600ms     touch_cancel sent cxl-9 seq=3 best effort
touch_hold rejected <id>: <code>         touch_move rejected <id>: <code>
touch_hold unsupported hold-7, long_press instead
touch cancelled touch=t-6                touch ended touch=t-6
touch lifetime reached touch=t-6         touch_release timed out <id>
remote hold ignored <session>
remote control command rejected: <code>
control message ignored <remoteSessionId>
control ack ignored <id>
```

Coordinates, frames and the text of a `set_text` are not logged, here or on the tablet.
A touch logs ids, `seq` and milliseconds since its hold, never a position.
