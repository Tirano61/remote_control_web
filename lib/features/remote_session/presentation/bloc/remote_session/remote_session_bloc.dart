import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/error/failure.dart';
import '../../../../../core/error/result.dart';
import '../../../domain/entities/remote_session.dart';
import '../../../domain/usecases/activate_remote_session.dart';
import '../../../domain/usecases/close_remote_session.dart';
import '../../../domain/usecases/create_remote_session.dart';
import '../../../domain/usecases/load_current_remote_session.dart';

part 'remote_session_event.dart';
part 'remote_session_state.dart';

/// Shown when the state could not be refreshed because the backend was not
/// reachable. The known session is kept on screen and the user may retry.
const String kRemoteSessionRefreshFailedNotice =
    'No se pudo actualizar el estado de la asistencia.';

/// Shown when a close was refused but the session is still live.
const String kRemoteSessionStillLiveNotice =
    'La asistencia sigue activa. Vuelve a intentarlo.';

/// Shown when the activation could not be confirmed with the backend.
///
/// The wording is deliberate: the remote connection itself is fine — it is the
/// confirmation that did not get through — and it can be retried.
const String kRemoteSessionActivationFailedNotice =
    'La conexión con el dispositivo está establecida, pero no se pudo '
    'confirmar el inicio de la asistencia.';

/// Owns the remote session of the signed-in technician.
///
/// REST is the source of truth. The BLoC never promotes a session to `CLOSED`
/// or to `ACTIVE` on its own: every transition it shows came from
/// `GET /remote-sessions/current`, `POST /remote-sessions`,
/// `POST /remote-sessions/:id/activate` or `POST /remote-sessions/:id/close`.
///
/// The four operations are kept apart on purpose — create, load current,
/// activate and close fail differently and are recovered differently — and
/// none of them replaces a visible assistance with an empty loading screen.
///
/// Socket.IO is deliberately absent from this class. Realtime only triggers a
/// [RemoteSessionRefreshRequested]; it never carries the state itself. WebRTC
/// is absent too: whether the peers reached each other is decided elsewhere
/// and arrives here only as a [RemoteSessionActivationRequested].
class RemoteSessionBloc extends Bloc<RemoteSessionEvent, RemoteSessionState> {
  RemoteSessionBloc({
    required LoadCurrentRemoteSession loadCurrentRemoteSession,
    required CreateRemoteSession createRemoteSession,
    required ActivateRemoteSession activateRemoteSession,
    required CloseRemoteSession closeRemoteSession,
  }) : _loadCurrentRemoteSession = loadCurrentRemoteSession,
       _createRemoteSession = createRemoteSession,
       _activateRemoteSession = activateRemoteSession,
       _closeRemoteSession = closeRemoteSession,
       super(const RemoteSessionInitial()) {
    on<RemoteSessionStarted>(_onStarted);
    on<RemoteSessionRefreshRequested>(_onRefreshRequested);
    on<RemoteSessionCreateRequested>(_onCreateRequested);
    on<RemoteSessionActivationRequested>(_onActivationRequested);
    on<RemoteSessionCloseRequested>(_onCloseRequested);
    on<RemoteSessionNoticeDismissed>(_onNoticeDismissed);
    on<RemoteSessionCleared>(_onCleared);
  }

  final LoadCurrentRemoteSession _loadCurrentRemoteSession;
  final CreateRemoteSession _createRemoteSession;
  final ActivateRemoteSession _activateRemoteSession;
  final CloseRemoteSession _closeRemoteSession;

  /// Events are processed concurrently by default, so a refresh arriving while
  /// the first read is still in flight would fire a duplicate request.
  bool _isLoading = false;

  Future<void> _onStarted(
    RemoteSessionStarted event,
    Emitter<RemoteSessionState> emit,
  ) async {
    if (_isLoading) return;
    emit(const RemoteSessionLoading());
    await _loadCurrent(emit);
  }

  Future<void> _onRefreshRequested(
    RemoteSessionRefreshRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    if (_isLoading) return;
    if (state is RemoteSessionInitial) emit(const RemoteSessionLoading());
    await _loadCurrent(emit);
  }

