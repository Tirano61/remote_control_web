# remote_control_web

## Project overview

`remote_control_web` is the Flutter Web technician client of the remote support system.

The complete system consists of:

```text
remote_control_backend
    NestJS + PostgreSQL / Neon

remote_control_device
    Flutter Android
    installed on supported devices

remote_control_web
    Flutter Web
    ← this repository
```

The web application is used by authorized technicians and administrators to:

```text
authenticate
view devices
view support requests
take support requests
create RemoteSessions
join realtime signaling
establish WebRTC
view the Android screen
send remote-control commands
```

Development is incremental.

Do not implement future stages unless explicitly requested by the current prompt.

---

# Technology

Main technology:

```text
Flutter Web
Dart
```

Architecture:

```text
DDD
BLoC
```

Maintain clear separation between:

```text
data
domain
presentation
```

Do not place HTTP, persistence, Socket.IO or WebRTC logic directly inside widgets.

---

# Backend

The backend project is:

```text
remote_control_backend
```

Technology:

```text
NestJS
PostgreSQL / Neon
JWT
Socket.IO
WebRTC signaling
```

The backend is already operational and tested against real Neon PostgreSQL.

---

# Backend contract

The official backend contracts are copied locally into:

```text
docs/backend/ENDPOINTS.md
docs/backend/REALTIME.md
```

These files originate from:

```text
remote_control_backend
```

and are the source of truth for integration.

Before implementing any REST integration, read:

```text
docs/backend/ENDPOINTS.md
```

Before implementing Socket.IO or signaling, read:

```text
docs/backend/REALTIME.md
```

Do NOT guess:

```text
routes
HTTP methods
request fields
response fields
roles
status codes
namespace names
Socket.IO event names
ACK structures
signaling payloads
error codes
```

If the frontend requires a contract that does not currently exist, report it.

Do not silently invent a frontend-only backend contract.

Do not modify the copied contract files merely to fit the Flutter implementation.

The source contract must first be changed in `remote_control_backend`.

---

# Authentication

This application authenticates human users.

Current authorized roles relevant to this application are:

```text
admin
tecnico
```

Use the current backend contract to determine authorization.

Authentication uses:

```text
POST /auth/login
GET /auth/check-status
```

according to `ENDPOINTS.md`.

The web application uses a User JWT.

It must NEVER use Device JWTs.

---

# Roles

Authorization remains a backend responsibility.

Flutter may use roles to:

```text
show/hide UI
disable unavailable actions
improve navigation
```

but client-side role checks are NOT security.

The backend must remain authoritative.

Do not invent additional roles.

---

# User session

The authenticated user session conceptually contains:

```text
id
email
fullName
roles
isActive
User JWT
```

Use actual fields from the backend contract.

Do not expose the JWT in UI or logs.

---

# Token persistence

Unlike `remote_control_device`, this is a human web application.

The exact persistence strategy for the User JWT must be chosen carefully for Flutter Web.

Avoid storing secrets in arbitrary plaintext application structures.

Keep token persistence behind an abstraction.

Presentation and domain code must not know whether the implementation uses browser storage or another mechanism.

Security tradeoffs must be documented when persistence is introduced.

---

# HTTP architecture

Use a centralized HTTP client.

Conceptually:

```text
RemoteDataSource
      ↓
RepositoryImpl
      ↓
Repository
      ↓
UseCase
      ↓
BLoC
      ↓
UI
```

Do not scatter HTTP calls across widgets or blocs.

Keep:

```text
BACKEND_BASE_URL
```

centralized and configurable.

Do not hardcode backend URLs throughout the application.

---

# Errors

Represent meaningful categories such as:

```text
network
authentication
authorization
validation
not found
conflict
server
```

Do not show raw backend exceptions, SQL messages, stack traces or internal implementation details to users.

Do not make business logic depend on human-readable backend error strings when status codes or stable error codes exist.

---

# Devices

A future stage will use the administrative device endpoints documented in `ENDPOINTS.md`.

Important distinction:

```text
Device.id
    internal UUID

Device.publicId
    human-friendly ID, e.g. 132-491-092
```

`publicId` is not authentication.

Device ONLINE/OFFLINE is calculated by backend presence.

The web application does not set `isOnline`.

---

# Enrollment administration

The web application will later allow an authorized technician/admin to:

```text
create Device
generate enrollment code
```

The generated values:

```text
publicId
enrollmentCode
```

are supplied to `remote_control_device`.

Do not generate activation codes locally.

The backend is authoritative.

---

# SupportRequests

The future technician flow is:

```text
Device creates WAITING request
        ↓
remote_control_web lists request
        ↓
technician assigns/takes it
        ↓
ASSIGNED
        ↓
device user accepts or rejects
        ↓
ACCEPTED / REJECTED
```

The technician identity used for assignment comes from authenticated backend identity.

Do not allow Flutter to submit an arbitrary `technicianId` if the backend contract does not require it.

---

# RemoteSession

After a SupportRequest becomes:

```text
ACCEPTED
```

the technician can create a:

```text
RemoteSession
```

Current session states:

```text
CONNECTING
ACTIVE
CLOSED
```

Use the actual backend contract.

The web application must not invent transitions that do not exist server-side.

---

# Technician Socket.IO

The technician realtime namespace is:

```text
/technicians
```

Authentication uses the current User JWT according to `REALTIME.md`.

Do not use:

```text
device JWT
email
userId
technicianId
```

as client-supplied socket identity unless explicitly required by the contract.

Backend authentication determines technician identity.

---

# Signaling

The backend already supports signaling events for RemoteSessions.

The current contract includes concepts such as:

```text
remote-session:join
webrtc:offer
webrtc:answer
webrtc:ice-candidate
```

