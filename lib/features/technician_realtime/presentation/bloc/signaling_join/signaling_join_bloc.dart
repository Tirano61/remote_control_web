import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/client/technician_realtime_client.dart';
import '../../../domain/entities/join_remote_session_result.dart';
import '../../../domain/entities/remote_session_peer_joined_notice.dart';
import '../../../domain/entities/signaling_error_code.dart';

part 'signaling_join_event.dart';
part 'signaling_join_state.dart';

/// Owns `remote-session:join` and the readiness it reports.
///
/// Joining is the precondition of every `webrtc:*` message, and being joined
/// is not the same thing as being able to negotiate: an offer relayed into a
/// room the tablet has not entered is dropped by the backend without a word.
/// The two facts are therefore tracked together but kept apart —
/// [SignalingJoined.peerJoined] is readiness, [SignalingJoined] itself is
/// membership.
///
/// Three rules shape this BLoC:
///
/// * a join is attempted once per (session, connection). Loading the current
///   session, refreshing the queue or receiving another "connected" event must
///   not send a second one;
/// * a join never survives its connection. Rooms die with the socket, so the
///   state is reset on every disconnection and the caller joins again —
///   readiness included, which is re-read from the new ACK and never carried
///   over;
/// * readiness only ever grows within a connection, and it is idempotent: the
///   ACK may already say `peerJoined: true`, `remote-session:peer-joined` may
///   arrive once or twice, and all of it means the same thing.
///
/// Being joined is the precondition the signaling client checks before
/// relaying anything, so this BLoC and that client are kept in step: a reset
/// here also tells the client to forget the room.
class SignalingJoinBloc extends Bloc<SignalingJoinEvent, SignalingJoinState> {
  SignalingJoinBloc({required TechnicianRealtimeClient client})
    : _client = client,
      super(const SignalingIdle()) {
    on<SignalingJoinRequested>(_onJoinRequested);
    on<SignalingJoinReset>(_onReset);
    on<_SignalingPeerJoinedReported>(_onPeerJoinedReported);

    _peerJoinedSubscription = _client.peerJoined.listen(
      (notice) => add(_SignalingPeerJoinedReported(notice.remoteSessionId)),
    );
  }

  final TechnicianRealtimeClient _client;

  late final StreamSubscription<RemoteSessionPeerJoinedNotice>
  _peerJoinedSubscription;

  /// Attempt in flight, if any.
  _JoinAttempt? _pending;

  /// Last attempt that reached an outcome, successful or not.
  _JoinAttempt? _settled;

  /// Session a `remote-session:peer-joined` was received for.
  ///
  /// It exists for one race: the tablet may join between this socket's
  /// `remote-session:join` and its acknowledgement, in which case the ACK
  /// legitimately says `peerJoined: false` and the event arrives first.
  /// Without this, that readiness would be lost until the next reconnection.
  ///
  /// Dropped by every reset, so nothing is ever carried across a connection.
  String? _peerReadyRemoteSessionId;

  @override
  Future<void> close() async {
    await _peerJoinedSubscription.cancel();
    return super.close();
  }

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
      case JoinRemoteSessionAccepted(:final remoteSessionId, :final peerJoined):
        emit(
          SignalingJoined(
            remoteSessionId,
            // An event that overtook this acknowledgement counts: readiness
            // is one fact reported through two channels.
            peerJoined:
                peerJoined || _peerReadyRemoteSessionId == remoteSessionId,
          ),
        );
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

  /// The tablet entered the signaling room of a session.
  ///
  /// The event is never treated as authorization and its id is never adopted:
  /// readiness is only applied to the session this console already joined.
  void _onPeerJoinedReported(
    _SignalingPeerJoinedReported event,
    Emitter<SignalingJoinState> emit,
  ) {
    _peerReadyRemoteSessionId = event.remoteSessionId;

    final current = state;
    if (current is! SignalingJoined) return;
    if (current.remoteSessionId != event.remoteSessionId) return;
    // Idempotent: a second event, or one after an ACK that already said so,
    // changes nothing.
    if (current.peerJoined) return;

    emit(SignalingJoined(current.remoteSessionId, peerJoined: true));
  }

  void _onReset(SignalingJoinReset event, Emitter<SignalingJoinState> emit) {
    _pending = null;
    _settled = null;
    // Readiness belongs to the connection that observed it. A new socket is a
    // new room, and its ACK is the only thing that may say the tablet is in.
    _peerReadyRemoteSessionId = null;
    // The client stops accepting `webrtc:*` for that session at the same
    // moment the console stops considering itself joined: one fact, one
    // reset. Late signaling for the previous session is then discarded.
    _client.forgetJoinedRemoteSession();
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