  Future<void> _onCreateRequested(
    RemoteSessionCreateRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    final current = state;
    // The backend allows one live session per technician, so the console never
    // even offers a second one.
    if (current.hasLiveSession) return;
    // One creation at a time: a second click is dropped before the network.
    if (current is RemoteSessionIdle && current.isStarting) return;

    emit(RemoteSessionIdle(startingSupportRequestId: event.supportRequestId));

    final result = await _createRemoteSession(
      supportRequestId: event.supportRequestId,
    );

    switch (result) {
      case Success<RemoteSession>(:final value):
        emit(RemoteSessionState.fromSession(value));
      case Failed<RemoteSession>(:final failure):
        // A 409 usually means this technician already holds a live session —
        // for instance after a create whose response was lost. Reconcile with
        // REST before deciding it was an error.
        if (failure is ConflictFailure) {
          await _reconcileAfterCreateConflict(emit, conflict: failure);
        } else {
          emit(RemoteSessionIdle(failure: failure));
        }
    }
  }

  /// `POST /remote-sessions/:id/activate`.
  ///
  /// The assistance stays on screen throughout: this is a confirmation sent
  /// while the technician is already working, not a page transition.
  Future<void> _onActivationRequested(
    RemoteSessionActivationRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    final current = state;
    // Only a `CONNECTING` session is activable. An `ACTIVE` one is already
    // where the backend would put it, so no request is even sent; and a
    // session that is not live is not this technician's business any more.
    if (current is! RemoteSessionConnecting) return;
    // An id is never adopted from outside: the activation has to name the
    // session REST gave us, or it is about something else entirely.
    if (current.session.id != event.remoteSessionId) return;
    // One activation at a time. The backend is idempotent, but a second
    // request while the first is unanswered buys nothing.
    if (current.isActivating) return;

    final session = current.session;
    emit(RemoteSessionState.fromSession(session, isActivating: true));

    final result = await _activateRemoteSession(remoteSessionId: session.id);

    switch (result) {
      case Success<RemoteSession>():
        // The response already carries the `ACTIVE` session, but REST stays
        // the source of truth: ask for the current one instead of assuming.
        await _loadCurrent(emit);
      case Failed<RemoteSession>(:final failure):
        if (failure is ConflictFailure || failure is NotFoundFailure) {
          // The session stopped being activable — closed concurrently by the
          // tablet, most likely. Reconcile instead of keeping a state the
          // backend has already moved on from.
          await _reconcileAfterActivationConflict(emit, conflict: failure);
        } else {
          // Everything else — a network failure above all — leaves the
          // assistance exactly as it was. The peers are still connected; only
          // the confirmation did not get through, and it can be retried.
          emit(
            RemoteSessionState.fromSession(
              session,
              failure: failure is NetworkFailure
                  ? const NetworkFailure(kRemoteSessionActivationFailedNotice)
                  : failure,
              canRetryActivation: _isRetryable(failure),
            ),
          );
        }
    }
  }

  Future<void> _onCloseRequested(
    RemoteSessionCloseRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    final current = state;
    if (current is! RemoteSessionLive) return;
    // One close at a time: the button is disabled too, this is the safety net.
    if (current.isClosing) return;

    final session = current.session;
    // An activation that is still in flight keeps its flag: closing does not
    // make its guard disappear.
    emit(
      RemoteSessionState.fromSession(
        session,
        isClosing: true,
        isActivating: current.isActivating,
      ),
    );

    final result = await _closeRemoteSession(remoteSessionId: session.id);

    switch (result) {
      case Success<RemoteSession>():
        // The response already carries the closed session, but REST stays the
        // source of truth: ask for the current one instead of assuming.
        await _loadCurrent(emit);
      case Failed<RemoteSession>(:final failure):
        if (failure is ConflictFailure || failure is NotFoundFailure) {
          // The session probably stopped being live on its own — the tablet
          // closed it first. Reconcile instead of blocking the UI.
          await _reconcileAfterCloseConflict(emit, session: session);
        } else {
          emit(RemoteSessionState.fromSession(session, failure: failure));
        }
    }
  }

  void _onNoticeDismissed(
    RemoteSessionNoticeDismissed event,
    Emitter<RemoteSessionState> emit,
  ) {
    final current = state;
    if (current.failure == null) return;
    if (current is RemoteSessionLive) {
      // The retry offer goes with the banner it belonged to; what is in
      // flight does not.
      emit(
        RemoteSessionState.fromSession(
          current.session,
          isClosing: current.isClosing,
          isActivating: current.isActivating,
        ),
      );
    } else if (current is RemoteSessionIdle) {
      emit(
        RemoteSessionIdle(
          startingSupportRequestId: current.startingSupportRequestId,
        ),
      );
    }
  }

