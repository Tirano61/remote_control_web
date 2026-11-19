import 'dart:async';
import 'dart:math' as math;

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/error/failure.dart';
import '../../../../../core/error/result.dart';
import '../../../../../core/logging/debug_log.dart';
import '../../../domain/entities/remote_session.dart';
import '../../../domain/entities/remote_session_close_outcome.dart';
import '../../../domain/storage/pending_remote_session_close_store.dart';
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

/// Shown once the backend confirmed that an assistance finalized here is over.
const String kRemoteSessionFinishedNotice = 'Asistencia finalizada.';

/// Shown while the close of an assistance finalized here is being confirmed.
const String kRemoteSessionCloseConfirmingNotice =
    'La asistencia se detuvo en esta consola. Confirmando el cierre con el '
    'servidor...';

/// Shown when the backend could not confirm the close of an assistance
/// finalized here. Nothing in it says the assistance is over server side: it
/// was not confirmed.
const String kRemoteSessionCloseUnconfirmedNotice =
    'La asistencia se detuvo en esta consola, pero no se pudo confirmar su '
    'cierre en el servidor.';

/// Shown when the activation could not be confirmed with the backend.
///
/// The wording is deliberate: the remote connection itself is fine — it is the
/// confirmation that did not get through — and it can be retried.
const String kRemoteSessionActivationFailedNotice =
    'La conexión con el dispositivo está establecida, pero no se pudo '
    'confirmar el inicio de la asistencia.';

