part of 'signaling_join_bloc.dart';

/// Whether the console is inside the signaling room of its remote session.
///
/// It is tracked apart from the connection state on purpose: a socket can be
/// perfectly connected and still not be in the room, which is exactly the
/// situation right after a reconnection.
sealed class SignalingJoinState extends Equatable {
  const SignalingJoinState();

  /// The session this state talks about, when there is one.
  String? get remoteSessionId => null;

  bool get isJoined => false;

  @override
  List<Object?> get props => const [];
}

/// Nothing to join: no live session, or no connection.
final class SignalingIdle extends SignalingJoinState {
  const SignalingIdle();
}

/// `remote-session:join` was sent and its acknowledgement is pending.
final class SignalingJoining extends SignalingJoinState {
  const SignalingJoining(this.remoteSessionId);

  @override
  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}

/// The acknowledgement came back with `joined: true`.
///
/// It holds only for the connection that obtained it: rooms are connection
/// scoped, so a reconnection sends the console back to [SignalingIdle].
final class SignalingJoined extends SignalingJoinState {
  const SignalingJoined(this.remoteSessionId, {required this.peerJoined});

  @override
  final String remoteSessionId;

  /// Whether the tablet is inside the same signaling room.
  ///
  /// Two facts feed it, and both are connection scoped: the `peerJoined` flag
  /// of the join ACK, and `remote-session:peer-joined` arriving afterwards.
  /// It is readiness, never authorization — what this technician may do was
  /// settled by the join the backend accepted.
  ///
  /// Being joined is not enough to start negotiating: a `webrtc:offer` sent
  /// into a room the tablet has not entered is relayed to nobody and silently
  /// dropped.
  final bool peerJoined;

  @override
  bool get isJoined => true;

  /// Everything signaling can contribute to a WebRTC negotiation is true.
  bool get isPeerReady => peerJoined;

  @override
  List<Object?> get props => [remoteSessionId, peerJoined];
}

/// The join was refused, or no usable acknowledgement came back.
///
/// [error] is the stable signaling code when the backend answered one, and
/// `null` when the acknowledgement never arrived. No automatic retry is made:
/// a refused join repeated in a loop would hammer the backend for nothing.
final class SignalingUnavailable extends SignalingJoinState {
  const SignalingUnavailable({required this.remoteSessionId, this.error});

  @override
  final String remoteSessionId;

  final SignalingErrorCode? error;

  @override
  List<Object?> get props => [remoteSessionId, error];
}
