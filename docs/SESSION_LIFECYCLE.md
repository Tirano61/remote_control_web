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
FINALIZAR -> Ending at once (not live) -> POST close ok -> Idle
          -> GET current fails            -> still Idle, no banner
          -> GET current 401              -> Idle, the user session ends

GET starts (backend: ACTIVE)
remote-session:closed                     -> Idle
GET answers ACTIVE                        -> dropped (stale), read again

close in flight, remote-session:closed    -> Idle
close then fails (network)                -> still Idle
```

A session FINALIZAR was pressed for is a stronger case: it is ended locally
before the backend says anything, and stays ended — see *FINALIZAR is final
locally* below. When both apply, *closed* wins: a read that still lists a session
already confirmed closed is an old read and resumes nothing.

Before this stage a `GET` failing right after a successful close re-emitted the
session it had "preserved", `ACTIVE` and no longer closing, and the console gave
remote control back.

## Presence in the header (B1)

**Defect.** During an assistance the header of *ASISTENCIA REMOTA* showed
`RemoteSession.device.isOnline`. That copy is only refreshed by
`GET /remote-sessions/current`, and `device:presence-updated` never reads it: the
event re-reads `GET /devices` and `GET /support-requests` (both carry presence),
not the session. A tablet that dropped and came back kept reading *Offline* in
the header while the device list next to it already said *Online*.

**Fix.** The header shows the presence of the session's device as the
`DevicesBloc` holds it (`isSessionDeviceOnline`, matched by `Device.id`, never by
`publicId`), and falls back to the session's own copy only while the list does
not contain the device (not loaded, failed, unknown device).

```text
device:presence-updated   -> GET /devices + GET /support-requests   (unchanged)
                             no extra request for the header
                             GET /remote-sessions/current NOT read
```

* **No redundant REST.** The header reuses the read the event already makes.
* **Old answers.** `DevicesBloc` serialises its reads: a `GET /devices` that left
  before a presence change is always followed by one that left after it, and
  answers are applied in the order they were asked. The last value shown is
  always the newest read.
* **Another device's event** re-reads the list (as before) and changes nothing in
  the header.
* **Presence is information only.** *Online* enables nothing: remote control is
  still decided by `ACTIVE` + a confirmed read + the socket
  (`_publishControlAuthority`). A tablet *Online* while control is paused stays
  paused.

## FINALIZAR is final locally (B2)

**Defect.** Pressing FINALIZAR kept the session live with `isClosing: true`
until `POST /remote-sessions/:id/close` answered. Remote control was suspended at
once, but the `RTCPeerConnection`, the `control` channel and the room were only
released by the answer — 1.9–2.7 s with Neon — and a network failure or a `5xx`
put the session back as `ACTIVE`, with remote control (`a close that failed
gives it back` was a test).

**Policy.** The technician decided. The decision is irreversible *for this
console* and never depends on REST:

```text
FINALIZAR
  1. the id is finalized (memory) and RemoteSessionEnding is emitted
     -> not live: the coordinator does what it does for any non-live session
        remote control withdrawn: a finger down gets touch_cancel (never a
          release), pending commands and the settle guard are dropped
        WebRTC generation bumped: late callbacks of the old negotiation die
        control channel and peer connection closed, candidate queues cleared
        signaling room forgotten, WebRTC recovery cancelled
  2. the id is written to PendingRemoteSessionCloseStore
  3. one turn of the event loop later: POST /remote-sessions/:id/close
