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
  recovery attempt planned (its place in the schedule)
attempt's time comes
  authority check -> GET /remote-sessions/current
GET answers the same session, live, read after the attempt started
  + still failed (nothing restarted it meanwhile)
  + socket connected, room joined, tablet in it
    -> one new negotiation: new peer connection, new data channel, new offer
GET fails
  -> the attempt is spent, the next one is planned and reads again
```

The schedule (`TechnicianConsoleCoordinator.defaultWebRtcRecoveryDelays`):

```text
attempt 1   at once
attempt 2   5 s after the failure that asks for it
attempt 3   15 s after
attempt 4   30 s after
then        nothing on its own: REINTENTAR CONEXIÓN, a socket reconnection,
            an F5 or a new assistance
```

Bounds:

* at most four automatic attempts in a run of failures; a connection that
  really works again (`connected` + `control` open), a socket reconnection, a
  new session and REINTENTAR give the schedule back;
* one attempt at a time: a failure reported while one is planned or reading
  REST is what that attempt is already about;
* the failed peer connection is released before the new one exists, so there
  are never two, and the new negotiation has its own generation: late callbacks,
  acknowledgements, tracks and data channel events of the old one are dropped;
* a close that arrives while an attempt waits or reads wins: no offer goes out;
* no new `RemoteSession` is created and no acceptance is asked for again.

While an attempt is planned the console says *Se perdió la conexión con el
dispositivo. Reintentando...*; once the schedule is spent, *No se pudo
establecer la conexión remota.* Both offer **REINTENTAR CONEXIÓN**, which goes
through REST like every automatic attempt.

What the tablet does with the new offer is the tablet's decision. It reuses its
running screen capture for a short window (20 s) after its peer connection went
away; past that, Android asks the user for MediaProjection consent again, and
the web never works around it. Since `remote_control_device` Prompt 31 the
tablet also replaces a peer connection it still reads as `connected` when the
offer comes from a web connection it never answered and its authority is
confirmed.

### Root cause of the UDP cut (Prompt 23 follow-up)

Reproduced on the T10A, browser UDP blocked for 90 s with a temporary Windows
Firewall rule (removed afterwards), on the code before this change:

```text
UTC          web (Chrome)                       tablet
15:30:51.3   UDP blocked
15:30:57.4                                      peer disconnected
15:30:58     peer disconnected
15:31:07.4                                      peer failed, capture orphaned
15:31:08     peer failed, GET current
15:31:11     GET ACTIVE -> offer 1 (recovery)   answered, capture reused
15:31:31     peer failed (ICE, UDP still cut)
             GET ACTIVE -> offer 2              answered (replacing gen 15)
15:31:49     peer failed -> "budget exhausted"
             "No se pudo establecer la conexión remota."
15:32:21.7   UDP back                           nothing more ever arrives
```

Each new peer connection failed 17–20 s after its offer while UDP was blocked.
The two attempts of the old budget ran back to back and were spent 31 s before
the network came back; nothing re-armed them afterwards — no timer by design,
and the socket, being TCP, never reconnected.

In the earlier run of `remote_control_device` Prompt 31 (11:33–11:35 local)
the tablet received no offer at all. The web logs of that run are gone; the
most likely path, consistent with the code, is that the recovery's single
`GET /remote-sessions/current` failed during the cut (`NetworkFailure`):
the recovery then waited for a read nobody would make, for good. That path
is covered by a test (`a REST read failing during the outage does not park
it`); it was not reproduced on the device.

A second defect was found while fixing it: a read that fails twice in a row
leaves the same `RemoteSessionState` twice, which a stream listener never sees.
`RemoteSessionState.failedAuthorityCheck` now makes every failed answer to a
check observable.

## Unanswered offer

The tablet answers an offer only after Android's MediaProjection consent
(`remote_control_device`, docs/webrtc/SCREEN_SHARING.md, *Answering an
offer*): a person deciding, which takes as long as it takes. Nothing in the
protocol tells the web the tablet is waiting for consent, and the same silence
is what an offer refused by the tablet (authority suspended, Android stopped
the capture in this session), an offer lost in signaling, or a tablet that
lost its own room look like. There is no `remote-session:peer-left` and no
negotiation id (docs/backend/REALTIME.md).

What the web knows, and uses:

| Fact | Source |
| --- | --- |
| the offer reached the tablet's namespace | relay ACK `delivered: true` |
| the session is still live and this technician's | `GET /remote-sessions/current` |
| the session ended | `remote-session:closed`, or that same GET |
| the tablet answered | `webrtc:answer`, or the peer connection reaching `connected` |

What it cannot know: *why* there is no answer.

So:

```text
offer relayed
  answer deadline armed (WebRtcSessionBloc.defaultAnswerDeadline, 30 s)
deadline passes without an answer
  the negotiation is reported unanswered — NOT failed, NOT torn down:
    "El dispositivo todavía no respondió. Si la tablet pide permiso
     para compartir la pantalla, debe aceptarse allí."
    REINTENTAR CONEXIÓN offered
  a recovery attempt is planned, on the same schedule as a failure
attempt's time comes
  GET /remote-sessions/current
    null / CLOSED        -> the assistance ends
    failure              -> the attempt is spent, the next one reads again
    live + still silent  -> that negotiation alone is replaced
                            (released first; never one that got its answer)
a late answer, while the negotiation is still there
  -> applied to it; nothing is replaced
