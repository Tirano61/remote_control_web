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
    bool isActivating = false,
    bool canRetryActivation = false,
    Failure? failure,
  }) {
    if (session.isConnecting) {
      return RemoteSessionConnecting(
        session: session,
        isClosing: isClosing,
        isActivating: isActivating,
        canRetryActivation: canRetryActivation,
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

  /// Whether `POST /remote-sessions/:id/activate` is in flight.
  ///
  /// It is watched by the console, which must not ask for a second activation
  /// while one is still unanswered.
  bool get isActivating => false;

  /// Whether the last activation failed in a way a new attempt could fix.
  ///
  /// Only a transport level problem qualifies. A refused activation is a
  /// backend decision and is reconciled instead of retried.
  bool get canRetryActivation => false;

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
  bool get isBusy => isClosing || isActivating;

  @override
  List<Object?> get props => [
    session,
    isClosing,
    isActivating,
    canRetryActivation,
    failure,
  ];
}

/// `CONNECTING` — the session exists and both ends may start connecting.
///
/// This is also the only status that can be activated, which is why it is the
/// only one carrying the activation flags: an `ACTIVE` session is already
/// where `POST /remote-sessions/:id/activate` would put it.
final class RemoteSessionConnecting extends RemoteSessionLive {
  const RemoteSessionConnecting({
    required super.session,
    super.isClosing,
    this.isActivating = false,
    this.canRetryActivation = false,
    super.failure,
  });

  @override
  final bool isActivating;

  @override
  final bool canRetryActivation;
}

/// `ACTIVE` — the assistance is running: the technician reached the device.
///
/// Only the backend produces it, through `POST /remote-sessions/:id/activate`
/// and the `GET /remote-sessions/current` that follows. It is never simulated
/// locally, and `connectedAt` is never computed here.
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