```

The revocation is all local and runs before the request leaves (asserted by a
test that records the peer connection at the moment the close reaches the
repository). Nothing afterwards gives the session back: not a failed close, not
a `GET /remote-sessions/current` that still lists it (started before or after),
not an activation answered late, not an F5, not signing out and in again. The
FINALIZAR button disappears with the view, so there is no second press.

### What the backend said

`POST /remote-sessions/:id/close` is idempotent (`remote_control_backend`
Prompt 34, `f5b8a1c`): the first close **and** any repetition on a session of
this technician already `CLOSED` answer `200` with the session as it was
closed. The repetition writes nothing, emits nothing, and keeps the original
`endedBy` and `endedAt` — which may be `DEVICE` or `SYSTEM` when the tablet or
the backend closed it first. A late close never claims it. `404` is a session
that does not exist or is not this technician's (live or `CLOSED`, admin
included); `409` is now only a session still live whose support request cannot
be completed.

`CloseRemoteSession` returns a typed outcome:

| Answer | Outcome |
|---|---|
| `200`, same id, `CLOSED`, `endedAt` set — any `endedBy` | confirmed, no further read |
| `200` that does not describe that session as closed (another id, still live, no `endedAt`) | not trusted: `GET /remote-sessions/:id` decides (`CLOSED` → confirmed, live → unconfirmed and retried, another id → unconfirmed) |
| `404` (not found / not this technician's) | confirmed: nothing left to close |
| `409` → `GET /remote-sessions/:id` live | refused |
| `409` → `GET /remote-sessions/:id` `CLOSED` | confirmed (only a backend predating the idempotent close answers this way) |
| `409` → that read fails | unconfirmed |
| `403`, `400` | refused |
| no network, timeout, `5xx`, unreadable answer | unconfirmed |
| `401` | unconfirmed, reported: the user session ends |

`endedBy` is never required to be `TECHNICIAN`: the outcome carries the session
exactly as answered and the console logs its `endedBy`; *Asistencia
finalizada.* is shown whoever closed it.

The `409` path still reads by id rather than trusting the status alone. With
the current backend that costs one `GET` on a rare refusal; in exchange the
console stays correct against a backend that still answers `409` to a closed
session (compatibility). A valid `200` is not followed by any
`GET /remote-sessions/:id` — the contract says the response alone confirms
`CLOSED`. The `GET /remote-sessions/current` that follows any confirmation is
unchanged: it is about what comes next (a newer session, the queue), never
about bringing this one back.

`GET /remote-sessions/:id` is documented in `docs/backend/ENDPOINTS.md` and
returns closed sessions too. No contract was invented.

### Retries

Exactly the finalized id is ever sent, so a retry can never close a newer
assistance.

```text
unconfirmed      -> retry in 2 s, 5 s, 15 s, 30 s (five requests, ~1 min)
                    then "La asistencia se detuvo en esta consola, pero no se
                    pudo confirmar su cierre en el servidor." + REINTENTAR CIERRE