/// Owns the remote session of the signed-in technician.
///
/// REST is the source of truth for what the backend holds. The BLoC never
/// promotes a session to `ACTIVE` on its own, and only calls one *closed* on a
/// backend confirmation: a successful `POST /remote-sessions/:id/close` (or a
/// `GET /remote-sessions/:id` answering `CLOSED` after a `409`), a
/// `remote-session:closed` naming it, or a read that no longer returns it.
///
/// FINALIZAR is the one decision that does not wait for the backend. The
/// technician said the assistance is over, so it is over **for this console**
/// at once: the session leaves the live states before the close is even sent
/// ([RemoteSessionEnding]), everything keyed on a live session lets go of it,
/// and no answer brings it back — not a failed close, not a read that still
/// lists it, not an F5, not signing in again. Its id is remembered in memory
/// and in a [PendingRemoteSessionCloseStore] until the backend confirms the
/// close, which is asked for again on a bounded, spaced schedule.
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
    required PendingRemoteSessionCloseStore pendingCloseStore,
    List<Duration> closeRetryDelays = defaultCloseRetryDelays,
  }) : _loadCurrentRemoteSession = loadCurrentRemoteSession,
       _createRemoteSession = createRemoteSession,
       _activateRemoteSession = activateRemoteSession,
       _closeRemoteSession = closeRemoteSession,
       _pendingCloseStore = pendingCloseStore,
       _closeRetryDelays = closeRetryDelays,
       super(const RemoteSessionInitial()) {
    on<RemoteSessionStarted>(_onStarted);
    on<RemoteSessionRefreshRequested>(_onRefreshRequested);
    on<RemoteSessionAuthorityCheckRequested>(_onAuthorityCheckRequested);
    on<RemoteSessionClosedReported>(_onClosedReported);
    on<RemoteSessionCreateRequested>(_onCreateRequested);
    on<RemoteSessionActivationRequested>(_onActivationRequested);
    on<RemoteSessionCloseRequested>(_onCloseRequested);
    on<RemoteSessionCloseRetryRequested>(_onCloseRetryRequested);
    on<_RemoteSessionCloseRetryDue>(_onCloseRetryDue);
    on<RemoteSessionNoticeDismissed>(_onNoticeDismissed);
    on<RemoteSessionCleared>(_onCleared);
  }

  final LoadCurrentRemoteSession _loadCurrentRemoteSession;
  final CreateRemoteSession _createRemoteSession;
  final ActivateRemoteSession _activateRemoteSession;
  final CloseRemoteSession _closeRemoteSession;
  final PendingRemoteSessionCloseStore _pendingCloseStore;

  /// When each automatic retry of an unconfirmed close starts, counted from
  /// the attempt that could not confirm it. One entry per retry, so the list is
  /// also the budget: with the first attempt, five requests over about a
  /// minute — never a storm. Past it the console says the close is
  /// unconfirmed and waits for REINTENTAR, a socket that comes back, or the
  /// backend itself (`remote-session:closed`, a read that no longer lists the
  /// session).
  static const List<Duration> defaultCloseRetryDelays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  final List<Duration> _closeRetryDelays;

  /// Sessions FINALIZAR was pressed for, in this page or — read from the
  /// [PendingRemoteSessionCloseStore] — before it was reloaded. Never shown as
  /// an assistance again, whatever any answer says. Kept across a sign out.
  final Set<String> _finalizedRemoteSessionIds = {};

  /// The ids of [_finalizedRemoteSessionIds] that are still written in the
  /// store, so that a read showing they are over can forget them there.
  final Set<String> _storedFinalizationIds = {};
  Future<void>? _storedFinalizationsLoaded;
  bool _areStoredFinalizationsLoaded = false;

  /// The close this console is still trying to get confirmed, if any.
  _PendingClose? _pendingClose;

  /// "Asistencia finalizada.", from the confirmation until it is dismissed or
  /// a new assistance starts.
  String? _finishedNotice;

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

  /// The session an activation is in flight for.
  ///
  /// Held here rather than read back from the state, so that a read answered
  /// meanwhile — a refresh, an authority check — keeps saying so.
  String? _activatingRemoteSessionId;

  /// Sessions the backend confirmed are over. A closed session never reopens,
  /// so an answer that still shows one of these live is an old answer.
  final Set<String> _closedRemoteSessionIds = {};

  @override
  Future<void> close() {
    _pendingClose?.cancelRetry();
    return super.close();
  }

  /// The support request a `POST /remote-sessions` is in flight for. A read
  /// answered meanwhile keeps saying so, or a second click could go out.
  String? _startingSupportRequestId;

  Future<void> _onStarted(
    RemoteSessionStarted event,
    Emitter<RemoteSessionState> emit,
  ) async {
    if (!state.hasLiveSession && !_isReading && state is! RemoteSessionEnding) {
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

    final pending = _pendingClose;
    if (pending != null && pending.remoteSessionId == id) {
      // The close FINALIZAR asked for is confirmed — by this event, whoever
      // won the race to close it. Nothing more is sent for it.
      _settlePendingClose(pending);
      _emitNoLiveSession(emit);
    } else if (state.session?.id == id) {
      // Ended here and now. Waiting for REST would leave a closed assistance
      // on screen — and, if REST failed, preserved as if it were still open.
      if (_activatingRemoteSessionId == id) _activatingRemoteSessionId = null;
      _isVerified = true;
      _emitNoLiveSession(emit);
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
    // The close of the previous assistance comes first: until the backend
    // confirms it, it may still hold that session, and one live session per
    // technician is the rule.
    if (_pendingClose != null) return;

    final epoch = _epoch;
    _startingSupportRequestId = event.supportRequestId;
    _finishedNotice = null;
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
          _emitNoLiveSession(emit, failure: failure);
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

  /// FINALIZAR.
  ///
  /// Everything local happens first, in this order and before anything is
  /// awaited: the session is finalized for good in memory, [RemoteSessionEnding]
  /// is emitted — which is what makes the console withdraw remote control,
  /// cancel a finger still down with a `touch_cancel`, drop what is pending and
  /// release the room, the data channel and the peer connection — and the
  /// decision is written to the store. Only then, one turn of the event loop
  /// later so that the revocation — all of it local — has run, is the backend
  /// asked. Its answer decides what the technician is told, never whether the
  /// assistance comes back.
  Future<void> _onCloseRequested(
    RemoteSessionCloseRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    final current = state;
    if (current is! RemoteSessionLive) return;

    final session = current.session;
    final epoch = _epoch;
    logDebug('remote session finalized locally ${session.id}');
    _finalizedRemoteSessionIds.add(session.id);
    if (_activatingRemoteSessionId == session.id) {
      _activatingRemoteSessionId = null;
    }
    _isVerified = true;
    _finishedNotice = null;
    _pendingClose?.cancelRetry();
    final pending = _PendingClose.of(session)..isPreparing = true;
    _pendingClose = pending;
    _emitNoLiveSession(emit);

    await _rememberFinalization(session.id);
    await Future<void>(() {});
    pending.isPreparing = false;
    if (isClosed || epoch != _epoch || !identical(_pendingClose, pending)) {
      return;
    }
    await _attemptClose(emit, pending);
  }

  Future<void> _onCloseRetryRequested(
    RemoteSessionCloseRetryRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    final pending = _pendingClose;
    if (pending == null || pending.isInFlight || pending.isPreparing) return;
    // A fresh schedule: something genuinely new happened — the user asked, or
    // the network came back.
    pending
      ..cancelRetry()
      ..retriesUsed = 0;
    await _attemptClose(emit, pending);
  }

  Future<void> _onCloseRetryDue(
    _RemoteSessionCloseRetryDue event,
    Emitter<RemoteSessionState> emit,
  ) async {
    final pending = _pendingClose;
    if (pending == null || pending.remoteSessionId != event.remoteSessionId) {
      return;
    }
    pending.retryTimer = null;
    await _attemptClose(emit, pending);
  }

  /// One `POST /remote-sessions/:id/close` for exactly [pending]'s session,
  /// and what its outcome means.
  Future<void> _attemptClose(
    Emitter<RemoteSessionState> emit,
    _PendingClose pending,
  ) async {
    if (!identical(_pendingClose, pending) || pending.isInFlight) return;
    pending
      ..cancelRetry()
      ..isInFlight = true
      ..attempts += 1;
    final id = pending.remoteSessionId;
    final epoch = _epoch;
    _emitNoLiveSession(emit);
    logDebug('remote session close attempt ${pending.attempts} $id');

    final outcome = await _closeRemoteSession(remoteSessionId: id);
    if (isClosed || epoch != _epoch) return;
    pending.isInFlight = false;
    // Settled meanwhile — `remote-session:closed`, or a read that no longer
    // lists it. Whatever this answer says, nothing is left to do.
    if (!identical(_pendingClose, pending)) return;

    switch (outcome) {
      case RemoteSessionCloseConfirmed():
        logDebug('remote session close confirmed $id');
        _settlePendingClose(pending);
        _emitNoLiveSession(emit);
        // REST is still read, as everywhere: it is the source of truth for
        // what comes next, never for bringing this session back.
        await _readCurrent(
          emit,
          (result, check) => _applyAfterConfirmedClose(emit, result, check),
        );
      case RemoteSessionCloseRefused(:final failure):
        // The same request would get the same answer: nothing retries it on
        // its own. Still finalized here.
        logDebug('remote session close refused $id');
        _emitNoLiveSession(emit, failure: failure);
      case RemoteSessionCloseUnconfirmed(:final failure):
        if (failure is! AuthFailure) _scheduleCloseRetry(pending);
        _emitNoLiveSession(emit, failure: failure);
    }
  }

  void _scheduleCloseRetry(_PendingClose pending) {
    if (pending.retriesUsed >= _closeRetryDelays.length) {
      logDebug(
        'remote session close unconfirmed, retries exhausted '
        '${pending.remoteSessionId}',
      );
      return;
    }
    final delay = _closeRetryDelays[pending.retriesUsed];
    pending.retriesUsed++;
    logDebug(
      'remote session close retry ${pending.retriesUsed}/'
      '${_closeRetryDelays.length} in ${delay.inMilliseconds} ms '
      '${pending.remoteSessionId}',
    );
    pending.retryTimer = Timer(delay, () {
      if (!isClosed) add(_RemoteSessionCloseRetryDue(pending.remoteSessionId));
    });
  }

  /// The backend holds no live session by [pending]'s id for this technician
  /// any more: the close is over, and so is its retry schedule.
  void _settlePendingClose(_PendingClose pending) {
    pending.cancelRetry();
    if (identical(_pendingClose, pending)) _pendingClose = null;
    _closedRemoteSessionIds.add(pending.remoteSessionId);
    _forgetStoredFinalization(pending.remoteSessionId);
    _isVerified = true;
    _finishedNotice = kRemoteSessionFinishedNotice;
  }

  /// A read showed [session] — finalized here — still live: the backend never
  /// got, or never committed, the close. It is asked for again, at once,
  /// unless this console is already on it.
  void _resumePendingClose(RemoteSession session) {
    final pending = _pendingClose;
    if (pending != null && pending.remoteSessionId == session.id) return;
    // One live session per technician: another one being live means the
    // previous pending close is over.
    if (pending != null) _settlePendingClose(pending);
    logDebug('remote session finalized here is still live ${session.id}');
    final resumed = _PendingClose.of(session);
    _pendingClose = resumed;
    _finishedNotice = null;
    unawaited(_rememberFinalization(session.id));
    resumed.retryTimer = Timer(Duration.zero, () {
      if (!isClosed) add(_RemoteSessionCloseRetryDue(session.id));
    });
  }

  Future<void> _rememberFinalization(String remoteSessionId) async {
    _storedFinalizationIds.add(remoteSessionId);
    await _pendingCloseStore.add(remoteSessionId);
  }

  void _forgetStoredFinalization(String remoteSessionId) {
    if (!_storedFinalizationIds.remove(remoteSessionId)) return;
    unawaited(_pendingCloseStore.remove(remoteSessionId));
  }

  /// Reads, once, the sessions finalized before this page was loaded.
  Future<void> _loadStoredFinalizations() =>
      _storedFinalizationsLoaded ??= () async {
        final ids = await _pendingCloseStore.read();
        _areStoredFinalizationsLoaded = true;
        if (ids.isEmpty) return;
        logDebug('remote sessions finalized before this page: ${ids.length}');
        _finalizedRemoteSessionIds.addAll(ids);
        _storedFinalizationIds.addAll(ids);
      }();

  void _onNoticeDismissed(
    RemoteSessionNoticeDismissed event,
    Emitter<RemoteSessionState> emit,
  ) {
    final current = state;
    if (current is RemoteSessionLive) {
      if (current.failure == null) return;
      // The retry offer goes with the banner it belonged to; what is in
      // flight, and whether the session is confirmed, do not.
      _emitSession(emit, current.session);
    } else if (current is RemoteSessionIdle) {
      if (current.failure == null && current.notice == null) return;
      _finishedNotice = null;
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
    _activatingRemoteSessionId = null;
    _startingSupportRequestId = null;
    _isVerified = true;
    // The schedule belongs to the console that signed out. What was finalized
    // stays finalized: signing in again resumes the close when the backend
    // still lists the session, and never shows it as an assistance.
    _pendingClose?.cancelRetry();
    _pendingClose = null;
    _finishedNotice = null;
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
      if (!_areStoredFinalizationsLoaded) {
        await _loadStoredFinalizations();
        if (isClosed || epoch != _epoch) return;
      }
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
  ///
  /// A session finalized here is never shown, whatever the read says: still
  /// listed, its close is asked for again; no longer listed, its close is
  /// confirmed — this read, ownership scoped, says this technician has no such
  /// live session.
  RemoteSession? _applySuccessfulRead(
    Emitter<RemoteSessionState> emit,
    RemoteSession? value,
    int check, {
    Failure? failureIfNone,
  }) {
    _answeredAuthorityCheck = math.max(_answeredAuthorityCheck, check);
    final known = state.session;
    final listed = value != null && value.isLive ? value : null;

    for (final id in _storedFinalizationIds.toList()) {
      if (id != listed?.id) _forgetStoredFinalization(id);
    }

    // Finalized here and not known to be closed: the backend still holds it.
    // Known to be closed, an answer that lists it is only an old one.
    if (listed != null &&
        _finalizedRemoteSessionIds.contains(listed.id) &&
        !_closedRemoteSessionIds.contains(listed.id)) {
      _resumePendingClose(listed);
      _isVerified = true;
      _emitNoLiveSession(emit);
      return null;
    }

    final pending = _pendingClose;
    if (pending != null && pending.remoteSessionId != listed?.id) {
      logDebug(
        'remote session close confirmed by a read ${pending.remoteSessionId}',
      );
      _settlePendingClose(pending);
    }

    final live = listed != null && !_closedRemoteSessionIds.contains(listed.id)
        ? listed
        : null;
    if (listed != null && live == null) {
      // An answer that predates a close this console already knows about.
      logDebug('closed remote session ignored in a read ${listed.id}');
    }
    if (known != null && known.id != live?.id) {
      _closedRemoteSessionIds.add(known.id);
    }
    _isVerified = true;
    if (live == null) {
      _emitNoLiveSession(emit, failure: failureIfNone);
      return null;
    }
    _finishedNotice = null;
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
        if (failure is AuthFailure) _emitNoLiveSession(emit, failure: failure);
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
        _emitNoLiveSession(
          emit,
          failure: failure is AuthFailure ? failure : conflict,
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

  /// Emits [session] with what this BLoC knows about it — activation in
  /// flight, confirmed or not — unless the backend already said it is over or
  /// the technician finalized it here.
  void _emitSession(
    Emitter<RemoteSessionState> emit,
    RemoteSession session, {
    Failure? failure,
    bool canRetryActivation = false,
  }) {
    if (_closedRemoteSessionIds.contains(session.id) ||
        _finalizedRemoteSessionIds.contains(session.id)) {
      // A late answer about an assistance that is over. Nothing brings it
      // back; whatever is on screen now already says so.
      logDebug('ended remote session not restored ${session.id}');
      if (state.session?.id == session.id) _emitNoLiveSession(emit);
      return;
    }
    emit(
      RemoteSessionState.fromSession(
        session,
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
    if (_pendingClose != null || previous is RemoteSessionIdle) {
      _emitNoLiveSession(emit, failure: reported);
      return;
    }
    emit(RemoteSessionFailure(reported));
  }

  /// No assistance on screen: [RemoteSessionEnding] while a close this console
  /// asked for is not confirmed, [RemoteSessionIdle] otherwise.
  ///
  /// While ending, only an [AuthFailure] is carried — the console must hear
  /// it; the state itself says what happened to the close.
  void _emitNoLiveSession(
    Emitter<RemoteSessionState> emit, {
    Failure? failure,
  }) {
    final pending = _pendingClose;
    if (pending != null) {
      emit(
        RemoteSessionEnding(
          remoteSessionId: pending.remoteSessionId,
          deviceLabel: pending.deviceLabel,
          devicePublicId: pending.devicePublicId,
          isConfirming: pending.isConfirming,
          failure: failure is AuthFailure ? failure : null,
        ),
      );
      return;
    }
    emit(
      RemoteSessionIdle(
        failure: failure,
        startingSupportRequestId: _startingSupportRequestId,
        notice: failure == null ? _finishedNotice : null,
      ),
    );
  }

  /// Whether a new attempt could plausibly succeed.
  ///
  /// Only transport level problems qualify. A refusal is a backend decision
  /// and a rejected token needs a new login, so neither offers a retry.
  static bool _isRetryable(Failure failure) =>
      failure is NetworkFailure || failure is ServerFailure;
}

/// The close of one session finalized here, until the backend confirms it.
class _PendingClose {
  _PendingClose({
    required this.remoteSessionId,
    this.deviceLabel,
    this.devicePublicId,
  });

  factory _PendingClose.of(RemoteSession session) => _PendingClose(
    remoteSessionId: session.id,
    deviceLabel: session.deviceLabel,
    devicePublicId: session.devicePublicId,
  );

  final String remoteSessionId;
  final String? deviceLabel;
  final String? devicePublicId;

  /// Between FINALIZAR and its first request: the revocation is running.
  bool isPreparing = false;
  bool isInFlight = false;
  Timer? retryTimer;
  int retriesUsed = 0;
  int attempts = 0;

  bool get isConfirming => isPreparing || isInFlight || retryTimer != null;

  void cancelRetry() {
    retryTimer?.cancel();
    retryTimer = null;
  }
}
