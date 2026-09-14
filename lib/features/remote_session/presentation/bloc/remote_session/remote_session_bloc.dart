import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/error/failure.dart';
import '../../../../../core/error/result.dart';
import '../../../domain/entities/remote_session.dart';
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

/// Owns the remote session of the signed-in technician.
///
/// REST is the source of truth. The BLoC never promotes a session to `CLOSED`
/// on its own and never invents `ACTIVE`: every transition it shows came from
/// `GET /remote-sessions/current`, `POST /remote-sessions` or
/// `POST /remote-sessions/:id/close`.
///
/// Socket.IO is deliberately absent from this class. Realtime only triggers a
/// [RemoteSessionRefreshRequested]; it never carries the state itself.
class RemoteSessionBloc extends Bloc<RemoteSessionEvent, RemoteSessionState> {
  RemoteSessionBloc({
    required LoadCurrentRemoteSession loadCurrentRemoteSession,
    required CreateRemoteSession createRemoteSession,
    required CloseRemoteSession closeRemoteSession,
  }) : _loadCurrentRemoteSession = loadCurrentRemoteSession,
       _createRemoteSession = createRemoteSession,
       _closeRemoteSession = closeRemoteSession,
       super(const RemoteSessionInitial()) {
    on<RemoteSessionStarted>(_onStarted);
    on<RemoteSessionRefreshRequested>(_onRefreshRequested);
    on<RemoteSessionCreateRequested>(_onCreateRequested);
    on<RemoteSessionCloseRequested>(_onCloseRequested);
    on<RemoteSessionNoticeDismissed>(_onNoticeDismissed);
    on<RemoteSessionCleared>(_onCleared);
  }

  final LoadCurrentRemoteSession _loadCurrentRemoteSession;
  final CreateRemoteSession _createRemoteSession;
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

  Future<void> _onCloseRequested(
    RemoteSessionCloseRequested event,
    Emitter<RemoteSessionState> emit,
  ) async {
    final current = state;
    if (current is! RemoteSessionLive) return;
    // One close at a time: the button is disabled too, this is the safety net.
    if (current.isClosing) return;

    final session = current.session;
    emit(RemoteSessionState.fromSession(session, isClosing: true));

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
      emit(
        RemoteSessionState.fromSession(
          current.session,
          isClosing: current.isClosing,
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