refused, 401     -> no automatic retry (same request, same answer)
socket reconnect -> one fresh schedule (the network came back)
REINTENTAR       -> one fresh schedule, one request per press
```

The close is confirmed — and the schedule stops, with no further request — by
any of: a confirmed outcome, `remote-session:closed` for that id (whoever won the
race), or a successful `GET /remote-sessions/current` that no longer lists it
(ownership scoped, one live session per technician). Then: *Asistencia
finalizada.*, the queue is re-read once, the store entry is removed.

While a close is pending no new assistance can be started (the backend may still
hold the old one). After confirmation everything is as usual.

### Persistence

Needed: without it an F5, a closed tab or a browser restart during an
unconfirmed close would read the session back from
`GET /remote-sessions/current` as `ACTIVE`, and — the tablet having received no
close — a new negotiation would hand remote control back.

`BrowserPendingRemoteSessionCloseStore` (behind the domain
`PendingRemoteSessionCloseStore`, so domain and presentation do not know it is
`localStorage`):

* stores `[{ "id": <remote session UUID>, "at": <ms> }]` and nothing else — no
  User JWT, user id, device id, SDP or ICE; a session id authorizes nothing;
* entries expire after 12 h, at most 8 are kept, corrupt or foreign values are
  ignored, storage errors never throw (the in-memory protection still holds);
* it is a deny list: an id in it is never shown as an assistance. It is read once
  per page before the first `GET /remote-sessions/current`. If that read lists
  the id as live, the close is resumed at once; if not, the entry is removed.
* signing out keeps both the in-memory set and the store, so signing in again
  never brings it back.

### Closed elsewhere

`DEVICE` and `SYSTEM` closes keep their path (`remote-session:closed` → the
session ends at once, REST afterwards). When the console's own close races
with them, or the event was missed, the close answers `200` with their
`endedBy`, and that is a confirmation like any other; whichever arrives first
— the event or the `200` — settles the pending close, and the other is
ignored. Seen on the T10A: a tablet that lost its
server stops the assistance on its own and closes it (`endedBy DEVICE`) when it
comes back; a tablet away longer than the 60 s grace gets `endedBy SYSTEM`. Both
end the console's view without a request of its own.

### Contract notes

* There is no event to leave the session room. After FINALIZAR the console no
  longer joins, but its socket — still connected — keeps counting as the
  technician's participation, so while the close is unconfirmed and the socket
  stays up, the backend's automatic close does not start. Only the console's own
  retries close it then. A disconnection (F5, closed tab, network) does start the
  60 s grace. The idempotent close (`200` on a session already `CLOSED`) now
  exists and is what the retries rely on; a `remote-session:leave` would still
  make this simpler and remains only proposed (`remote_control_backend`).
* The tablet receives `remote-session:closed` only when the close commits: until
  then it sees the peer connection and its channel go (at once), and decides on
  its own what to do with its capture.

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
A `401` is never dropped. Signing out discards whatever is in flight. The
pending close, activation and creation flags are fields of the BLoC, so a read
answered in the middle of FINALIZAR keeps the session ended.

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

## Seen on the T10A (2026-11-19) — presence and FINALIZAR

T10A `LSTT10M2026081504`, Android 16, `remote_control_device` `main` (`e40b39f`),
backend `main` (`f7eba5a`, `node dist/main` on `:3000`, Neon) shared and left
running; the tablet through the VS Code dev tunnel. This console in debug
(`flutter run -d web-server`, `localhost:5173`) pointed at an isolated relay on
`127.0.0.1:3101` that forwarded REST and the `/technicians` WebSocket to the
backend and could delay, drop or cut them (control port `3102`, logs without
headers or bodies). Only the console went through it. Times UTC; the tablet's
clock runs ~0.2 s behind. PERMITIR and every MediaProjection consent were given
by hand; ADB only for `input tap` on SOLICITAR ASISTENCIA, `cmd wifi`,
`screencap` and `logcat`. No mobile-mcp, no UiAutomation.

**A. Presence** (session `a58493da`, ACTIVE). Tablet Wi-Fi off at 17:21:42.8;
`device:presence-updated` → `GET /devices` at 17:22:29: header **Offline**,
session still *En curso*. Wi-Fi on at 17:22:38; event → `GET /devices` at
17:22:54: header **Online**. No `GET /remote-sessions/current` was caused by
either event. The tablet then closed the session itself (`endedBy DEVICE`, its
own policy after losing the server), which the console handled as a remote close.
A first attempt left the tablet away longer than the grace period: `endedBy
SYSTEM` at 17:18:30, peer released at once.

**B. Normal FINALIZAR** (session `0d67c7c3`):

```text
17:27:02.146  finalized locally
17:27:02.154  peer connection closed (+8 ms)       tablet: SCTP "User-Initiated Abort"
17:27:02.187  close attempt 1 (POST leaves)
17:27:04.635  POST 200 (2442 ms, Neon)            tablet: capture stopped
17:27:04.638  close confirmed -> "Asistencia finalizada."
```

**C. Slow POST** (session `c69965d8`, relay delaying the close 8 s): peer closed
at +3 ms, the tablet's channel aborted at once. The client gave the first POST up
after 10 s while the backend committed it at 10.5 s — a close that **arrived and
lost its answer**, for real: retry 2 s later → `409` → `GET /remote-sessions/:id`
`CLOSED` → confirmed. (Contract of that date. Since the idempotent close the
retry answers `200` with the original close — see the 2026-11-20 runs below.) **F**: this session itself was a new assistance started
normally right after B's confirmed close.

**D/E/F5. Failing POST, reconnection, reload** (session `7485747a`, relay
dropping every close before the backend):

```text
17:30:40.866  finalized locally; peer closed +3 ms; tablet channel aborted
17:30:40–47   attempts 1–3 dropped; retries 2 s, 5 s; localStorage holds only
              [{"id":"7485747a-…","at":…}]
