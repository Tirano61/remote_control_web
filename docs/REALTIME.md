# Realtime on the technician console — decisions

This document records how `remote_control_web` **uses** the `/technicians`
namespace. The contract itself — event names, payloads, rooms, audiences — is
[docs/backend/REALTIME.md](backend/REALTIME.md), copied from
`remote_control_backend`, and is not repeated here.

## Events are invalidations, REST is the state

Every domain notification of `/technicians` carries an id and nothing else. The
console never turns one into state: it asks REST and shows what REST answers.

```text
device:presence-updated        ->  GET /devices
                                   GET /support-requests
support-request:queue-updated  ->  GET /support-requests
support-request:updated        ->  GET /support-requests
remote-session:active          ->  GET /remote-sessions/current
remote-session:closed          ->  GET /remote-sessions/current
socket reconnected             ->  GET /devices
                                   GET /support-requests
```

The wiring lives in `TechnicianConsoleCoordinator`
(`lib/app/console/technician_console_coordinator.dart`). No BLoC imports
another, no widget listens to the socket, and nothing is polled.

## Device presence

`device:presence-updated` — payload `{ deviceId }` — says that the effective
presence of one device changed. It does **not** say which way: there is no
`isOnline` in it, and the client would ignore one if it ever appeared.

Presence is shown in two places, each with its own source of truth:

```text
Dispositivos             DevicesBloc          Device.isOnline
                                              (GET /devices)

Solicitudes de           SupportRequestsBloc  SupportRequest.device.isOnline
asistencia                                    (GET /support-requests)
```

Both are re-read on every event, whichever section the technician is looking
at. `isOnline` is never copied from one BLoC to the other and never toggled
locally: if it were, a quick `OFFLINE -> ONLINE -> OFFLINE` would leave the
console guessing which event was the last one, while REST already knows.

The `deviceId` is not used to pick rows. Both GETs return every device at once,
so a reload for device B is also a reload for device A — and A simply keeps
whatever presence the backend reports for it.

Online means "connected to the backend". It does not mean that the screen is
shared, that the accessibility service is enabled, that an assistance was
accepted, or that a WebRTC session or the `control` channel is up. A tablet can
be Online and not share anything.

## Refreshes in flight

Both `DevicesBloc` and `SupportRequestsBloc` apply the same policy:

```text
no GET in flight            ->  start one
GET in flight + new request ->  mark "refresh pending" (a flag, not a queue)
GET ends, pending set       ->  clear the flag, run one more GET
GET ends, pending clear     ->  done
```

Why it matters for presence:

```text
GET /devices starts           (reads the registry: OFFLINE)
the tablet connects
device:presence-updated       (arrives while the GET travels)
GET answers OFFLINE           (stale, and shown for what it is)
pending -> GET /devices       (reads ONLINE)
```

Without the pending flag the event would be dropped and the list would stay
`OFFLINE` until somebody pressed ACTUALIZAR. That was the behaviour of
`DevicesBloc` before this stage; `SupportRequestsBloc` already coalesced.

Properties of the policy:

* at most one GET per collection is in flight, so responses are applied in the
  order their requests were made and an older answer can never overwrite a
  newer one;
* a burst of events during one GET costs exactly one more GET, however long the
  burst is;
* a failure consumes the pending reload and never creates one, so an outage
  cannot become a request loop; a `401` stops everything, because the user
  session is ending;
* signing out discards a pending reload (`DevicesPendingRefreshDiscarded`,
  `SupportRequestsPendingRefreshDiscarded`); a GET already in flight cannot be
  recalled, but nothing follows it.

While a follow-up GET is pending the section keeps showing that it is
refreshing, so it does not flicker to idle between the two reads.

## Reconnection

Nothing is replayed. Every event emitted while the socket was down — presence
changes included — is lost for good, so a reconnection re-reads both
collections:

```text
socket drops
  events may be lost
socket reconnects (a new connection id)
  GET /devices
  GET /support-requests
  remote-session:join again, if an assistance is live
```

The first connection after opening the console re-reads nothing: the console
has just loaded both collections. A reconnection never creates or closes a
`SupportRequest` or a `RemoteSession`; it only reconciles what is shown.

There is no fallback polling. If the socket stays down, the lists are as fresh
as the last GET, and ACTUALIZAR still works.

## Listeners

`TechnicianRealtimeClientImpl` registers every server event handler once per
Socket.IO socket, at `connect()`. A Socket.IO reconnection reuses that socket
and its handlers; a `disconnect()` disposes it, and a handler of a replaced
socket ignores anything that still arrives. A payload without a usable id is
dropped without throwing.

## Logging

`device:presence-updated received <deviceId>` is logged in debug, like the
other notifications. The `deviceId` is an internal identifier, not a
credential; no token, SDP or ICE content is ever logged.