Read exact payloads and ACKs from:

```text
docs/backend/REALTIME.md
```

The backend only relays signaling.

It does not normally transport video or remote-control traffic.

---

# WebRTC

Future architecture:

```text
remote_control_device
        ↕
      WebRTC
        ↕
remote_control_web
```

Expected transport later:

```text
VideoTrack
    Android device → technician web

RTCDataChannel
    technician ↔ Android device
```

Do not introduce WebRTC until explicitly requested.

---

# Remote video

The technician web application will eventually render the Android device screen received through WebRTC.

Do not implement fake screenshots, polling or backend video transport as substitutes.

---

# Remote control

Control commands will eventually travel through:

```text
RTCDataChannel
```

toward `remote_control_device`.

Expected future commands include:

```text
tap
long press
swipe
drag
scroll
Back
Home
Recent apps
text input
```

Do not implement these before the dedicated prompt.

---

# Security

This application will eventually allow control of remote Android devices.

Treat these as security boundaries:

```text
technician authentication
roles
SupportRequest ownership
RemoteSession ownership
Socket.IO authentication
signaling authorization
WebRTC session identity
remote control
```

Never:

```text
trust a userId supplied by the UI as authorization
trust a RemoteSession id without backend validation
expose JWTs
log SDP/ICE contents
bypass the explicit user consent flow on the Android device
```

---

# Logging

Never log:

```text
User JWT
password
Authorization header
SDP
ICE candidate contents
```

Safe operational identifiers such as:

```text
device publicId
supportRequestId
remoteSessionId
```

may be logged in debug when useful.

---

# Socket.IO reconnection

Realtime state and backend domain state are different.

A socket reconnect does NOT recreate or close:

```text
SupportRequest
RemoteSession
```

After reconnecting, the application should recover backend state through REST when necessary.

Joining a signaling room must be repeated after Socket.IO reconnect because room membership is connection-scoped.

---

# Source of truth

Use:

```text
REST
```

for persistent domain state.

Use:

```text
Socket.IO
```

for notifications and ephemeral signaling.

Do not make a realtime event the sole source of persistent state when a REST endpoint exists to recover it.

---

# UI direction

The application should become a practical technician console.

Expected future areas:

```text
Login
Dashboard
Devices
Support requests
Active assistance
Remote session
Remote screen
```

Do not build all sections before their functionality exists.

Prefer functional, clear UI over premature design complexity.

---

# DDD structure

A reasonable structure is:

```text
lib/
  core/

  app/

  features/
    auth/
      data/
      domain/
      presentation/

    devices/
      data/
      domain/
      presentation/

    support/
      data/
      domain/
      presentation/

    remote_session/
      data/
      domain/
      presentation/

    signaling/
      data/
      domain/
      presentation/
```

This is guidance.

Create only what the current prompt requires.

---

# BLoC

Use BLoC for asynchronous application workflows and meaningful UI state.

Do not use blocs as:

```text
HTTP clients
database/storage adapters
service locators
```

Keep dependencies explicit.

---

# Dependency composition

Prefer a clear application composition root.

Do not introduce a global service locator unless there is a strong reason.

Dependencies should remain testable and replaceable with fakes.

---

# Tests

Add unit/widget tests for meaningful behavior.

Contract-sensitive code should have tests verifying the backend request/response shape where practical.

Do not claim backend/hardware integration was tested unless it actually was.

---

# Current backend status

The backend already implements and has real integration coverage for:

```text
user authentication
admin/technician roles

devices
device enrollment
device authentication

device Socket.IO presence

SupportRequests

RemoteSessions

/devices Socket.IO
/technicians Socket.IO

remote-session:join

WebRTC signaling:
webrtc:offer
webrtc:answer
webrtc:ice-candidate
```

`remote_control_device` already implements through signaling readiness.

The web client must consume the existing contracts rather than recreate them.

---

# Current real device status

A physical Android tablet has already been successfully validated with:

```text
enrollment
Device JWT
Socket.IO presence
SupportRequest WAITING
ASSIGNED
REJECTED
ACCEPTED
RemoteSession CONNECTING
RemoteSession recovery after restart
remote-session:created realtime flow
```

Do not assume WebRTC itself has already been validated.

---

# Development scope discipline

Prompts are intentionally incremental.

Implement only the requested stage.

Do not proactively add:

```text
devices
support
Socket.IO
RemoteSession
signaling
WebRTC
remote control
```

before their corresponding prompts.

---

# Planned development order

Approximate roadmap:

```text
1. Technician/admin authentication
2. Devices + SupportRequests
3. RemoteSession + /technicians Socket.IO
4. Signaling
5. WebRTC peer connection
6. Remote video
7. RTCDataChannel
8. Remote control UI
9. Lifecycle/security hardening
```

This roadmap does not authorize implementing later stages early.

---

# Verification

Normally run:

```text
flutter analyze
flutter test
```

For Flutter Web changes, build when appropriate:

```text
flutter build web
```

Do not claim browser integration was tested unless it actually was.

---

# Project prompt convention

This project is:

```text
remote_control_web
```

Every development prompt must contain:

```text
Proyecto: remote_control_web
Prompt: <incremental number>
```

The title goes on the following line.

Example:

```text
Proyecto: remote_control_web
Prompt: 1

# remote_control_web — Prompt 1 — FLUTTER WEB — Autenticación de técnico/admin
```

Prompt numbering is independent from:

```text
remote_control_backend
remote_control_device
```

---

# Priority

If instructions conflict:

```text
current explicit prompt
        ↓
actual repository state
        ↓
docs/backend contracts
        ↓
CLAUDE.md
```

The current explicit prompt is authoritative for scope.
