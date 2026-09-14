# remote_control_web

Flutter Web technician console of the remote support system.

Current stage: **Prompt 1 — technician/admin authentication and session
restore**. Devices, support requests, Socket.IO, remote sessions, signaling and
WebRTC are not implemented yet.

## Backend URL

The backend host lives in a single place, `lib/core/config/app_config.dart`,
and is provided at compile time:

```bash
# local development (default when the define is omitted)
flutter run -d chrome --dart-define=BACKEND_BASE_URL=http://localhost:3000

# Dev Tunnel, no code change needed
flutter run -d chrome --dart-define=BACKEND_BASE_URL=https://w4qb7jsw-3000.brs.devtunnels.ms
flutter build web --dart-define=BACKEND_BASE_URL=https://w4qb7jsw-3000.brs.devtunnels.ms
```

## Verification

```bash
flutter analyze
flutter test
flutter build web
```

## Documentation

```text
docs/backend/ENDPOINTS.md          REST contract (source of truth)
docs/backend/REALTIME.md           Socket.IO contract (later stages)
docs/SECURITY_TOKEN_STORAGE.md     Why the User JWT lives in browser storage
```
