part of 'remote_session_bloc.dart';

sealed class RemoteSessionState extends Equatable {
  const RemoteSessionState();

  /// Builds the state that matches a session returned by the backend.
  ///
  /// A `CLOSED` session — or a status this version does not recognise — is not
  /// live, so it produces [RemoteSessionIdle] instead of an assistance view.
  /// The console never invents a transition the backend did not make.
  static RemoteSessionState fromSession(
    RemoteSession session, {
    bool isClosing = false,
    Failure? failure,
  }) {
    if (session.isConnecting) {
      return RemoteSessionConnecting(
        session: session,
        isClosing: isClosing,
        failure: failure,
      );
    }
    if (session.isActive) {
      return RemoteSessionActive(
        session: session,
        isClosing: isClosing,
        failure: failure,
      );
    }
    return RemoteSessionIdle(failure: failure);
  }

  /// The live session, when there is one.
  RemoteSession? get session => null;

  /// The last problem the user still has to be told about.
  Failure? get failure => null;

  /// Watched by the console: an [AuthFailure] ends the session, a
  /// [ForbiddenFailure] or a [NetworkFailure] does not.
  Failure? get lastFailure => failure;

  /// Whether an assistance is currently open for this technician.
  bool get hasLiveSession => session?.isLive ?? false;

  /// Whether a REST call of this feature is in flight.
  bool get isBusy => false;

  @override
  List<Object?> get props => const [];
}

/// Nothing has been read yet.
final class RemoteSessionInitial extends RemoteSessionState {
  const RemoteSessionInitial();
}

/// The first `GET /remote-sessions/current` is in flight.
final class RemoteSessionLoading extends RemoteSessionState {
  const RemoteSessionLoading();

  @override
  bool get isBusy => true;
}

/// The technician has no live session.
///
/// This is the normal state of the console: the dashboard is shown as usual and
/// an accepted request may be started.
final class RemoteSessionIdle extends RemoteSessionState {
  const RemoteSessionIdle({this.failure, this.startingSupportRequestId});

  @override
  final Failure? failure;

  /// Id of the support request whose `POST /remote-sessions` is in flight.
  final String? startingSupportRequestId;

  bool get isStarting => startingSupportRequestId != null;

  bool isStartingFor(String supportRequestId) =>
      startingSupportRequestId == supportRequestId;

  @override
  bool get isBusy => isStarting;

  @override
  List<Object?> get props => [failure, startingSupportRequestId];
}

/// There is a live session: `CONNECTING` or `ACTIVE`.
sealed class RemoteSessionLive extends RemoteSessionState {
  const RemoteSessionLive({
    required this.session,
    this.isClosing = false,
    this.failure,
  });

  @override
  final RemoteSession session;

  /// `POST /remote-sessions/:id/close` is in flight.
  final bool isClosing;

  @override
  final Failure? failure;

  @override
  bool get isBusy => isClosing;

  @override
  List<Object?> get props => [session, isClosing, failure];
}

/// `CONNECTING` — the session exists and both ends may start connecting.
final class RemoteSessionConnecting extends RemoteSessionLive {
  const RemoteSessionConnecting({
    required super.session,
    super.isClosing,
    super.failure,
  });
}

/// `ACTIVE` — reserved by the backend; no code path sets it today.
///
/// It is rendered if it ever arrives, and never simulated locally.
final class RemoteSessionActive extends RemoteSessionLive {
  const RemoteSessionActive({
    required super.session,
    super.isClosing,
    super.failure,
  });
}

/// The state could not be read at all and nothing is known yet.
final class RemoteSessionFailure extends RemoteSessionState {
  const RemoteSessionFailure(this.failure);

  @override
  final Failure failure;

  @override
  List<Object?> get props => [failure];
}
