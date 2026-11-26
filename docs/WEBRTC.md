# WebRTC on the technician console — decisions

Stage: Prompt 19 (the tablet's screen is displayed, a click sends a tap, a drag
sends a swipe, holding the pointer still puts a remote finger down that follows the
pointer until it goes up, a long press on an older tablet, three buttons send Back,
Home and Recents, a dialog sends a text to the focused field and Acción runs its IME
action; see [CONTROL_CHANNEL.md](CONTROL_CHANNEL.md)).

This document records the choices that are **not** part of the backend
contract. `docs/backend/REALTIME.md` only relays SDP and ICE and is
deliberately neutral about everything below; these are agreements between
`remote_control_web` and `remote_control_device`.

## Roles

```text
remote_control_web      initial offerer
remote_control_device   answerer
```

The backend does not decide who offers — *"it does not decide which side
creates the offer. Either end may send `webrtc:offer`"*. A fixed role is what
makes glare impossible without any rollback logic, and the technician is the
natural offerer: the assistance is started from the console, and the console is
the side that creates the `control` channel.

Consequences, both enforced in code:

* an incoming `webrtc:offer` is ignored (logged in debug, nothing else). The
  console never creates an answer;
* an incoming `webrtc:answer` is applied once per negotiation, and only while a
  negotiation is waiting for one. An answer never creates a peer connection.

## When a negotiation starts

Being joined is not enough. The backend hands a relayed message to the room of
the other namespace, and *"if the other end has not joined the session yet, the
room is empty and the message is silently dropped"* — an offer sent then is
lost, and nothing ever answers it.

All of this must hold:

```text
RemoteSession is live (CONNECTING or ACTIVE, from REST)
+ the /technicians socket is connected
+ this socket joined that session's signaling room
+ joined id == RemoteSession.id
+ peerJoined == true
+ no negotiation was already started on this connection
```

`peerJoined` comes from two places, both connection scoped and neither
persisted:

```text
remote-session:join ACK   { joined, remoteSessionId, peerJoined }
remote-session:peer-joined { remoteSessionId }
```

The event is readiness, never authorization: what the technician may do was
settled by the join the backend accepted. It is idempotent, and readiness for a
session the console does not hold is ignored.

Since Prompt 27 the event is also read for *when* it arrives. The backend emits
it only when a tablet socket enters a room none of the tablet's sockets is in,
so one received after this socket joined says the tablet has just come back —
typically after its own reconnection — and that an offer relayed before it,
still unanswered, reached nobody:

```text
peer-joined after the join      SignalingJoined.peerArrivals += 1
                                (peerJoined stays true: readiness unchanged)
offer relayed before it,
  no answer yet                 WebRtcSessionState.isOfferLost
                                -> the console replaces it at once, REST first
offer not relayed yet           nothing: it goes to the tablet now in the room
answered / connected /
  ICE disconnected              nothing
```

