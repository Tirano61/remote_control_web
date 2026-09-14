import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/client/technician_realtime_client.dart';
import '../../../domain/entities/join_remote_session_result.dart';
import '../../../domain/entities/signaling_error_code.dart';

part 'signaling_join_event.dart';
part 'signaling_join_state.dart';

/// Owns `remote-session:join` for the technician console.
///
/// Joining is the precondition of every future `webrtc:*` message, so the
/// console has to know whether it is inside the right room even though no
/// signaling is exchanged yet.
///
/// Two rules shape this BLoC:
///
/// * a join is attempted once per (session, connection). Loading the current
///   session, refreshing the queue or receiving another "connected" event must
///   not send a second one;
/// * a join never survives its connection. Rooms die with the socket, so the
///   state is reset on every disconnection and the caller joins again.
class SignalingJoinBloc extends Bloc<SignalingJoinEvent, SignalingJoinState> {
  SignalingJoinBloc({required TechnicianRealtimeClient client})
    : _client = client,
      super(const SignalingIdle()) {
    on<SignalingJoinRequested>(_onJoinRequested);
    on<SignalingJoinReset>(_onReset);
  }

  final TechnicianRealtimeClient _client;

  /// Attempt in flight, if any.
  _JoinAttempt? _pending;

  /// Last attempt that reached an outcome, successful or not.
  _JoinAttempt? _settled;

  Future<void> _onJoinRequested(
    SignalingJoinRequested event,
    Emitter<SignalingJoinState> emit,
  ) async {
    final attempt = _JoinAttempt(event.remoteSessionId, event.connectionId);

    // Already asking for exactly this: a repeated trigger is not a new join.
    if (_pending == attempt) return;
    // Already answered on this connection. Only an explicit retry insists.
    if (_settled == attempt && !event.force) return;

    _pending = attempt;
    emit(SignalingJoining(event.remoteSessionId));

    final result = await _client.joinRemoteSession(event.remoteSessionId);

    // The connection or the session moved on while the ACK was travelling;
    // whatever came back is about a join nobody is waiting for any more.
    if (_pending != attempt) return;
    _pending = null;
    _settled = attempt;

    switch (result) {
      case JoinRemoteSessionAccepted(:final remoteSessionId):
        emit(SignalingJoined(remoteSessionId));
      case JoinRemoteSessionRejected(:final error):
        emit(
          SignalingUnavailable(
            remoteSessionId: event.remoteSessionId,
            error: error,
          ),
        );
      case JoinRemoteSessionFailed():
        emit(SignalingUnavailable(remoteSessionId: event.remoteSessionId));
    }
  }

  void _onReset(SignalingJoinReset event, Emitter<SignalingJoinState> emit) {
    _pending = null;
    _settled = null;
    if (state is SignalingIdle) return;
    emit(const SignalingIdle());
  }
}

/// One join, identified by what makes it unique: the session and the
/// connection it was sent over.
class _JoinAttempt {
  const _JoinAttempt(this.remoteSessionId, this.connectionId);

  final String remoteSessionId;
  final int connectionId;

  @override
  bool operator ==(Object other) =>
      other is _JoinAttempt &&
      other.remoteSessionId == remoteSessionId &&
      other.connectionId == connectionId;

  @override
  int get hashCode => Object.hash(remoteSessionId, connectionId);
}
