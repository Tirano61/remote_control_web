# WebRTC on the technician console — decisions

Stage: Prompt 5 (`RTCPeerConnection` and the `control` data channel).

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

The peer connection, the data channel, the event subscription and both
candidate queues are released together, from every ending:

```text
FINALIZAR ASISTENCIA        (RemoteSession -> Idle)
remote-session:closed       (-> REST reconciliation -> Idle)
sign out
a new negotiation
RTCPeerConnectionState.failed / closed
signaling lost before the peer connection was established
```

Nothing about WebRTC is persisted: no SDP, no candidate, no readiness, no
generation. After an F5 the console re-reads `GET /remote-sessions/current`,
reconnects, joins again and starts a **new** negotiation if the ACK says the
tablet is still there.

## Logging

Never logged: SDP, ICE candidate contents, the User JWT, the `Authorization`
header, the handshake `auth` map.

Logged in debug: peer connection created, offer created, offer relayed, answer
received, remote description applied, peer connection connected/failed/closed,
control channel created and its state, plus the safe identifiers
(`remoteSessionId`, `supportRequestId`, `device.publicId`).

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