Offers made by the recovery wait 10 s for their answer instead of 30 s
(`WebRtcSessionBloc.defaultRecoveryAnswerDeadline`), the fallback when the
event does not come. Details, measurements and limits:
[SESSION_LIFECYCLE.md](SESSION_LIFECYCLE.md#fast-recovery-when-the-tablet-is-back-prompt-27).

## Four states, kept apart

```text
socket connected     the /technicians handshake succeeded
signaling joined     remote-session:join was accepted
peer ready           the tablet is in the same room
WebRTC connected     RTCPeerConnectionState.connected
```

They fail independently, so they are tracked independently. In particular:

* **`RemoteSession` does not change because WebRTC connected.** The backend has
  no `CONNECTING -> ACTIVE` transition today, so `RemoteSession = CONNECTING`
  together with `WebRTC = connected` is a normal combination. It is never
  faked locally;
* **losing the socket does not close a connected peer connection.** WebRTC is
  peer to peer and Socket.IO is not in the path once ICE succeeded. An
  *incomplete* negotiation is dropped instead, because the answer and the
  remaining candidates would never arrive;
* **after a reconnection no second offer is created** while the current peer
  connection is still usable;
* **a connected peer connection is not authority.** Remote control also needs
  the socket and a REST read made since it last came back; a peer connection
  that keeps working while the socket is down keeps its video, not its control;
* **a failed peer connection is renegotiated, within a budget,** only after
  `GET /remote-sessions/current` confirms the same session is still live. See
  [SESSION_LIFECYCLE.md](SESSION_LIFECYCLE.md#webrtc-failure);
* **a connected peer connection is not a live picture.** The tablet may hold
  its frames back while ICE stays connected (`remote_control_device`
  Prompt 40) and says nothing about it; what the console can tell the
  technician, and how it knows, is in
  [SESSION_LIFECYCLE.md](SESSION_LIFECYCLE.md#transmission-indicator-prompt-26).

## ICE configuration

One place, `AppConfig`, one define:

```bash
flutter run -d chrome --dart-define=WEBRTC_STUN_URL=stun:stun.l.google.com:19302
```

With no define the peer connection is created with `iceServers: []`. That is
the right default for this stage: on a LAN, host candidates alone connect the
tablet and the browser, and nothing contacts a third party host unless somebody
asked for it.

**TURN is not implemented, and this will not be enough outside favourable
networks.** Symmetric NAT, mobile carriers and restrictive corporate firewalls
all need a relay, so a real deployment will require TURN (coturn or equivalent).
TURN needs credentials; credentials are secrets and must be issued by
`remote_control_backend`, so none are hardcoded here and no TURN entry is
configurable through a `--dart-define` yet.

## The `control` data channel

```text
label     control
ordered   true
delivery  reliable (the SCTP default: no maxRetransmits, no maxPacketLifeTime)
```

Exactly one channel, created by the console before the offer — it is what puts
the SCTP m-section into the SDP. The tablet does not create it; it receives it
through `onDataChannel`.

Its state (`connecting`, `open`, `closing`, `closed`) is tracked apart from the
peer connection state: `connected` does not imply the channel is already open.

It carries eight commands, the tap, the swipe, the long press, Back, Home, Recents,
`set_text` and `ime_enter`, the four messages of a touch session, `touch_hold`,
`touch_move`, `touch_release` and `touch_cancel`, and their acknowledgements. The protocol and what each side does with it are
in [CONTROL_CHANNEL.md](CONTROL_CHANNEL.md). `set_text` is the only one whose content is
sensitive: it crosses this channel because that is the operation, and is not logged or
kept ([Remote text privacy](CONTROL_CHANNEL.md#remote-text-privacy)). Keys, a cursor,
selection and a remote clipboard are not defined.

`ime_enter` is presented as **Acción**: it runs `ACTION_IME_ENTER` on the field with
input focus, whatever action that field declares (Buscar, Ir, Siguiente, Enviar...). It
carries only its id, the web does not know which action it is, and its `ok: true` only
says Android accepted it. It requires the picture to be really displayed, so that the
technician can confirm on it which field has focus, nothing pending ahead of it, and a
deliberate press: it is never sent after a tap or a text. See
[CONTROL_CHANNEL.md](CONTROL_CHANNEL.md#ime-action-acción).

`long_press` has no button: holding the pointer still on the picture sends it, from the
same surface as a tap and a swipe.

```text
mouse/touch hold  -> long_press   {"v":1,"type":"long_press","id":"long-3","x":0.5,"y":0.25}

release before kLongPressTimeout, not moved   -> tap
moved >= 6 px before kLongPressTimeout        -> swipe
held still for kLongPressTimeout              -> long press, once, while still down
```

The web decides **when** the technician means a long press (Flutter's
`kLongPressTimeout`); the device decides **how long** Android holds it
(`getLongPressTimeout() + 100 ms`), and no duration crosses the channel. It asks for the
picture really displayed and nothing pending, like Acción, and settles like a global
action. See [CONTROL_CHANNEL.md](CONTROL_CHANNEL.md#long-press).

Since Prompt 19 that `long_press` is the fallback. A hold is first a **touch session**:

```text
web hold recognition   -> touch_hold     {"v":1,"type":"touch_hold","id":"hold-9","touch":"t-8","x":0.41,"y":0.52}
move after the hold    -> touch_move     a stream: <= ~30/s, latest point wins, keepalive every 250 ms
up                     -> touch_release  the finger is lifted there
cancel                 -> touch_cancel   the finger is taken away, never a release
```

The web decides when there is a hold or a drag; the device keeps one continuous Android
pointer across `dispatchGesture` calls (`willContinue` / `continueStroke`). Moves, the
release and the cancel never wait for the hold's acknowledgement, and keepalives start
when the hold is sent. Support is learned per negotiation from the first hold's answer:
`ok` means touch sessions, `unsupported_command` means `long_press` from then on. Nothing
else is negotiated, and no `capabilities` message exists. See
[CONTROL_CHANNEL.md](CONTROL_CHANNEL.md#hold-and-drag-touch-sessions).

## The screen: one `recvonly` video section

```text
kind        video
direction   recvonly
transceiver added before createOffer, exactly one per peer connection
```

What the two ends negotiate, and what each one does with it:

```text
remote_control_web      DataChannel creator      VIDEO recvonly
remote_control_device   DataChannel receiver     VIDEO sendonly (MediaProjection)
```

The tablet captures its screen with `MediaProjection` and attaches the
resulting `VideoTrack` to the transceiver this offer created, answering it as
`sendonly`. That path has been observed end to end with a physical tablet up to
the console receiving the track; no renegotiation is involved, and none is
implemented.

A session without a picture is still a normal, healthy state, and the console
treats it as one:

```text
RTCPeerConnection  connected
control channel    open
remote video       none      (consent pending on the tablet, or refused)
```

Nothing is degraded by the absence of a screen. The assistance is established
when the peer connection is `connected` **and** `control` is `open`, exactly as
before. "Control connected" and "screen available" are two different facts:
the second never gates the first, and never gates `POST /remote-sessions/:id/activate`.
It does not gate Back, Home and Recents either: they work without a picture, and only
a tap or a swipe needs one to aim at
([CONTROL_CHANNEL.md](CONTROL_CHANNEL.md#they-need-no-picture)). A text needs one as
well. The tablet would run it without a picture: requiring it is the web's own decision,
because the picture is how the technician checks where the text lands
([CONTROL_CHANNEL.md](CONTROL_CHANNEL.md#when-it-is-available)).

### Why a transceiver

`addTransceiver(kind: video, init: direction recvonly)`, never
`offerToReceiveVideo`. The latter is the Plan B constraint for the same intent,
and libwebrtc prints a deprecation warning for it under Unified Plan — which is
what every current browser implements. The transceiver is also the object a
later stage reads the negotiated direction back from.

**No SDP is written by hand.** The `m=video` line is produced by `createOffer`,
like everything else in the description; nothing in this application parses,
edits or inserts SDP.

### Exactly one, always

`prepareScreenVideoReceiver()` is idempotent, and idempotent even against
itself: the adapter memoises the *future* that adds the transceiver, so two
calls that overlap wait on the same creation instead of producing two `m=video`
sections. One peer connection carries one screen.

The order is part of the port's contract and is asserted on both sides of it:

```text
createPeerConnection
  -> openControlChannel          (SCTP m-section)
  -> prepareScreenVideoReceiver  (video m-section, recvonly)
  -> createLocalOffer            (createOffer + setLocalDescription)
  -> webrtc:offer
```

A peer connection created before this existed is never repaired in place — a
new assistance creates a new one, which is the only way a session gets a video
section.

### The track, seen from above

`onTrack` is accepted for `kind == 'video'` only; an audio track is dropped
with a debug line, because no audio is negotiated and nothing would consume it.
A video track becomes one typed event:

```text
RemoteVideoTrackAvailable(RemoteVideoTrack)
```

`RemoteVideoTrack` is an opaque handle in `domain`: an `id` and nothing else.
The real `MediaStreamTrack` and the `MediaStream` it was announced in stay
inside `FlutterWebRtcRemoteVideoTrack`, next to the adapter, so no BLoC and no
widget imports `package:flutter_webrtc` to know a screen is arriving.

The BLoC keeps the handle of the **current** negotiation in its state
(`WebRtcSessionState.remoteVideoTrack`, `hasRemoteVideo`) and carries it
through `connecting -> connected -> interrupted`. The generation guard drops
the track of a replaced or closed peer connection before it reaches the state,
and every ending of a negotiation forgets it.

## Rendering the screen

```text
remote track (onTrack, kind video)
  -> RemoteVideoTrack                    opaque handle, domain
  -> RemoteVideoRenderer                 presentation port
  -> FlutterWebRtcRemoteVideoRenderer    data, the only renderer adapter
  -> RTCVideoRenderer                    flutter_webrtc
  -> RTCVideoView                        the visible picture
```

### The seam

`RemoteVideoRenderer` is a port declared in presentation — it produces a
widget, so it cannot be a domain one — with a small lifecycle: `initialize`,
`attach(RemoteVideoTrack)`, `detach`, `dispose`, plus `buildView`, `track`,
`isDisplaying` and `aspectRatio`. None of `RTCVideoRenderer`, `MediaStream`,
`MediaStreamTrack` or `RTCVideoView` appears in it.

Its single implementation, `FlutterWebRtcRemoteVideoRenderer`, lives in
`data` next to the peer connection adapter. It recognises its own concrete
handle (`is FlutterWebRtcRemoteVideoTrack`) and unwraps it there. A handle it
does not know is refused with `RemoteVideoAttachResult.unsupportedTrack`: no
exception, and whatever was on screen is cleared rather than left behind.

The composition root hands the factory to the console
(`AppDependencies.remoteVideoRendererFactory`); tests hand a fake.

### Lifecycle

One adapter owns exactly one `RTCVideoRenderer`, created with it:

```text
constructor  RTCVideoRenderer()
initialize   renderer.initialize()          memoised: once, whoever asks
attach       renderer.srcObject = stream    replaces the previous track
detach       renderer.srcObject = null
dispose      renderer.dispose()             once; waits for a pending initialize
```

The adapter is owned by `RemoteScreenView`, a `StatefulWidget`: created in
`initState`, attached or detached in `didUpdateWidget` when the track changes,
disposed in `dispose`. Nothing is created in `build`.

Every attach, detach and dispose bumps a counter; an attach that finds another
number after one of its awaits was overtaken and does not touch the renderer.
The newest request always wins, so a quick `A -> B` never ends with A.

On the web, `RTCVideoView` looks its `<video>` element up once, when it is
mounted, and that element only exists after `initialize()`. The view is
therefore only built once the renderer is initialised and a track is bound.

### The stream handed to the renderer

`RTCVideoRenderer` renders streams, not tracks:

* the stream the track was announced in (`onTrack.streams`, from the `msid`)
  is used as it is when it carries exactly that video track and nothing else —
  the normal case;
* otherwise — no `msid`, or a stream that unexpectedly carries audio or a
  second video — a local stream (`createLocalMediaStream`) wrapping the screen
  track alone is built. Audio therefore never reaches the renderer, and the web
  renderer never creates an `<audio>` element.

Neither the track nor any stream is stopped or disposed by the console: they
belong to the peer connection. Releasing them means dropping the reference.
Nothing touches the peer connection, the transceiver or any SDP.

### The view

```text
RTCVideoView(renderer,
  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
  mirror:    false)
```

`contain`, never `cover`: the screen is letterboxed, never cropped or
stretched. Not mirrored: it is a screen, not a camera.

The surface is laid out with the aspect ratio the stream itself reports
(`RTCVideoValue`, updated on `canplay` and `resize`). Nothing is hardcoded —
the physical tablet happens to capture 1280x800, but a rotation or another
resolution simply reports another ratio and the surface reshapes. The surface
takes the full width of the assistance block and the height left in the window
once the buttons under it are on screen, and the largest box of the video's
ratio that fits both. See
[CONTROL_CHANNEL.md](CONTROL_CHANNEL.md#the-bar-stays-on-screen).

Until the first frames have told their size, and whenever no track is
attached, the surface shows **"Esperando pantalla del dispositivo..."**. That
is decided by the renderer reporting a size, never by a timer.

Over a real picture, and only while remote control can be used, a layer on top
of the view turns clicks into taps, drags into swipes and holds into a remote touch
that follows the pointer until it goes up (a long press on an older tablet). While that
touch lasts the layer stays, because it is what follows the pointer, and a pointer that
leaves the picture is clamped to the picture's edge instead of dropped.
The view itself is not touched, and the keyboard is not listened to. The wheel sends
nothing. See
[CONTROL_CHANNEL.md](CONTROL_CHANNEL.md#tap-swipe-or-long-press).

For the 350 ms after a global action, an IME action, a long press or the release of a
touch is sent, or until
it is answered if that takes longer, the layer is not there: the transition is still
running, so a click would land somewhere the technician did not aim at. The picture itself keeps arriving and
the renderer is left alone. See
[CONTROL_CHANNEL.md](CONTROL_CHANNEL.md#the-settle-guard).

### What the console does not know

Nothing in the protocol tells the web that the tablet refused
`MediaProjection` or that its capture failed. "Pantalla del dispositivo no
disponible" is therefore never shown: without a track the console keeps
waiting, and the assistance stays valid without a picture. If the tablet ever
signals it, it will have to be a contract between both apps first.

### When the picture goes away

```text
peer connection failed / closed   negotiation released  -> surface removed
                                  (a touch still down is forgotten at once; the
                                  tablet abandons it on its side)
WebRtcSessionTerminated           (FINALIZAR, closed, sign out) -> idem
RemoteSession CLOSED / gone       assistance block removed      -> idem
RemoteSession id changes          surface keyed by id           -> new renderer
new negotiation, same session     state without track -> detach, then attach
peer connection disconnected      kept, as the peer is (existing policy)
RemoteSession CONNECTING -> ACTIVE same widget, same renderer, same picture
```

The surface only exists while a negotiation of the session on screen is alive,
so a renderer is disposed whenever its surface leaves the tree, and a WebRTC
state about another session is never displayed under this one.

## Candidate ordering

Two ephemeral queues, both cleared with the negotiation and neither persisted:

```text
pendingLocalIceCandidates    setLocalDescription starts gathering, so
                             candidates exist before webrtc:offer has been
                             acknowledged. They wait for delivered=true and
                             are then relayed in order; later ones go out
                             directly.

pendingRemoteIceCandidates   a candidate may arrive before the answer was
                             applied. addCandidate would fail, so they wait
                             for setRemoteDescription and are then applied in
                             order; later ones are applied directly.
```

A relay the backend refused never closes anything: a connected session survives
on the pairs it already has, and an unfinished one is judged by ICE. Nothing is
resent, so a broken relay cannot become a flood.

## End-of-candidates

The contract accepts `candidate: ""`, *"since some implementations use it to
signal end-of-candidates"*. What that means on each side:

* **outgoing** — the browser reports the end of gathering with a `null`
  candidate, and `flutter_webrtc` drops that event before it reaches the
  application (`dart_webrtc` only forwards `iceEvent.candidate != null`). The
  console therefore never sends an empty candidate. The contract allows it, it
  does not require it;
* **incoming** — an empty `candidate` is *not* discarded as invalid. It is
  passed to `addCandidate` as it is, which is the standard end-of-candidates
  indication for the m-section named by its `sdpMid`.

A relayed candidate **without an `sdpMid`** is dropped with a debug line rather
than applied: the contract makes the field optional, but the web implementation
of `flutter_webrtc` dereferences it, and a browser cannot place a candidate
that names neither a mid nor an m-line index. ICE has the other candidates.

## Generations

Every negotiation carries a local number. A callback from a peer connection
that was replaced or closed — a late ICE candidate, a state change, a relay
acknowledgement that finally came back — is dropped instead of touching the
current state. The number is never persisted: an F5 destroys the peer
connection anyway.

A negotiation marked lost (Prompt 27) is replaced like an unanswered one: the
old peer connection is released first, so there are never two, and the new
generation drops everything the old one still reports. An answer received
before the replacement's offer is relayed is ignored; one that still arrives
for the offer taken for lost, before it is replaced, is applied and cancels the
replacement. The signaling contract has no negotiation id, so an answer already
on the wire when the replacement is relayed cannot be told apart.

## Teardown

The peer connection, the data channel, the video transceiver, the remote track
reference (in the adapter and in the BLoC state), the event subscription and
both candidate queues are released together, from every ending — and with
them the remote screen surface, whose `RTCVideoRenderer` is disposed:

```text
FINALIZAR ASISTENCIA        (RemoteSession -> Idle once POST close succeeds)
remote-session:closed       (the session on screen: at once, then REST)
a reconnection whose GET no longer returns the session
another session replacing the one held
sign out
a new negotiation
RTCPeerConnectionState.failed / closed
signaling lost before the peer connection was established
```

The remote track and the transceiver belong to the peer connection and die with
it, so closing means letting go of the references — nothing is stopped or
disposed twice, and a callback firing during the teardown reaches a detached
handler.

Nothing about WebRTC is persisted: no SDP, no candidate, no readiness, no
generation, no track. After an F5 the console re-reads `GET /remote-sessions/current`,
reconnects, joins again and starts a **new** negotiation if the ACK says the
tablet is still there.

## Logging

Never logged: SDP, ICE candidate contents, the User JWT, the `Authorization`
header, the handshake `auth` map.

Also never logged: media. No frame, no codec, no track content — a remote track
is reported by its opaque id and nothing else.

Logged in debug: peer connection created, offer created, offer relayed, answer
received, remote description applied, peer connection connected/failed/closed,
control channel created and its state, the video `recvonly` transceiver being
created, a remote video track being received and a non-video track being
ignored, the renderer attaching (by track id), detaching and being disposed,
plus the safe identifiers (`remoteSessionId`, `supportRequestId`,
`device.publicId`).

## Divergence with the copied contract

When this stage was written, `docs/backend/REALTIME.md` as copied into this
repository documented neither the `peerJoined` field of the
`remote-session:join` ACK nor the `remote-session:peer-joined` event. The copy
has since been refreshed from `remote_control_backend` and documents both
(*Participant readiness*, checked again in Prompt 27); the contract tests
(`test/features/technician_realtime/data/realtime_contract_test.dart`) still
pin the shape the client relies on. The copied file is never edited to match
this client.

An accepted ACK without a boolean `peerJoined` is treated as **malformed**, so a
backend that does not send it yet reports the assistance channel as
unavailable instead of silently guessing readiness in either direction.
