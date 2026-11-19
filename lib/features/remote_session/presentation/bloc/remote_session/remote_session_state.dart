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
    bool isActivating = false,
    bool canRetryActivation = false,
    bool isVerified = true,
    int answeredAuthorityCheck = 0,
    int failedAuthorityCheck = 0,
    Failure? failure,
  }) {
    if (session.isConnecting) {
      return RemoteSessionConnecting(
        session: session,
        isActivating: isActivating,
        canRetryActivation: canRetryActivation,
        isVerified: isVerified,
        answeredAuthorityCheck: answeredAuthorityCheck,
        failedAuthorityCheck: failedAuthorityCheck,
        failure: failure,
      );
    }
    if (session.isActive) {
      return RemoteSessionActive(
        session: session,
        isVerified: isVerified,
        answeredAuthorityCheck: answeredAuthorityCheck,
        failedAuthorityCheck: failedAuthorityCheck,
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

  /// Whether the last read about the session on screen succeeded.
  ///
  /// `false` after a `GET /remote-sessions/current` that failed while a session
  /// was known: it stays on screen, but nothing says the backend still holds it,
  /// and the console does not let remote control run on it until a read
  /// succeeds. Dismissing the error banner does not change this.
  bool get isVerified => true;

  /// The highest [RemoteSessionAuthorityCheckRequested.checkId] a successful
  /// read has answered — one that started after that check was asked for.
  int get answeredAuthorityCheck => 0;

  /// The highest check a *failed* read started after it was asked for.
  ///
  /// A read that fails twice in a row produces the same state twice, which a
  /// listener never sees as a change. This is what makes every failure of a
  /// check observable — the answer, not the state, is what is being waited for.
  int get failedAuthorityCheck => 0;

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
  const RemoteSessionIdle({
    this.failure,
    this.startingSupportRequestId,
    this.notice,
  });

  @override
  final Failure? failure;

  /// Something the technician is told that is not a problem — today only
  /// "Asistencia finalizada.", once the backend confirmed the close FINALIZAR
  /// asked for. It stays until it is dismissed or a new assistance starts.
  final String? notice;

  /// Id of the support request whose `POST /remote-sessions` is in flight.
  final String? startingSupportRequestId;

  bool get isStarting => startingSupportRequestId != null;

  bool isStartingFor(String supportRequestId) =>
      startingSupportRequestId == supportRequestId;

  @override
  bool get isBusy => isStarting;

  @override
  List<Object?> get props => [failure, startingSupportRequestId, notice];
}

/// FINALIZAR was pressed: the assistance is over **for this console**, whatever
/// the backend answers, and the close is being — or could not be — confirmed.
///
/// It is not live on purpose. Everything that keys on a live session — the
/// signaling room, the peer connection, its data channel, remote control, the
/// WebRTC recovery — lets go of it the moment this state appears, before any
/// HTTP answer, and nothing brings the session back: not a failed close, not a
/// read that still lists it, not an F5.
///
/// The id is kept, and only the id is ever sent again: `POST
/// /remote-sessions/:id/close` for exactly this session, so no retry can close
/// a newer one by mistake.
final class RemoteSessionEnding extends RemoteSessionState {
  const RemoteSessionEnding({
    required this.remoteSessionId,
    this.deviceLabel,
    this.devicePublicId,
    this.isConfirming = true,
    this.failure,
  });

  /// The session this console finalized. Never adopted as a live one again.
  final String remoteSessionId;

  /// What the technician was assisting, for the message on screen. Absent when
  /// the session was finalized before a reload and only its id is known.
  final String? deviceLabel;
  final String? devicePublicId;

  /// A close is in flight, or one more is planned.
  ///
  /// `false` means the console stopped asking on its own: the backend could
  /// not be reached for long enough, or it refused. The technician may still
  /// ask again — see [canRetryClose].
  final bool isConfirming;

  /// Only ever an [AuthFailure]: the console has to hear it to sign out. The
  /// state itself says what happened to the close.
  @override
  final Failure? failure;

  bool get isUnconfirmed => !isConfirming;

  bool get canRetryClose => !isConfirming;

  @override
  bool get isBusy => isConfirming;

  @override
  List<Object?> get props => [
    remoteSessionId,
    deviceLabel,
    devicePublicId,
    isConfirming,
    failure,
  ];
}

/// There is a live session: `CONNECTING` or `ACTIVE`.
sealed class RemoteSessionLive extends RemoteSessionState {
  const RemoteSessionLive({
    required this.session,
    this.isVerified = true,
    this.answeredAuthorityCheck = 0,
    this.failedAuthorityCheck = 0,
    this.failure,
  });

  @override
  final RemoteSession session;

  @override
  final bool isVerified;

  @override
  final int answeredAuthorityCheck;

  @override
  final int failedAuthorityCheck;

  @override
  final Failure? failure;

  @override
  bool get isBusy => isActivating;

  @override
  List<Object?> get props => [
    session,
    isActivating,
    canRetryActivation,
    isVerified,
    answeredAuthorityCheck,
    failedAuthorityCheck,
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
    this.isActivating = false,
    this.canRetryActivation = false,
    super.isVerified,
    super.answeredAuthorityCheck,
    super.failedAuthorityCheck,
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
    super.isVerified,
    super.answeredAuthorityCheck,
    super.failedAuthorityCheck,
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