```

Nothing here ends an assistance: only FINALIZAR, the tablet or the backend do.
The notice stays across the replacements until the tablet answers.

Why a replacement is safe while Android's dialog is open: the tablet
deduplicates capture requests per session (`MediaProjectionScreenCaptureClient`,
`_starting`), so a replacing offer joins the dialog already on screen, and the
grant goes to the newest negotiation. Seen on the T10A (below): one dialog.

Bounds: the schedule above — four automatic offers at most for a silent tablet,
then only REINTENTAR; the last negotiation is kept so that a consent given
later still connects.

## Seen on the T10A (2026-11-18)

T10A `LSTT10M2026081504`, Android 16, `remote_control_device` `main`
(`4a6b67e`, Prompt 31 merged; debug APK installed 11:19 local, code unchanged
since `7e2f6a6`), backend `main` `07b7c74` (`dist` built 08:38) through the VS
Code dev tunnel, this console served by `flutter run -d web-server` on
`localhost:5173`. Both clients on Google STUN, no TURN. Times UTC (local
−3 h). PERMITIR and every MediaProjection consent were given by hand on the
tablet; no mobile-mcp, no UiAutomation. Tablet Dart logs read from its debug VM
service, native ones from logcat.

**Real UDP cut, with this change** (session `eda944ec`, ACTIVE, 90 s):

```text
15:54:43.2   UDP blocked
15:55:00     web peer failed; attempt 1 at once -> offer, answered
15:55:21     failed again; attempt 2 planned in 5 s -> offer at 15:55:28
15:55:47     failed again; attempt 3 planned in 15 s -> offer at 15:56:05
15:56:13.6   UDP back
15:56:13.9   tablet: peer connected; web: connected, control open
15:57:28     Recientes, 15:57:33 Atrás: accepted by Android on the new channel
```

Four generations on the tablet, one at a time, each `capture reused`: one
MediaProjection (`TYPE_SCREEN_CAPTURE`) throughout, no dialog. The console said
*Reintentando...* with REINTENTAR CONEXIÓN while attempts waited.

**FINALIZAR during a recovery** (same session, second 60 s cut): pressed while
attempt 2 was connecting; peer closed at once, `endedBy TECHNICIAN`, tablet
withdrew control and stopped the capture (`Media Projection: null`), no offer
afterwards.

**F5 on the session left stuck by the old code**: recovered on its own
(`GET current` → offer → `recovery offer accepted: replacing generation 16`,
capture reused).

**Unanswered offer** (session `3058bafe`, CONNECTING): the user left Android's
dialog open for 98 s.

```text
16:04:24   offer; tablet: capture permission requested
16:04:54   web: answer overdue, notice shown; GET ACTIVE
16:04:56   offer replaced; tablet: recovery offer accepted (gen 31 -> 32)
16:05:34   replaced again (gen 32 -> 33), after its own deadline and wait
16:06:02   consent granted — the one dialog, no second request
16:06:04   answer of the newest generation; connected; control open
16:06:06   ACTIVE; Recientes and Atrás accepted by Android
```

Not shown on the device, covered by tests only: a `SYSTEM` close while an
attempt waits, a REST read failing during a real cut, a late answer arriving
while the attempt reads REST, a socket down when an attempt runs, ICE
`disconnected` recovering on its own.

## Residual risks

* **An answer already on the wire** when the web replaces a negotiation can be
  taken by the new peer connection: neither end can tell answers apart without
  a negotiation id in the signaling contract (`remote_control_backend`). ICE
  then fails and the schedule takes over; bounded, not prevented.
* **Silent replacements during a long consent.** A user who takes more than
  ~2 minutes on Android's dialog makes the console spend its schedule; the
  last negotiation is kept and still connects on consent, but if the backend's
  120 s `CONNECTING` TTL closes the session first, the assistance ends.
* **A tablet that lost its own room** while the web stays joined re-enters it
  and the web receives `remote-session:peer-joined` again. The console treats
  that event as idempotent, as the contract asks, so it waits for the answer
  deadline instead of offering at once.
* **Longer outages** than the schedule (~2 min, plus ~20 s per failing attempt)
  end on *No se pudo establecer la conexión remota.* with REINTENTAR CONEXIÓN.
* **No TURN.** Networks that never allow UDP between the two ends cannot be
  recovered by any number of offers.

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
* **REINTENTAR CONEXIÓN** after the WebRTC recovery schedule is spent, or to
  try at once while an offer is unanswered (an F5 does the same);
* **on the tablet**, MediaProjection consent, when Android asks for it again;
* **FINALIZAR** remains available throughout, and is the only way the console
  itself closes a session.

## Logging

Debug only, identifiers only: `remote session closed <id> endedBy=<value>`,
`remote session read superseded`, `closed remote session ignored in a read <id>`,
`remote session replaced <old> -> <new>`, `webrtc failed <id> (<reason>)`,
`webrtc recovery <n>/<max> planned in <ms> ms <id>`,
`webrtc recovery checking the session <id>`,
`webrtc recovery could not confirm the session <id>`, `webrtc recovery <id>`,
`webrtc recovery budget exhausted <id>`, `answer overdue <id>`,
`webrtc offer unanswered <id>`, `unanswered negotiation replaced <id>`,
`late answer accepted <id>`, `connection retry requested <id>`. No token, SDP,
ICE candidate, coordinate or text.
