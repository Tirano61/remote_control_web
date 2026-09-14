# User JWT persistence on Flutter Web — security decision

Stage: Prompt 1 (technician/admin authentication).

## What is persisted

Only the **User JWT** returned by `POST /auth/login` and renewed by
`GET /auth/check-status`.

```text
key    remote_control_web.user_token
value  <user jwt>
```

Never persisted:

```text
password
user profile (id, email, fullName, roles, isActive)
Device JWT
```

The user profile is deliberately *not* cached: it is re-fetched from
`GET /auth/check-status` on every application start, so `isActive`, `roles` and
the identity always come from the backend and never from a value the browser
could have been tricked into holding.

## Where it is persisted

`shared_preferences` (`SharedPreferencesAsync`), which on Flutter Web is backed
by `window.localStorage`. It is the maintained, first-party option and it is
what makes the session survive a page refresh — the requirement for this stage.

The implementation is `BrowserUserTokenStorage`, and it is reachable only
through the `UserTokenStorage` port. Domain, BLoCs and widgets do not know that
browser storage exists.

## The trade-off

`localStorage` is readable by **any JavaScript running on the origin**. A
successful XSS on this application would therefore be able to read the User JWT
and impersonate the technician until it expires.

The alternative that removes this exposure is an **HttpOnly, Secure, SameSite
cookie** issued by the backend. It is not available today:

* the current contract returns the token inside the JSON body of
  `POST /auth/login`;
* every protected route expects `Authorization: Bearer <user token>`;
* adopting cookies would change `remote_control_backend`, and the backend is
  the source of truth. Changing the contract is not part of this stage.

Accepted, with the following mitigations already in place:

* **Bounded exposure.** User JWTs live 2h and there is no refresh token, so a
  stolen token expires on its own and cannot be silently renewed forever.
* **No password at rest.** The password exists only inside the login form's
  `TextEditingController` while the field is on screen. It never enters a BLoC
  state, never reaches storage and never reaches a log.
* **No secrets in logs.** No Dio logging interceptor is installed, transport
  errors are reduced to a status code before leaving the data layer, and
  `UserSession`, `LoginState` and the session BLoC events/states override
  `toString()` so the token is never printed. This is covered by
  `test/features/auth/secret_handling_test.dart`.
* **Single storage key, namespaced**, so clearing the session is exact.
* **Backend stays authoritative.** The client-side role check (`admin` or
  `tecnico`) only hides UI; every endpoint is still protected server-side.

## Deferred to later stages

```text
strict Content-Security-Policy in web/index.html
HttpOnly cookie authentication (requires a backend contract change)
server-side token revocation (does not exist in the contract today)
```
