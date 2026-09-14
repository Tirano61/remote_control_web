import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/error/failure.dart';
import '../../../../../core/error/result.dart';
import '../../../domain/entities/authenticated_user.dart';
import '../../../domain/entities/user_session.dart';
import '../../../domain/usecases/log_out.dart';
import '../../../domain/usecases/restore_session.dart';

part 'user_session_event.dart';
part 'user_session_state.dart';

/// Global authentication coordinator.
///
/// It decides what the application shows: startup check, login, connection
/// error or the authenticated console. It never touches the token storage
/// directly; the use cases and the repository do.
class UserSessionBloc extends Bloc<UserSessionEvent, UserSessionState> {
  UserSessionBloc({required RestoreSession restoreSession, required LogOut logOut})
    : _restoreSession = restoreSession,
      _logOut = logOut,
      super(const UserSessionCheckingStoredSession()) {
    on<UserSessionStarted>(_onStarted);
    on<UserSessionRetryRequested>(_onRetryRequested);
    on<UserSessionSignedIn>(_onSignedIn);
    on<UserSessionSignOutRequested>(_onSignOutRequested);
  }

  final RestoreSession _restoreSession;
  final LogOut _logOut;

  Future<void> _onStarted(
    UserSessionStarted event,
    Emitter<UserSessionState> emit,
  ) async {
    emit(const UserSessionCheckingStoredSession());
    await _restore(emit);
  }

  Future<void> _onRetryRequested(
    UserSessionRetryRequested event,
    Emitter<UserSessionState> emit,
  ) async {
    emit(const UserSessionAuthenticating());
    await _restore(emit);
  }

  void _onSignedIn(UserSessionSignedIn event, Emitter<UserSessionState> emit) {
    emit(UserSessionAuthenticated(event.session));
  }

  Future<void> _onSignOutRequested(
    UserSessionSignOutRequested event,
    Emitter<UserSessionState> emit,
  ) async {
    // There is no server side logout in the backend contract: the session ends
    // by dropping the User JWT locally.
    await _logOut();
    emit(const UserSessionUnauthenticated());
  }

  Future<void> _restore(Emitter<UserSessionState> emit) async {
    final result = await _restoreSession();

    switch (result) {
      case Success<SessionRestoreOutcome>(:final value):
        switch (value) {
          case NoStoredSession():
            emit(const UserSessionUnauthenticated());
          case RestoredSession(:final session):
            emit(UserSessionAuthenticated(session));
        }
      case Failed<SessionRestoreOutcome>(:final failure):
        emit(_stateForFailure(failure));
    }
  }

  UserSessionState _stateForFailure(Failure failure) => switch (failure) {
    // The backend is unreachable or broken: the stored token is still kept, so
    // the user only has to retry.
    NetworkFailure() => UserSessionConnectionError(message: failure.message),
    ServerFailure() => UserSessionConnectionError(message: failure.message),
    UnexpectedFailure() => UserSessionConnectionError(message: failure.message),
    // The token was rejected and has already been cleared by the repository.
    AuthFailure() => const UserSessionUnauthenticated(),
    // Valid account, but not allowed in this console.
    ForbiddenFailure() => UserSessionUnauthenticated(notice: failure.message),
    _ => UserSessionUnauthenticated(notice: failure.message),
  };
}
