import 'dart:async';

import '../../core/error/failure.dart';
import '../../features/auth/presentation/bloc/user_session/user_session_bloc.dart';
import '../../features/remote_session/presentation/bloc/remote_session/remote_session_bloc.dart';
import '../../features/support/presentation/bloc/support_requests/support_requests_bloc.dart';
import '../../features/technician_realtime/domain/client/technician_realtime_client.dart';
import '../../features/technician_realtime/domain/entities/remote_session_closed_notice.dart';
import '../../features/technician_realtime/domain/entities/technician_realtime_status.dart';
import '../../features/technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import '../../features/technician_realtime/presentation/bloc/technician_realtime/technician_realtime_bloc.dart';

/// Shown on the login page after the `/technicians` handshake was rejected.
const String kRealtimeSessionRejectedNotice =
    'Tu sesión dejó de ser válida. Inicia sesión nuevamente.';

/// Wires the console features together without letting them know each other.
///
/// Every BLoC stays ignorant of the others — none of them imports another —
/// and the rules that only make sense at the level of the whole console live
/// here:
///
/// ```text
/// authenticated                      -> connect /technicians + GET current
/// signed out                         -> disconnect + forget the session
/// socket connected + live session    -> remote-session:join
/// socket lost                        -> the join is no longer valid
/// remote-session:closed              -> GET current (never the event as state)
/// live session disappeared           -> reload the support request queue
/// socket handshake rejected          -> the user session is over
/// ```
class TechnicianConsoleCoordinator {
  TechnicianConsoleCoordinator({
    required UserSessionBloc userSessionBloc,
    required RemoteSessionBloc remoteSessionBloc,
    required TechnicianRealtimeBloc technicianRealtimeBloc,
    required SignalingJoinBloc signalingJoinBloc,
    required SupportRequestsBloc supportRequestsBloc,
    required TechnicianRealtimeClient realtimeClient,
  }) : _userSessionBloc = userSessionBloc,
       _remoteSessionBloc = remoteSessionBloc,
       _technicianRealtimeBloc = technicianRealtimeBloc,
       _signalingJoinBloc = signalingJoinBloc,
       _supportRequestsBloc = supportRequestsBloc,
       _realtimeClient = realtimeClient;

  final UserSessionBloc _userSessionBloc;
  final RemoteSessionBloc _remoteSessionBloc;
  final TechnicianRealtimeBloc _technicianRealtimeBloc;
  final SignalingJoinBloc _signalingJoinBloc;
  final SupportRequestsBloc _supportRequestsBloc;
  final TechnicianRealtimeClient _realtimeClient;

  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// Whether the console currently believes an assistance is open.
  ///
  /// Only used to notice the transition "there was one, now there is none",
  /// which is when the support request queue is worth re-reading: its request
  /// has just become `COMPLETED`.
  bool _hadLiveSession = false;

  bool _isStarted = false;

  void start() {
    if (_isStarted) return;
    _isStarted = true;

    _subscriptions
      ..add(_userSessionBloc.stream.listen(_onUserSessionChanged))
      ..add(_technicianRealtimeBloc.stream.listen(_onRealtimeStatusChanged))
      ..add(_remoteSessionBloc.stream.listen(_onRemoteSessionChanged))
      ..add(_realtimeClient.remoteSessionClosed.listen(_onRemoteSessionClosed));

    // The console is opened by an already authenticated session, so the
    // current state has to be acted upon and not only its future changes.
    _onUserSessionChanged(_userSessionBloc.state);
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _isStarted = false;
  }

  void _onUserSessionChanged(UserSessionState state) {
    if (state is UserSessionAuthenticated) {
      // Connecting does not wait for a remote session: the namespace also
      // delivers notifications addressed to the technician.
      _technicianRealtimeBloc.add(const TechnicianRealtimeConnectRequested());
      // Whatever is in memory, the backend decides whether an assistance is
      // open. This is what makes an F5 recover on its own.
      _remoteSessionBloc.add(const RemoteSessionStarted());
      return;
    }

    _technicianRealtimeBloc.add(const TechnicianRealtimeDisconnectRequested());
    _signalingJoinBloc.add(const SignalingJoinReset());
    _remoteSessionBloc.add(const RemoteSessionCleared());
    _hadLiveSession = false;
  }

  void _onRealtimeStatusChanged(TechnicianRealtimeStatus status) {
    if (status is TechnicianRealtimeConnectionError &&
        status.isAuthenticationError) {
      // The handshake validates the very same User JWT the REST calls use, and
      // there is no refresh token: the session is over. A transport failure
      // never gets here.
      _userSessionBloc.add(
        const UserSessionInvalidated(notice: kRealtimeSessionRejectedNotice),
      );
      return;
    }

    if (status.isConnected) {
      _joinLiveSessionIfPossible();
      return;
    }

    // Rooms do not survive the connection, so nothing is joined any more.
    _signalingJoinBloc.add(const SignalingJoinReset());
  }

  void _onRemoteSessionChanged(RemoteSessionState state) {
    final failure = state.lastFailure;
    if (failure is AuthFailure) {
      _userSessionBloc.add(const UserSessionInvalidated());
    }

    if (state.hasLiveSession) {
      _hadLiveSession = true;
      _joinLiveSessionIfPossible();
      return;
    }

    _signalingJoinBloc.add(const SignalingJoinReset());

    if (_hadLiveSession && state is! RemoteSessionLoading) {
      // The assistance is over — closed from here or from the tablet. Its
      // support request is `COMPLETED` now, so the queue is stale.
      _hadLiveSession = false;
      _supportRequestsBloc.add(const SupportRequestsRefreshRequested());
    }
  }

  void _onRemoteSessionClosed(RemoteSessionClosedNotice notice) {
    // The event is a trigger, never the state: its id is not adopted and the
    // current session is not closed locally, not even when the ids match.
    // REST decides, here as everywhere else.
    _remoteSessionBloc.add(const RemoteSessionRefreshRequested());
  }

  void _joinLiveSessionIfPossible() {
    final status = _technicianRealtimeBloc.state;
    final connectionId = status.connectionId;
    if (!status.isConnected || connectionId == null) return;

    final session = _remoteSessionBloc.state.session;
    if (session == null || !session.isLive) return;

    // The BLoC drops this when it is the same session over the same
    // connection, so repeated triggers cannot produce a second join.
    _signalingJoinBloc.add(
      SignalingJoinRequested(
        remoteSessionId: session.id,
        connectionId: connectionId,
      ),
    );
  }
}
