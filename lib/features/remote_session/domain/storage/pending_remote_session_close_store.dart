/// Remembers, across page reloads and browser restarts, the remote sessions
/// this console finalized whose close the backend has not confirmed yet.
///
/// It is a deny list, not a source of truth: an id in it is never shown as an
/// assistance again — whatever a `GET /remote-sessions/current` that started
/// before the close says — and the close is asked for again whenever the
/// backend still answers with that exact id as this technician's live session.
/// It never makes a session appear, and it never decides that one is over.
///
/// Only remote session ids are kept: no token, no user, no device. Presentation
/// and domain do not know where they are written.
///
/// Implementations must never throw: a storage that is full, blocked or
/// corrupt degrades to "nothing remembered", and the in-memory protection of
/// the running page stays in force regardless.
abstract interface class PendingRemoteSessionCloseStore {
  /// The ids still waiting for their close to be confirmed.
  Future<Set<String>> read();

  /// FINALIZAR was pressed for [remoteSessionId].
  Future<void> add(String remoteSessionId);

  /// The backend confirmed that [remoteSessionId] is no longer live.
  Future<void> remove(String remoteSessionId);
}
