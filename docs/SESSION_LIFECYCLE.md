# Remote session lifecycle on the technician console — decisions

How `remote_control_web` keeps a `RemoteSession` honest when the `/technicians`
socket, the backend or the peer connection let it down. The contract — the
automatic `SYSTEM` close, the 60 s grace period, the 120 s `CONNECTING` TTL —
is [docs/backend/REALTIME.md](backend/REALTIME.md#remote-session-lifecycle-automatic-close)
and [docs/backend/ENDPOINTS.md](backend/ENDPOINTS.md), copied from
`remote_control_backend`; it is not repeated here.

## PostgreSQL is the authority

The console never infers that it may control a tablet from what it still holds:

```text
RemoteSessionBloc still shows ACTIVE    -> not enough
RTCPeerConnection still connected       -> not enough
the control data channel is still open  -> not enough
```

Remote control is available only while **all** of this holds
(`TechnicianConsoleCoordinator._publishControlAuthority`):

```text
signed in
+ RemoteSession ACTIVE and no close in flight
+ its last GET /remote-sessions/current succeeded        (isVerified)
+ a read started after the socket last came back answered (authority check)
+ the /technicians socket is connected
```

The socket is part of it because it is how the console hears
`remote-session:closed`. Without it the backend may close the session — on its
own, after the grace period — and the console would not know. The peer
connection says the tablet can be *reached*; it never says the technician may
reach it.

The tablet applies the same rule on its side: it suspends commands as soon as it
loses its own socket, and stops everything after 45 s without authority.

## Suspension

The moment any condition above stops holding, the coordinator tells the WebRTC
BLoC that no session is authorised. That happens synchronously, in the listener
that noticed the change — before any REST call is even sent:

```text
a finger still down        -> lifted: one touch_cancel, best effort, if the
                              channel is still open (it ends a gesture, it
                              does not start one); the tablet's watchdog lifts
                              it anyway
pending commands           -> dropped, not answered, not resent
settle guard, last command -> forgotten
new commands               -> refused at the BLoC, not queued
```

Nothing is held for later: when the authority comes back, no command issued
during the suspension goes out. The peer connection and the data channel are
**kept** — a socket that blinked is not a reason to tear a working video down.

## Reconnection

```text
socket drops
  remote control suspended (above)
  signaling room forgotten
socket reconnects (a new connection id)
  authority check = n          required before the request leaves
  GET /remote-sessions/current
  GET /devices, GET /support-requests
  remote-session:join again    (keeps the session alive within the grace)
GET answers
  null / CLOSED           -> assistance ends: peer connection, data channel,
                             candidate queues, room; the queue is re-read
  same session, live      -> check n answered: remote control comes back; the
                             existing peer connection is kept, no new offer
  another live session    -> the old peer connection is released, nothing is
                             inherited; the new one is joined and negotiated
                             like any other
  failure                 -> session kept on screen, *unverified*: remote
                             control stays suspended, the peer connection is
                             kept, REINTENTAR is offered
```

A read that was already in flight when the socket came back **cannot** answer
the check: it is marked stale, its answer dropped, and the read made again.
There is no polling: if REST stays unreachable, the console waits for the user,
the next reconnection or the next trigger.

The join is repeated on every reconnection because the backend counts a side as
*taking part* only while one of its sockets is joined; reconnecting alone does
not stop the grace period. A join refused `UNAUTHORIZED` — what a session closed
meanwhile looks like — triggers one more `GET /remote-sessions/current`.

## `remote-session:closed`

On `/technicians` it arrives when the tablet closed the session (`DEVICE`) or
the backend did (`SYSTEM`). Every value, known or not, means the same thing.

The backend emits it only after the close committed, and a closed session never
reopens. So for the session on screen it is acted upon at once, without waiting
for REST:

```text
remote control withdrawn (suspension, above)
peer connection, data channel, candidate queues released
signaling room forgotten
RemoteSession -> Idle
its id remembered as closed
then GET /remote-sessions/current
```

For any other id, nothing on screen changes: the id is remembered as closed (it
is) and REST is read. The id is never adopted as the current session.

## A closed session stays closed

`RemoteSessionBloc` remembers every id the backend confirmed is over — a
successful `POST /remote-sessions/:id/close`, a `remote-session:closed`, or a
read that no longer returns it. Nothing brings one back:

```text
FINALIZAR -> POST close ok -> Idle at once
          -> GET current fails            -> still Idle, no banner
          -> GET current 401              -> Idle, the user session ends

GET starts (backend: ACTIVE)
remote-session:closed                     -> Idle
GET answers ACTIVE                        -> dropped (stale), read again

close in flight, remote-session:closed    -> Idle
close then fails (network)                -> still Idle
```

Before this stage a `GET` failing right after a successful close re-emitted the
session it had "preserved", `ACTIVE` and no longer closing, and the console gave
remote control back.

## Reads in flight

`GET /remote-sessions/current` follows the policy of the other collections, with
one difference that matters for security:

```text
no read in flight            -> start one
read in flight + request     -> mark it stale (a flag, not a queue)
stale read answers           -> answer DROPPED, read again
fresh read answers           -> applied
```

The device list may show an old answer for an instant; a remote session may
not, because an old `ACTIVE` would hand remote control back for that instant.
A `401` is never dropped. Signing out discards whatever is in flight. Close,
activation and creation flags are fields of the BLoC, so a read answered in the
middle of FINALIZAR keeps saying the session is closing.

## WebRTC failure

```text
RTCPeerConnectionState.failed (or the offer not relayed)
  peer connection, channel and track released at once
  authority check -> GET /remote-sessions/current
GET answers the same session, live, read after the failure
  + still failed (nothing restarted it meanwhile)
  + socket connected, room joined, tablet in it
    -> one new negotiation: new peer connection, new data channel, new offer
```

Before this stage the coordinator's `(connection, session)` guard stayed set
after a failure, so no new offer could ever leave on the same socket.

Bounds:

* at most `maxAutomaticWebRtcRecoveriesPerSession` (2) automatic attempts in a
  row; a connection that really works again gives the budget back. Once
  exhausted, the failure stays on screen until a genuinely new situation: a
  socket reconnection, an F5 or a new assistance. No timer retries anything;
* the failed peer connection is released before the new one exists, so there
  are never two, and the new negotiation has its own generation: late callbacks,
  acknowledgements, tracks and data channel events of the old one are dropped;
* a close that arrives while the check is in flight wins: no offer goes out;
* no new `RemoteSession` is created and no acceptance is asked for again.

What the tablet does with the new offer is the tablet's decision. It reuses its
running screen capture for a short window (20 s) after its peer connection went
away; past that, Android asks the user for MediaProjection consent again, and
the web never works around it. The tablet ignores an offer while its own peer
connection still reports `connected`; such an attempt stays "connecting" and
spends one unit of the budget.

## Closing the tab

Not implemented, on purpose:

* `beforeunload` / `pagehide` fire for an F5 too, and an F5 in the middle of an
  assistance is recovered on its own (`GET /remote-sessions/current` on start).
  A close sent there would end every assistance the technician reloads;
* neither event is a guarantee, and `navigator.sendBeacon` cannot carry the
  `Authorization` header `POST /remote-sessions/:id/close` requires;
* the backend already covers it: closing the tab closes the socket, the
  technician stops taking part in the session, and the backend closes it with
  `endedBy: SYSTEM` one grace period (60 s) later, emitting
  `remote-session:closed` to the tablet.

Nothing in the console sends a close on navigation or unload: FINALIZAR is the
only way it closes a session.

## Delivery limits

Socket.IO delivery is best effort and nothing is replayed. What protects the
console from what it missed:

| Missed while | Recovered by |
|---|---|
| the socket was down | the check `GET` on reconnection |
| a `GET` was in flight | the stale flag: the read is made again |
| the event never arrived although connected | the tablet refusing commands `session_not_active` (one `GET` per refused command), a relay or join refused `UNAUTHORIZED`, or the next reconnection |

## When the user has to act

* **REINTENTAR** after the session could not be confirmed — the banner's, or the
  pause notice's once the banner is closed;
* **F5** after the WebRTC recovery budget is exhausted, if FINALIZAR is not
  what they want;
* **on the tablet**, MediaProjection consent, when Android asks for it again;
* **FINALIZAR** remains available throughout, and is the only way the console
  itself closes a session.

## Logging

Debug only, identifiers only: `remote session closed <id> endedBy=<value>`,
`remote session read superseded`, `closed remote session ignored in a read <id>`,
`remote session replaced <old> -> <new>`, `webrtc failed <id> (<reason>)`,
`webrtc recovery <id>`, `webrtc recovery budget exhausted <id>`. No token, SDP,
ICE candidate, coordinate or text.
