part of 'signaling_join_bloc.dart';

sealed class SignalingJoinEvent extends Equatable {
  const SignalingJoinEvent();

  @override
  List<Object?> get props => const [];
}

/// Join [remoteSessionId] over the connection identified by [connectionId].
///
/// [connectionId] is what makes de-duplication possible: the same session over
/// the same connection is joined once, while the same session over a new
/// connection must be joined again.
final class SignalingJoinRequested extends SignalingJoinEvent {
  const SignalingJoinRequested({
    required this.remoteSessionId,
    required this.connectionId,
    this.force = false,
  });

  final String remoteSessionId;
  final int connectionId;

  /// Set by an explicit user retry, which is the only way to attempt a join
  /// that already failed on this same connection.
  final bool force;

  @override
  List<Object?> get props => [remoteSessionId, connectionId, force];
}

/// There is nothing to be joined any more: the connection dropped, the session
/// was closed, or the user signed out.
final class SignalingJoinReset extends SignalingJoinEvent {
  const SignalingJoinReset();
}

/// `remote-session:peer-joined` arrived. Internal: only the client raises it.
final class _SignalingPeerJoinedReported extends SignalingJoinEvent {
  const _SignalingPeerJoinedReported(this.remoteSessionId);

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];
}
