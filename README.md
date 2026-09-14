# remote_control_web

Flutter Web technician console of the remote support system.

Current stage: **Prompt 3 — remote sessions, recovery and Socket.IO
`/technicians`**.

Implemented so far:

```text
technician/admin authentication and session restore
devices and support requests, with assignment
remote sessions: create, recover, close
/technicians Socket.IO connection
remote-session:join
remote-session:closed
```

Not implemented yet: WebRTC signaling (`webrtc:offer`, `webrtc:answer`,
`webrtc:ice-candidate`), `flutter_webrtc`, remote video and remote control.

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
```
