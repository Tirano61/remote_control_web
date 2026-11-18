import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/error/failure.dart';
import '../../../../../core/error/result.dart';
import '../../../../../core/logging/debug_log.dart';
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
/// REST is the source of truth. The BLoC never promotes a session to `ACTIVE`
/// on its own, and only ends one locally on a backend confirmation that it is
/// over: a successful `POST /remote-sessions/:id/close`, a
/// `remote-session:closed` naming it, or a read that no longer returns it.
///
/// The four operations are kept apart on purpose — create, load current,
/// activate and close fail differently and are recovered differently — and
/// none of them replaces a visible assistance with an empty loading screen.
///
/// Three rules keep an old answer from undoing a newer fact:
///
/// * **a closed session stays closed.** Its id is remembered, and no read,
///   failed close or late answer may put it back on screen. This is what
///   stops a close confirmed by the backend from being undone by a
///   `GET /remote-sessions/current` that failed right after it — the failure
///   is not allowed to "preserve" a session that is over;
/// * **one read at a time, and none is lost.** A refresh asked for while a read
///   is in flight marks that read stale: its answer, which may predate what
///   triggered the refresh, is dropped and one more read follows. A burst of
///   triggers costs one extra GET;
/// * **a failed read is not a confirmation.** The known session stays on screen,
///   marked unverified, so that the console can hold remote control back until
///   a read succeeds.
///
/// Socket.IO is deliberately absent from this class. Realtime only triggers a
/// refresh, an authority check or a closed report; it never carries a state.
/// WebRTC is absent too: whether the peers reached each other is decided
/// elsewhere and arrives here only as a [RemoteSessionActivationRequested].
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
    on<RemoteSessionAuthorityCheckRequested>(_onAuthorityCheckRequested);
    on<RemoteSessionClosedReported>(_onClosedReported);
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
  /// a read is in flight would fire a duplicate request. It is folded into the
  /// read in flight instead: see [_isReadStale].
  bool _isReading = false;

  /// Something asked for a read while one was in flight. That read may have
  /// been answered before whatever triggered the request, so its answer is
  /// dropped and the read is made again.
  bool _isReadStale = false;

  /// Bumped when the user session ends: whatever is in flight belongs to a
  /// console that is gone, and none of it may be applied.
  int _epoch = 0;

  /// The highest authority check asked for, and the highest a successful read
  /// started after it has answered.
  int _requestedAuthorityCheck = 0;
  int _answeredAuthorityCheck = 0;
  int _failedAuthorityCheck = 0;

  /// Whether the last read about the session on screen succeeded.
  bool _isVerified = true;

  /// The session a close or an activation is in flight for.
  ///
  /// Held here rather than read back from the state, so that a read answered
  /// meanwhile — a refresh, an authority check — keeps saying so instead of
  /// handing remote control back in the middle of FINALIZAR.
  String? _closingRemoteSessionId;
  String? _activatingRemoteSessionId;

  /// Sessions the backend confirmed are over. A closed session never reopens,
  /// so an answer that still shows one of these live is an old answer.
  final Set<String> _closedRemoteSessionIds = {};

  /// The support request a `POST /remote-sessions` is in flight for. A read
  /// answered meanwhile keeps saying so, or a second click could go out.
  String? _startingSupportRequestId;

  Future<void> _onStarted(
    RemoteSessionStarted event,
    Emitter<RemoteSessionState> emit,
  ) async {
    if (!state.hasLiveSession && !_isReading) {
      emit(const RemoteSessionLoading());
    }
    await _readCurrent(
      emit,
      (result, check) => _applyRead(emit, result, check),
    );
  }

  Future<void> _onRefreshRequested(
    RemoteSessionRefreshRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    if (state is RemoteSessionInitial) emit(const RemoteSessionLoading());
    await _readCurrent(
      emit,
      (result, check) => _applyRead(emit, result, check),
    );
  }

  Future<void> _onAuthorityCheckRequested(
    RemoteSessionAuthorityCheckRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    _requestedAuthorityCheck = math.max(
      _requestedAuthorityCheck,
      event.checkId,
    );
    if (state is RemoteSessionInitial) emit(const RemoteSessionLoading());
    await _readCurrent(
      emit,
      (result, check) => _applyRead(emit, result, check),
    );
  }

  Future<void> _onClosedReported(
    RemoteSessionClosedReported event,
    Emitter<RemoteSessionState> emit,
  ) async {
    final id = event.remoteSessionId;
    logDebug('remote session closed $id endedBy=${event.endedBy}');
    // Whatever session this is, it is over: the backend emits the event only
    // after the close committed. Remembering it costs nothing and protects
    // the console from an answer that predates the close.
    _closedRemoteSessionIds.add(id);

    if (state.session?.id == id) {
      // Ended here and now. Waiting for REST would leave a closed assistance
      // on screen — and, if REST failed, preserved as if it were still open.
      if (_closingRemoteSessionId == id) _closingRemoteSessionId = null;
      if (_activatingRemoteSessionId == id) _activatingRemoteSessionId = null;
      _isVerified = true;
      emit(const RemoteSessionIdle());
    }

    // REST is still asked: it may have something to say beyond this id.
    await _readCurrent(
      emit,
      (result, check) => _applyRead(emit, result, check),
    );
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

    final epoch = _epoch;
    _startingSupportRequestId = event.supportRequestId;
    emit(RemoteSessionIdle(startingSupportRequestId: event.supportRequestId));

    final result = await _createRemoteSession(
      supportRequestId: event.supportRequestId,
    );
    if (epoch != _epoch) return;
    _startingSupportRequestId = null;

    switch (result) {
      case Success<RemoteSession>(:final value):
        _isVerified = true;
        _emitSession(emit, value);
      case Failed<RemoteSession>(:final failure):
        // A 409 usually means this technician already holds a live session —
        // for instance after a create whose response was lost. Reconcile with
        // REST before deciding it was an error.
        if (failure is ConflictFailure) {
          await _readCurrent(
            emit,
            (result, check) => _applyAfterCreateConflict(
              emit,
              result,
              check,
              conflict: failure,
            ),
          );
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
    final epoch = _epoch;
    _activatingRemoteSessionId = session.id;
    _emitSession(emit, session);

    final result = await _activateRemoteSession(remoteSessionId: session.id);
    if (epoch != _epoch) return;
    if (_activatingRemoteSessionId == session.id) {
      _activatingRemoteSessionId = null;
    }

    switch (result) {
      case Success<RemoteSession>():
        // The response already carries the `ACTIVE` session, but REST stays
        // the source of truth: ask for the current one instead of assuming.
        await _readCurrent(
          emit,
          (result, check) => _applyRead(emit, result, check),
        );
      case Failed<RemoteSession>(:final failure):
        if (failure is ConflictFailure || failure is NotFoundFailure) {
          // The session stopped being activable — closed concurrently by the
          // tablet or by the backend, most likely. Reconcile instead of
          // keeping a state the backend has already moved on from.
          await _readCurrent(
            emit,
            (result, check) =>
                _applyAfterActivationConflict(emit, result, check, failure),
          );
        } else {
          // Everything else — a network failure above all — leaves the
          // assistance exactly as it was. The peers are still connected; only
          // the confirmation did not get through, and it can be retried.
          _emitSession(
            emit,
            session,
            failure: failure is NetworkFailure
                ? const NetworkFailure(kRemoteSessionActivationFailedNotice)
                : failure,
            canRetryActivation: _isRetryable(failure),
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
    final epoch = _epoch;
    _closingRemoteSessionId = session.id;
    // An activation that is still in flight keeps its flag: closing does not
    // make its guard disappear.
    _emitSession(emit, session);

    final result = await _closeRemoteSession(remoteSessionId: session.id);
    if (epoch != _epoch) return;
    if (_closingRemoteSessionId == session.id) _closingRemoteSessionId = null;

    switch (result) {
      case Success<RemoteSession>():
        // Confirmed by the backend: the assistance is over, whatever any read
        // answers next. It ends on screen now — not after a GET that may fail
        // and, failing, must not be what decides.
        _closedRemoteSessionIds.add(session.id);
        _isVerified = true;
        emit(const RemoteSessionIdle());
        // REST is still read, as everywhere: it is the source of truth for
        // what comes next, never for bringing this session back.
        await _readCurrent(
          emit,
          (result, check) => _applyAfterConfirmedClose(emit, result, check),
        );
      case Failed<RemoteSession>(:final failure):
        if (failure is ConflictFailure || failure is NotFoundFailure) {
          // The session probably stopped being live on its own — the tablet
          // or the backend closed it first. Reconcile instead of blocking.
          await _readCurrent(
            emit,
            (result, check) =>
                _applyAfterCloseConflict(emit, result, check, session: session),
          );
        } else {
          _emitSession(emit, session, failure: failure);
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
      // flight, and whether the session is confirmed, do not.
      _emitSession(emit, current.session);
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
    // Whatever is in flight belongs to the console that signed out.
    _epoch++;
    _isReading = false;
    _isReadStale = false;
    _closingRemoteSessionId = null;
    _activatingRemoteSessionId = null;
    _startingSupportRequestId = null;
    _isVerified = true;
    emit(const RemoteSessionInitial());
  }

  /// `GET /remote-sessions/current`, one at a time and never lost.
  ///
  /// If a read is already in flight, it is marked stale and this returns: that
  /// read will be made again and its answer applied with *its* [apply]. A read
  /// marked stale while travelling is dropped on arrival — it may have been
  /// answered before what triggered the new request — except a `401`, which
  /// has to reach the console whenever it comes.
  ///
  /// Each read records the highest authority check asked for when it started,
  /// which is what it answers if it succeeds.
  Future<void> _readCurrent(
    Emitter<RemoteSessionState> emit,
    void Function(Result<RemoteSession?> result, int check) apply,
  ) async {
    if (_isReading) {
      _isReadStale = true;
      return;
    }
    final epoch = _epoch;
    _isReading = true;
    try {
      while (true) {
        _isReadStale = false;
        final check = _requestedAuthorityCheck;
        final result = await _loadCurrentRemoteSession();
        if (isClosed || epoch != _epoch) return;
        final isAuthFailure =
            result is Failed<RemoteSession?> && result.failure is AuthFailure;
        if (_isReadStale && !isAuthFailure) {
          logDebug('remote session read superseded, reading again');
          continue;
        }
        // Whatever [apply] makes of it, a failed read answered this check
        // too: the console waiting on it must hear so, even when the state
        // it leaves behind looks exactly like the previous one.
        if (result is Failed<RemoteSession?>) {
          _failedAuthorityCheck = math.max(_failedAuthorityCheck, check);
        }
        apply(result, check);
        return;
      }
    } finally {
      if (epoch == _epoch) {
        _isReading = false;
        _isReadStale = false;
      }
    }
  }

  /// The answer of a successful read, applied.
  ///
  /// Returns the live session it showed, if any. A session REST no longer
  /// returns — gone, or replaced by another one — is remembered as closed:
  /// one live session per technician, and a closed session never reopens.
  RemoteSession? _applySuccessfulRead(
    Emitter<RemoteSessionState> emit,
    RemoteSession? value,
    int check, {
    Failure? failureIfNone,
  }) {
    _answeredAuthorityCheck = math.max(_answeredAuthorityCheck, check);
    final known = state.session;
    final live =
        value != null &&
            value.isLive &&
            !_closedRemoteSessionIds.contains(value.id)
        ? value
        : null;
    if (value != null && value.isLive && live == null) {
      // An answer that predates a close this console already knows about.
      logDebug('closed remote session ignored in a read ${value.id}');
    }
    if (known != null && known.id != live?.id) {
      _closedRemoteSessionIds.add(known.id);
    }
    if (live == null) {
      _isVerified = true;
      emit(
        RemoteSessionIdle(
          failure: failureIfNone,
          startingSupportRequestId: _startingSupportRequestId,
        ),
      );
      return null;
    }
    _isVerified = true;
    _emitSession(emit, live);
    return live;
  }

  /// The usual answer to a read: REST decides, a failure preserves.
  void _applyRead(
    Emitter<RemoteSessionState> emit,
    Result<RemoteSession?> result,
    int check,
  ) {
    switch (result) {
      case Success<RemoteSession?>(:final value):
        _applySuccessfulRead(emit, value, check);
      case Failed<RemoteSession?>(:final failure):
        _emitUnverified(emit, failure);
    }
  }

  /// After a close the backend confirmed. The session is over whatever this
  /// read says: a failure leaves the console without an assistance, and only a
  /// rejected token is reported — the console must see it.
  void _applyAfterConfirmedClose(
    Emitter<RemoteSessionState> emit,
    Result<RemoteSession?> result,
    int check,
  ) {
    switch (result) {
      case Success<RemoteSession?>(:final value):
        _applySuccessfulRead(emit, value, check);
      case Failed<RemoteSession?>(:final failure):
        if (failure is AuthFailure) emit(RemoteSessionIdle(failure: failure));
      // Anything else: the close stands, and nothing is shown for a read
      // that only wanted to confirm it.
    }
  }

  void _applyAfterCreateConflict(
    Emitter<RemoteSessionState> emit,
    Result<RemoteSession?> result,
    int check, {
    required Failure conflict,
  }) {
    switch (result) {
      case Success<RemoteSession?>(:final value):
        // Recovered: show the session the technician already had, without
        // reporting an error the user cannot act on.
        _applySuccessfulRead(emit, value, check, failureIfNone: conflict);
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
  void _applyAfterActivationConflict(
    Emitter<RemoteSessionState> emit,
    Result<RemoteSession?> result,
    int check,
    Failure conflict,
  ) {
    switch (result) {
      case Success<RemoteSession?>(:final value):
        // Gone: the assistance is over, whatever the console still had on
        // screen. No fictional `CONNECTING` session is kept alive.
        _applySuccessfulRead(emit, value, check);
      case Failed<RemoteSession?>(:final failure):
        // A rejected token must reach the console; anything else is reported
        // as the refusal that started this.
        _emitUnverified(emit, failure is AuthFailure ? failure : conflict);
    }
  }

  void _applyAfterCloseConflict(
    Emitter<RemoteSessionState> emit,
    Result<RemoteSession?> result,
    int check, {
    required RemoteSession session,
  }) {
    switch (result) {
      case Success<RemoteSession?>(:final value):
        // Gone: the close the console asked for already happened. Nothing to
        // report — the assistance is over either way.
        final live = _applySuccessfulRead(emit, value, check);
        if (live != null) {
          _emitSession(
            emit,
            live,
            failure: const ConflictFailure(kRemoteSessionStillLiveNotice),
          );
        }
      case Failed<RemoteSession?>(:final failure):
        // The close was refused and nobody can say why: the session is kept,
        // but not as a confirmed one.
        _emitUnverified(emit, failure);
    }
  }

  /// Emits [session] with what this BLoC knows about it — close or activation
  /// in flight, confirmed or not — unless the backend already said it is over.
  void _emitSession(
    Emitter<RemoteSessionState> emit,
    RemoteSession session, {
    Failure? failure,
    bool canRetryActivation = false,
  }) {
    if (_closedRemoteSessionIds.contains(session.id)) {
      // A late answer about an assistance that is over. Nothing brings it
      // back; whatever is on screen now already says so.
      logDebug('closed remote session not restored ${session.id}');
      if (state.session?.id == session.id) emit(const RemoteSessionIdle());
      return;
    }
    emit(
      RemoteSessionState.fromSession(
        session,
        isClosing: _closingRemoteSessionId == session.id,
        isActivating: _activatingRemoteSessionId == session.id,
        canRetryActivation: canRetryActivation,
        isVerified: _isVerified,
        answeredAuthorityCheck: _answeredAuthorityCheck,
        failedAuthorityCheck: _failedAuthorityCheck,
        failure: failure,
      ),
    );
  }

  /// A read failed: what is known stays on screen, but unconfirmed.
  void _emitUnverified(Emitter<RemoteSessionState> emit, Failure failure) {
    final reported = failure is NetworkFailure
        ? const NetworkFailure(kRemoteSessionRefreshFailedNotice)
        : failure;
    final previous = state;
    final known = previous.session;
    if (known != null) {
      _isVerified = false;
      _emitSession(emit, known, failure: reported);
      return;
    }
    if (previous is RemoteSessionIdle) {
      emit(
        RemoteSessionIdle(
          failure: reported,
          startingSupportRequestId: _startingSupportRequestId,
        ),
      );
      return;
    }
    emit(RemoteSessionFailure(reported));
  }

  /// Whether a new attempt could plausibly succeed.
  ///
  /// Only transport level problems qualify. A refusal is a backend decision
  /// and a rejected token needs a new login, so neither offers a retry.
  static bool _isRetryable(Failure failure) =>
      failure is NetworkFailure || failure is ServerFailure;
}