  void _onCleared(
    RemoteSessionCleared event,
    Emitter<RemoteSessionState> emit,
  ) {
    emit(const RemoteSessionInitial());
  }

  /// Reads `GET /remote-sessions/current` and turns it into a state.
  ///
  /// A failure never throws away what is already known: the assistance stays on
  /// screen with a retry, which is what the user needs when the network blinks.
  Future<void> _loadCurrent(Emitter<RemoteSessionState> emit) async {
    final previous = state;
    final result = await _readCurrent();

    switch (result) {
      case Success<RemoteSession?>(:final value):
        emit(
          value == null
              ? const RemoteSessionIdle()
              : RemoteSessionState.fromSession(value),
        );
      case Failed<RemoteSession?>(:final failure):
        emit(_preservingKnownState(previous, failure));
    }
  }

  Future<void> _reconcileAfterCreateConflict(
    Emitter<RemoteSessionState> emit, {
    required Failure conflict,
  }) async {
    final result = await _readCurrent();

    switch (result) {
      case Success<RemoteSession?>(:final value):
        // Recovered: show the session the technician already had, without
        // reporting an error the user cannot act on.
        emit(
          value == null
              ? RemoteSessionIdle(failure: conflict)
              : RemoteSessionState.fromSession(value),
        );
      case Failed<RemoteSession?>(:final failure):
        // A rejected token must reach the console; anything else is reported as
        // the conflict the user actually triggered.
        emit(
          RemoteSessionIdle(
            failure: failure is AuthFailure ? failure : conflict,
          ),
        );
    }
  }

  /// A refused activation is never turned into a local state: REST is asked
  /// what the session really is now.
  Future<void> _reconcileAfterActivationConflict(
    Emitter<RemoteSessionState> emit, {
    required Failure conflict,
  }) async {
    final previous = state;
    final result = await _readCurrent();

    switch (result) {
      case Success<RemoteSession?>(:final value):
        // Gone: the assistance is over, whatever the console still had on
        // screen. No fictional `CONNECTING` session is kept alive.
        emit(
          value == null
              ? const RemoteSessionIdle()
              : RemoteSessionState.fromSession(value),
        );
      case Failed<RemoteSession?>(:final failure):
        // A rejected token must reach the console; anything else is reported
        // as the refusal that started this.
        emit(
          _preservingKnownState(
            previous,
            failure is AuthFailure ? failure : conflict,
          ),
        );
    }
  }

  Future<void> _reconcileAfterCloseConflict(
    Emitter<RemoteSessionState> emit, {
    required RemoteSession session,
  }) async {
    final result = await _readCurrent();

    switch (result) {
      case Success<RemoteSession?>(:final value):
        // Gone: the close the console asked for already happened. Nothing to
        // report — the assistance is over either way.
        emit(
          value == null
              ? const RemoteSessionIdle()
              : RemoteSessionState.fromSession(
                  value,
                  failure: const ConflictFailure(kRemoteSessionStillLiveNotice),
                ),
        );
      case Failed<RemoteSession?>(:final failure):
        emit(RemoteSessionState.fromSession(session, failure: failure));
    }
  }

  Future<Result<RemoteSession?>> _readCurrent() async {
    _isLoading = true;
    try {
      return await _loadCurrentRemoteSession();
    } finally {
      _isLoading = false;
    }
  }

  /// Whether a new attempt could plausibly succeed.
  ///
  /// Only transport level problems qualify. A refusal is a backend decision
  /// and a rejected token needs a new login, so neither offers a retry.
  static bool _isRetryable(Failure failure) =>
      failure is NetworkFailure || failure is ServerFailure;

  /// Keeps the last known session visible when the backend could not be read.
  RemoteSessionState _preservingKnownState(
    RemoteSessionState previous,
    Failure failure,
  ) {
    final reported = failure is NetworkFailure
        ? const NetworkFailure(kRemoteSessionRefreshFailedNotice)
        : failure;
    final known = previous.session;
    if (known != null) {
      return RemoteSessionState.fromSession(known, failure: reported);
    }
    if (previous is RemoteSessionIdle) {
      return RemoteSessionIdle(failure: reported);
    }
    return RemoteSessionFailure(reported);
  }
}