17:31:04      F5: "finalized before this page: 1"; GET current -> still ACTIVE
              -> kept ended, no join, no offer; close resumed (dropped)
17:31:20.3    relay cut: socket and REST down 8 s
17:31:37.7    socket back -> fresh schedule, attempt at once (dropped);
              GET current ACTIVE -> still ended; no join, no offer
17:31:54.7    relay back to normal
17:32:02.2    attempt 8: POST 200 -> confirmed; store empty;
              tablet: "El técnico finalizó la asistencia."
```

The session never showed as live, the video never came back and nothing was
offered after FINALIZAR, in any run. Not reached on the device: the exhausted
schedule's *no se pudo confirmar* banner (the reconnection restarted it), a
`500` from the backend, a drag held while pressing FINALIZAR — covered by tests.
When the relay dropped a connection Chrome resent the same POST once by itself
(two log lines per attempt); harmless, the close names one exact session.

## Seen on the T10A (2026-11-20) — idempotent close

T10A `LSTT10M2026081504`, Android 16, `remote_control_device` as installed.
Backend `main` `f5b8a1c` (idempotent close), shared `nest start --watch` on
`:3000`, Neon; not edited, not restarted, its branch untouched. This console in
debug (`flutter run -d web-server`, `localhost:5173`) through an isolated relay
on `127.0.0.1:3101` (control `3102`, scratchpad only, logs without headers or
bodies) that could drop the answer of a close **after** the backend had
committed it, and replay an authorized close with the console's User JWT held
in memory only (never logged or shown). Only the console went through it.
PERMITIR and every MediaProjection consent were given by hand; ADB only for
`input tap` (SOLICITAR ASISTENCIA, the tablet's FINALIZAR ASISTENCIA) and
`screencap`. No mobile-mcp, no UiAutomation. Times UTC.

| Run | Session | What happened | Result |
|---|---|---|---|
| **E** SYSTEM | `085e2c82` | consent not given within the `CONNECTING` TTL: backend closed it 13:07:51.093 | console: `remote-session:closed endedBy=SYSTEM`, peer released; two authorized closes afterwards → `200`, `endedBy SYSTEM`, same `endedAt` |
| **A** normal | `2d2f934b` | FINALIZAR 13:23:22: finalized locally, peer closed, attempt 1 in the same instant | `POST` `200` in 2.6 s → `close confirmed endedBy=TECHNICIAN`, no `GET /remote-sessions/:id`; tablet: *El técnico finalizó la asistencia.* |
| **B** repeated | `2d2f934b` | two authorized closes on the `CLOSED` session | `200` both, `endedBy TECHNICIAN`, `endedAt` 13:23:24.553 unchanged; request `COMPLETED` |
| **F** new assistance | `496fa1fc` | started normally after A; while `ACTIVE`, the old close of `2d2f934b` replayed | `200` describing `2d2f934b` only; `496fa1fc` stayed `ACTIVE`, video and control on screen |
| **D** lost answer (browser resend) | `496fa1fc` | first answer dropped after commit (13:26:28.155); Chrome resent the same `POST` by itself | resend `200` with the original `endedAt` → confirmed at the first attempt, one transition |
| **D** lost answer (console retry) | `e27e6143` | first answer **and** Chrome's resend dropped after commit (13:30:51.516) | `retry 1/4 in 2000 ms` → attempt 2 → `200` → confirmed; *Confirmando el cierre…* meanwhile, INICIAR disabled, no peer, offer or join; pending-close entry removed; one transition |
| **C** DEVICE | `da749273` | tablet FINALIZAR 13:29:03.964 | console: `remote-session:closed endedBy=DEVICE`, peer closed; two authorized technician closes → `200`, `endedBy DEVICE`, same `endedAt` |

After the runs: no live session (`GET /remote-sessions/current` → `null`),
every request of the day `COMPLETED`, the tablet idle on SOLICITAR ASISTENCIA,
the relay and the debug server stopped.

Not reached on the device (covered by tests): a `409` on a live session, a
`200` describing another session, a `500`, an F5 with a close pending against
the new backend, a close racing with `remote-session:closed`.

## Transmission indicator (Prompt 26)

**Problem.** Since `remote_control_device` Prompt 40 the tablet drops its screen
frames before the encoder whenever it loses its authority (its socket, or a
check it could not confirm). MediaProjection, the peer connection and the
`control` channel all stay up, so the console kept showing the last frame as if
it were live — and tells the technician nothing.

**What the tablet tells the console about it: nothing.** No DataChannel message,
no Socket.IO event, no REST field says "paused" or "resumed"
(`remote_control_device` `ScreenCaptureTransmission.kt`, docs/remote_session/
LIFECYCLE.md, *Video during an authority loss*). The indicator is therefore built
only from signals the console already has, and says *puede* / *podría* whenever
it is inferring.

### Signals

| Signal | Source | What it proves |
|---|---|---|
| ICE `disconnected` / `failed` | this browser's peer connection | confirmed: nothing can arrive |
| `/technicians` socket down | this browser's socket | the console cannot hear presence or closes: unknown |
| tablet `OFFLINE` | `device:presence-updated` → `GET /devices` | confirmed by the backend; the tablet suspends the moment it loses its socket, so *inferred*: paused |
| command answered `session_not_active` | the tablet, over `control` | the tablet does not hold the session confirmed: *inferred*: paused |
| tablet in the room (`peer-joined`, join ACK `peerJoined: true`) | backend | the tablet rejoins **only with its authority confirmed** — the same moment it lets frames through again |
| a new offer answered (`connected` after a negotiation) | peer connection | same: it answers only with its authority confirmed |
| a command acknowledged `ok` | the tablet | same |
| picture on screen | the renderer (`isPictureDisplayed`) | a track of this negotiation is being drawn |

Never used: `framesReceived`, a timer, or "the picture has not changed". A still
screen is a legitimate screen, and a working ICE connection says nothing about
frames held back on the tablet.

### States

`RemoteTransmissionMonitor` (pure reducer) → `RemoteTransmissionCubit` (reads
`RemoteSessionBloc`, `WebRtcSessionBloc`, `TechnicianRealtimeBloc`,
`DevicesBloc`, `SignalingJoinBloc` and `remote-session:peer-joined`; writes to
none of them). First match wins:

```text
no live session (Idle, Ending = FINALIZAR, closed)   hidden
never connected in this page                          hidden (existing lines)
WebRtcFailed, attempt planned                         recovering     (placeholder)
WebRtcFailed, none left                               unavailable    (placeholder)
ICE disconnected                                      interrupted    "Conexión interrumpida"            confirmed
socket down                                           unconfirmed    "Sin conexión con el servidor"
socket back, GET /devices or join not done yet        recovering     "Recuperando transmisión"
socket back, GET /devices or join failed              unconfirmed    "Estado del dispositivo sin confirmar"
tablet OFFLINE                                        interrupted    "Conexión interrumpida" (+ en pausa)  confirmed offline, inferred pause
tablet back online / not in the room, no evidence     recovering
command refused session_not_active, no evidence       possiblyPaused "Transmisión posiblemente pausada"
after any of the above: not connected + channel + picture   recovering
otherwise                                             available      (no notice)
```

* **Interrupted / unconfirmed / possibly paused**: a card in the middle of the
  picture on a 35 % veil — the last frame stays visible. **Recovering**: a
  discreet strip at the top. **Available**: nothing; no permanent badge.
* With no peer connection (failed, being replaced) after a transmission was
  seen, a black panel takes the place of the picture with the same words. No
  renderer: no frame of the broken peer connection stays on screen.
* *Recovered* is never "the socket came back": it needs presence and the room
  read again on the new socket, the tablet back with evidence, and a connected
  negotiation with its `control` channel open and a picture on screen.

### Authority untouched

The notice is drawn under an `IgnorePointer` (a click on it still reaches the
tablet — tested by tapping the card), and the cubit adds no event to any BLoC.
Remote control is still decided by `_publishControlAuthority` alone: a tablet
reported offline does not pause it (the tablet refuses on its side), and a
notice going away does not resume it. Command validation, DRAG, C2 locks,
FINALIZAR, the idempotent close, the pending-close store and session recovery
are unchanged.

One behaviour changed next to it: **REINTENTAR** (the error banner's and the
pause notice's) now re-reads `GET /devices` together with
`GET /remote-sessions/current`, the two reads a reconnection makes. Found on the
T10A (run D below): the session was confirmed but the notice stayed
*sin confirmar* until the next presence read.

### Identity

Memory is per session id: another id — a new assistance, or REST answering
another session — starts from nothing. A WebRTC state about another session is
ignored, and callbacks of a replaced peer connection never get here (the WebRTC
BLoC drops them by generation). `RemoteSessionEnding` hides everything at once,
whatever arrives afterwards.

### Limits

* **A tablet suspended with its socket up** (a failed check after its own
  reconnection) is visible only through `session_not_active` on a command. The
  backend notices a half-open tablet socket late (seen: ~25 s); until then the
  console may show no notice over a frozen frame.
* **Presence lags.** `device:presence-updated` → `GET /devices` takes the
  backend's detection time plus a round trip.
* **A lost `peer-joined`** (best effort delivery) leaves *Recuperando
  transmisión* until another evidence: an answered offer, an `ok` command, or
  the next reconnection.
* For an instant the strip can read *unavailable* before *recovering* (the
  WebRTC BLoC reports `failed` before the coordinator plans its attempt, and
  the coordinator clears the plan before the new negotiation). Same frame; seen
  only in the log.

### Proposed for another prompt (not implemented)

A positive signal from the tablet would replace every inference above. The
smallest one, in the `control` channel the tablet already owns:

```json
{ "type": "screen_state", "state": "paused" | "live", "reason": "authority" | "projection" }
```

sent by `remote_control_device` when its gate closes or opens (and once after
the channel opens). It needs a `remote_control_device` change first, then
docs/CONTROL_CHANNEL.md; nothing in the backend. Until then the console keeps
saying *puede* / *podría*.

### Seen on the T10A (2026-11-20) — transmission indicator

T10A `LSTT10M2026081504`, Android 16, `remote_control_device` as installed.
Backend `main` `f5b8a1c`, shared on `:3000`, Neon; not edited, not restarted.
This console in debug (`flutter run -d web-server`, `localhost:5173`) through an
isolated relay on `127.0.0.1:3101` (control `3102`, scratchpad only, logs
without headers or bodies) that could cut the console's WebSocket and answer
REST `503`. Only the console went through it. PERMITIR and both MediaProjection
consents were given by hand; ADB only for `input tap` (SOLICITAR ASISTENCIA),
`input keyevent`, `cmd wifi` and `screencap`. No mobile-mcp, no UiAutomation.
The other device attached to ADB was not touched. Times local (UTC −3).

| Run | Session | What was done | Seen |
|---|---|---|---|
| **A** normal | `16addf9c` | assistance started, Recientes + Atrás | `available` throughout, no notice; *Atrás enviado* |
| **B** console socket cut (WebRTC up) | `16addf9c` | relay `socket=down` 14:45:55 | `unconfirmed/serverUnreachable` at once, *Sin conexión con el servidor*, control paused. The tablet's Recents (via ADB) **did** appear on the picture: the tablet kept transmitting, and the notice had only said *podría* |
| **C** recovery | `16addf9c` | relay back 14:46:18 | socket back 14:46:24 → `recovering/reconnecting` → `available` 14:46:25 (`GET /devices` + join ACK `peerJoined: true`); control *listo* after its own check |
| **D** REST 503 | `16addf9c` | `rest=503`, socket cut 6 s, socket back with REST still down | `unconfirmed/stateUnconfirmed` *Estado del dispositivo sin confirmar* + error banner, control paused; REST back + REINTENTAR → control back, notice stayed until ACTUALIZAR (→ the REINTENTAR fix above) |
| **E** ICE cut | `16addf9c` | tablet Wi-Fi off 14:47:36–14:48:02 | 14:47:43 `interrupted/peerDisconnected` over the last frame; 14:47:53 `failed` → attempt 1, placeholder *Recuperando transmisión*, offer to a tablet still away; 14:48:08 backend reports it offline → `interrupted/deviceOffline`; 14:48:26 online → `recovering/awaitingDevice`; 14:48:28 `peer-joined` → `recovering/renegotiating`; 14:48:30 unanswered offer replaced; 14:48:35 connected, picture → `available`; no new consent |
| **F** FINALIZAR during a cut | `16addf9c` | Wi-Fi off 14:49:01, FINALIZAR on *Conexión interrumpida* | *Finalizando* at once, no notice; close confirmed 14:49:17 `endedBy TECHNICIAN`; no transmission transition afterwards (Wi-Fi back 14:49:26) |
| **G** new assistance | `03e5fb98` | requested, taken, accepted again | only `available/none` for the new id; FINALIZAR 14:51:13, confirmed `TECHNICIAN` |

Not reached on the device (covered by tests): *Transmisión posiblemente
pausada* (needs the tablet suspended while ICE and the console's socket stay
up), a `SYSTEM` close during a recovery, a join refused after a reconnection,
a `GET /devices` in flight across a reconnection.

After the runs: no live session, the tablet idle on SOLICITAR ASISTENCIA with
Wi-Fi on, relay and debug server stopped.

### Tests (Prompt 26)

* `remote_transmission_monitor_test` (31): healthy video, tablet without a
  screen yet, still screen, never connected, offline, ICE `disconnected` /
  `failed` with and without a planned attempt, socket down (and presence not
  trusted meanwhile), `GET /devices` failing / in flight across a reconnection,
  join refused then accepted, `session_not_active` and its evidence, socket back
  with WebRTC pending, peer recovered, presence back waiting for the tablet, the
  rejoin overtaking the offline answer, another session's `peer-joined`, ICE
  back vs a new negotiation, several cuts, `CLOSED` / `SYSTEM`, FINALIZAR,
  pending close, another session's WebRTC state, a new assistance.
* `remote_transmission_widget_test` (11, the whole console wired as in
  production): no notice while healthy (also after two minutes), ICE cut over
  the picture, socket cut and recovery, REST failing, REINTENTAR re-reading
  presence, offline → online → `peer-joined` with remote control unchanged and
  a click on the card still sent, a paused control staying paused, ICE failed →
  placeholder → replacement → an old generation's callback ignored, FINALIZAR
  and a `SYSTEM` close during a cut.
* Mutations: without the evidence (`peer-joined` & co.) 7 tests fail; without
  the `IgnorePointer` the click test fails; without the `GET /devices` in
  REINTENTAR its test fails.

## Tests (Prompt 25)

* `close_remote_session_test`: first close and repetition `200` (one transition,
  no read by id), `endedBy DEVICE` / `SYSTEM` kept, retry after a lost answer,
  a `200` about another session / still live / without `endedAt` not trusted,
  a read by id answering another session, `404` missing / not this
  technician's, `409` live → refused, `409` + `CLOSED` by id (older backend),
  `409` + failed read, timeout / `5xx` / unreadable, `401`, `403` / `400`.
* `remote_session_bloc_test` › *FINALIZAR is final for this console*: lost
  answer confirmed by the retry `200` (no `GET` by id, store emptied), `409`
  live refused and not retried, closed first by `DEVICE` / `SYSTEM`, a `200`
  about another session never confirming (bounded retries, never live again),
  one close per session, F5 with the close pending and the tablet closing
  meanwhile; the Prompt 24 cases (old `GET` answering `ACTIVE`, new
  assistance, `remote-session:closed` during the close, F5, sign in again)
  unchanged.
* `technician_console_session_recovery_test`: lost answer confirmed by the
  `200` with control withdrawn throughout, no new peer connection, no rejoin;
  closed first by the tablet.
* `remote_session_contract_test`: an idempotent `200` with `endedBy DEVICE` /
  `SYSTEM` and the original `endedAt`, parsed as sent; through the real
  repository one `POST` and no `GET`; a `200` for another id followed by
  `GET /remote-sessions/<exact id>`.
* The fake repository models the idempotent close (an already `CLOSED` session
  answers `200` with its original `endedBy` / `endedAt`) instead of the old
  `409`; the tests asserting a `409` for a repeated close were replaced.

## Tests (Prompt 24)

* `session_device_presence_test`: the list answers by `Device.id`, the session's
  copy otherwise.
* `remote_session_widget_test` › *presence in the header*: Offline → Online,
  Online → Offline, another device's event, a `GET /devices` that left before
  the change, Online with remote control paused.
* `close_remote_session_test`: every row of the outcome table, and a retry after
  a lost answer.
* `remote_session_bloc_test` › *FINALIZAR is final for this console*: ended
  before the POST answers, written down before it leaves, one request per
  press, timeout, `500`, lost answer, `409` live / closed, `404`, `401`, an old
  `GET` answering `ACTIVE`, a later read without it, `remote-session:closed`
  during the close, F5, signing in again, a late activation, no new assistance
  while pending, a new one after confirmation.
* `technician_console_session_recovery_test` › *FINALIZAR is irreversible
  locally*: peer and channel closed before the POST, `touch_cancel` and never a
  release, pending commands dropped, timeout, `500`, lost answer, socket
  reconnection, socket down, `remote-session:closed`, an old WebRTC generation,
  a negotiation still being built, F5, a new assistance.
* `pending_remote_session_close_codec_test`, contract and repository tests for
  `GET /remote-sessions/:id`.
* The tests that described the old behaviour (`a close that failed gives it
  back`, `… gives the control back`, `… gives Back and Home back`, `is disabled
  while the close is in flight`) were inverted. With the old behaviour restored
  by mutation (a failed close giving the session back; the session live until
  the POST answers; the header reading the session's copy) the new tests fail.

## Residual risks

* **The idempotent `200` is trusted only when it names the exact session as
  `CLOSED` with `endedAt`.** Anything else goes to `GET /remote-sessions/:id`,
  so a malformed backend answer costs a read and, at worst, the bounded retry
  schedule — never a wrong confirmation.
* **The `409` read by id is kept for compatibility.** Against the current
  backend it only ever finds the session live (a refusal); it is one extra
  `GET` on a rare path.

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
* **An unconfirmed close with the socket up.** Without a way to leave the room,
  the backend's automatic close does not start while this console stays
  connected; the session is closed by the console's own retries, the next
  reconnection or REINTENTAR CIERRE. Locally it is over regardless.
* **The pending-close entry is per browser, not per user.** Another technician
  signing in on the same browser never sees it (ownership-scoped reads never list
  it) and its entry is dropped by their first read; the original technician's
  session, its socket gone, is closed by the backend's grace period.
* **The transmission indicator infers.** The tablet never says it withholds
  its screen; see *Transmission indicator* for what is confirmed, what is
  inferred and the `screen_state` message proposed to `remote_control_device`.
* **Header presence follows the device list.** If `GET /devices` keeps failing
  the header shows the last value that list applied, like the list itself.

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
  itself closes a session;
* **REINTENTAR CIERRE** once the automatic retries of an unconfirmed close are
  spent (or after a refusal). The assistance is already over in the console.

## Logging

Debug only, identifiers only: `remote session closed <id> endedBy=<value>`,
`remote session read superseded`, `closed remote session ignored in a read <id>`,
`remote session replaced <old> -> <new>`, `webrtc failed <id> (<reason>)`,
`webrtc recovery <n>/<max> planned in <ms> ms <id>`,
`webrtc recovery checking the session <id>`,
`webrtc recovery could not confirm the session <id>`, `webrtc recovery <id>`,
`webrtc recovery budget exhausted <id>`, `answer overdue <id>`,
`webrtc offer unanswered <id>`, `unanswered negotiation replaced <id>`,
`late answer accepted <id>`, `connection retry requested <id>`,
`remote session finalized locally <id>`, `remote session close attempt <n> <id>`,
`remote session close retry <n>/<max> in <ms> ms <id>`,
`remote session close confirmed <id> endedBy=<value>`,
`remote session close refused <id>`,
`remote session close unconfirmed, retries exhausted <id>`,
`remote session finalized here is still live <id>`,
`remote session close confirmed by a read <id>`,
`remote sessions finalized before this page: <count>`,
`transmission <phase>/<cause> <id>`. No token, SDP, ICE
candidate, coordinate or text.
