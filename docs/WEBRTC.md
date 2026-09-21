# WebRTC on the technician console — decisions

Stage: Prompt 7 (the offer also asks to receive the tablet's screen).

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
  connection is still usable.

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

**No protocol exists yet.** Nothing is sent over the channel, incoming messages
are not parsed, and no command — tap, swipe, back, home, text — is defined.
This stage only proves that SCTP works.

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

**Screen capture is not implemented.** The tablet does not create a video track
yet: `MediaProjection`, the consent dialog it requires and the local
`VideoTrack` are the next stage on the device side. What exists today is the
*offer* that makes it possible — a session negotiated without a video section
could not receive a screen without renegotiating, and renegotiation is
deliberately not implemented either.

So this is a normal, healthy state and the console treats it as one:

```text
RTCPeerConnection  connected
control channel    open
remote video       none
```

Nothing is degraded by the absence of a screen. The assistance is established
when the peer connection is `connected` **and** `control` is `open`, exactly as
before; "control connected" and "screen available" become two different things
in a later stage, when there is something to display.

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

**Binding a renderer later.** `RTCVideoRenderer` needs the real
`MediaStream`. The seam is already chosen and does not change the domain: the
widget that builds the view will be injected into presentation as a builder,
and its only implementation will live next to the adapter, where the concrete
handle can be recognised and unwrapped. Presentation will hand it a
`RemoteVideoTrack` and still never learn what is inside.

Today nothing consumes the event beyond a debug line: there is no renderer, no
`RTCVideoView`, and no UI for a screen that is not being captured.

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

## Teardown

The peer connection, the data channel, the video transceiver, the remote track
reference, the event subscription and both candidate queues are released
together, from every ending:

```text
FINALIZAR ASISTENCIA        (RemoteSession -> Idle)
remote-session:closed       (-> REST reconciliation -> Idle)
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
ignored, plus the safe identifiers (`remoteSessionId`, `supportRequestId`,
`device.publicId`).

## Divergence with the copied contract

`docs/backend/REALTIME.md`, as copied into this repository, documents neither
the `peerJoined` field of the `remote-session:join` ACK nor the
`remote-session:peer-joined` event. The client implements both, because the
readiness contract was the explicit scope of this stage and the backend already
implements it.

The copied file is **not** edited to match this client: it is a copy of the
contract owned by `remote_control_backend`, and the source document has to be
updated there and copied again. Until it is, the readiness half of the contract
lives here and in the contract tests
(`test/features/technician_realtime/data/realtime_contract_test.dart`).

An accepted ACK without a boolean `peerJoined` is treated as **malformed**, so a
backend that does not send it yet reports the assistance channel as
unavailable instead of silently guessing readiness in either direction.
