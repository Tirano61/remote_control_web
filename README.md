# remote_control_web

Flutter Web technician console of the remote support system.

Current stage: **Prompt 5 — `RTCPeerConnection` and the `control` data
channel**.

Implemented so far:

```text
technician/admin authentication and session restore
devices and support requests, with assignment
remote sessions: create, recover, close
/technicians Socket.IO connection
remote-session:join, with its peerJoined readiness
remote-session:peer-joined
remote-session:closed
webrtc:offer / webrtc:answer / webrtc:ice-candidate relay
RTCPeerConnection (flutter_webrtc), technician side as the offerer
the control RTCDataChannel, opened but silent
```

Not implemented yet: video, `MediaProjection`, screen rendering and the remote
control commands (tap, swipe, back, home, text). The `control` channel carries
no protocol at all — this stage only establishes connectivity.

The WebRTC decisions that are not part of the backend contract — offerer role,
readiness, ICE/TURN, candidate ordering, teardown — are written down in
[docs/WEBRTC.md](docs/WEBRTC.md).

## Backend URL

The backend host lives in a single place, `lib/core/config/app_config.dart`,
and is provided at compile time:

```bash
# local development (default when the define is omitted)
flutter run -d chrome --web-port=5173 --dart-define=BACKEND_BASE_URL=http://localhost:3000

# Dev Tunnel, no code change needed
flutter run -d chrome --web-port=5173 --dart-define=BACKEND_BASE_URL=https://w4qb7jsw-3000.brs.devtunnels.ms
flutter build web --dart-define=BACKEND_BASE_URL=https://w4qb7jsw-3000.brs.devtunnels.ms
```

The Socket.IO URL is **derived from the same define**: the backend serves
`/technicians` on the same host and port as the HTTP API, so there is no second
URL to configure.

## ICE / STUN

The peer connection takes its ICE servers from a single optional define:

```bash
flutter run -d chrome --web-port=5173 --dart-define=WEBRTC_STUN_URL=stun:stun.l.google.com:19302
```

Without it the peer connection is created with `iceServers: []`, which is what
LAN testing needs and keeps the browser from contacting any third party host.

TURN is **not** implemented yet. Outside favourable networks — symmetric NAT,
mobile carriers, restrictive firewalls — a TURN/coturn relay will be required,
and its credentials will have to be issued by the backend.

`--web-port=5173` is not optional during development: CORS for both HTTP and
Socket.IO is configured on the backend, which allows `http://localhost:5173`.
A random port would be refused by the backend, not by this application, and
CORS is never changed from here.

## Verification

```bash
flutter analyze
flutter test
flutter build web
```

## Documentation

```text
docs/backend/ENDPOINTS.md          REST contract (source of truth)
docs/backend/REALTIME.md           Socket.IO contract (source of truth)
docs/SECURITY_TOKEN_STORAGE.md     Why the User JWT lives in browser storage
docs/WEBRTC.md                     WebRTC decisions of the technician side
```

The copy of `REALTIME.md` in this repository does not document `peerJoined`
nor `remote-session:peer-joined` yet, although the backend implements them and
this client consumes them. The copied contract is never edited to fit the
client: it has to be updated in `remote_control_backend` and copied again. See
the last section of [docs/WEBRTC.md](docs/WEBRTC.md).
