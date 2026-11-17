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

## Physical validation (2026-11-17)

Run against real hardware and a real backend, with the console of this branch
served in debug mode (`flutter run -d web-server --web-port=5173`) and opened in
Chrome with a technician session. Nothing below was simulated; the automated
tests cover the same rules separately.

```text
tablet        T10A (LSTT10M2026081504), publicId 645-589-107,
              deviceId 1a04a6e4-cb88-4486-b5d0-7b95937347d6, Android 16,
              app com.example.remote_control_device
backend       remote_control_backend feature/backend-device-presence-realtime
              (3c97aa9), already running on :3000 (not restarted); its dist/
              contains device:presence-updated
transitions   force-stop of the app (Online -> Offline) and a normal launcher
              start (Offline -> Online), over plain ADB; no UiAutomation
```

How it was observed: page-level instrumentation in that one browser tab only —
incoming `/technicians` frames of the domain notifications (never anything sent,
so the handshake and its JWT were never recorded) and Resource Timing for the
REST calls. No product code was changed for it.

Observed, all times UTC:

```text
Online -> Offline   force-stop 12:54:01.259
                    device:presence-updated {deviceId}   12:54:01.408
                    GET /devices           12:54:01.409 -> 02.934
                    GET /support-requests  12:54:01.410 -> 03.102
                    list: T10A Offline; WAITING card: Offline, TOMAR disabled

Offline -> Online   launch 12:54:17.029
                    device:presence-updated {deviceId}   12:54:23.766
                    GET /devices           12:54:23.767 -> 24.150
                    GET /support-requests  12:54:23.768 -> 25.473
                    list: T10A Online; WAITING card: Online, TOMAR enabled
```

The same pattern was seen on every transition of the run (12:49:18, 12:53:01,
12:57:04, 12:57:38, 12:58:43): one event per effective transition, the two GETs
starting within 2 ms of it, both sections in agreement, no ACTUALIZAR, no F5.
The payload was always exactly
`["device:presence-updated",{"deviceId":"1a04a6e4-cb88-4486-b5d0-7b95937347d6"}]`.

A new request created from the tablet arrived as `support-request:queue-updated`
and caused `GET /support-requests` only, as before this stage; its card and the
device list both showed the T10A Online.

Technician reconnection: the `/technicians` WebSocket was closed from the page
and reconnection attempts were pointed at a closed port for a while. During that
window the T10A was force-stopped: no event arrived and the console kept showing
Online — the event was lost, and nothing polls. Once attempts were allowed again,
Socket.IO reconnected on its own (12:55:52), and the console issued
`GET /devices` and `GET /support-requests` (12:55:53.671 / .672) without any
event; both sections switched to Offline.

Concurrent refresh: the Online event of a launch was used to force-stop the
tablet at once, so two events arrived 133 ms apart:

```text
12:58:03.501  device:presence-updated (Online)
12:58:03.502  GET /devices #1          -> 03.883
12:58:03.503  GET /support-requests #1 -> 05.188
12:58:03.634  device:presence-updated (Offline)   both GETs still in flight
12:58:03.886  GET /devices #2          -> 04.263   (coalesced, after #1)
12:58:05.191  GET /support-requests #2 -> 05.570   (coalesced, after #1)
final         both sections Offline, matching the stopped app
```

One extra GET per collection, never two in parallel, and no stale answer left
on screen.

A force-stop issued before the tablet's socket had authenticated produced no
event at all, as the contract says: the device never became `ONLINE`, so there
was no transition to announce.

Limitations of this run:

* force-stopping the app also makes Android turn its accessibility service off
  (`enabled_accessibility_services` was `null` afterwards, while the service was
  bound before the first force-stop). Presence is unaffected — the tablet reads
  Online without it — but remote control needs it enabled again, by hand, in
  the tablet's settings;
* the first transition of the run was observed before the REST timing was
  instrumented, so its GETs are not on record (its UI change is);
* a single technician console was open; the MDT1065 was not touched;
* the duration of a GET depends on this backend and its database; the race was
  reproduced because `GET /support-requests` took about 1.7 s.
