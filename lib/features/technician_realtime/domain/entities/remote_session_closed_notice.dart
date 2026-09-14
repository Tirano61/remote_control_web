import 'package:equatable/equatable.dart';

/// The `remote-session:closed` notification of the `/technicians` namespace.
///
/// It is a domain notification, not signaling: the backend addresses it to the
/// private room the socket joined at handshake, so it arrives without having
/// sent `remote-session:join`.
///
/// It is a trigger, never the state. The console answers it with
/// `GET /remote-sessions/current` — delivery is best effort, the payload
/// carries no session object, and REST is committed before the event is
/// emitted, so REST can only be ahead of it.
class RemoteSessionClosedNotice extends Equatable {
  const RemoteSessionClosedNotice({required this.remoteSessionId, this.endedBy});

  /// Which session the backend is talking about.
  ///
  /// It is never adopted as the current session id: an id that does not match
  /// what the console knows still only triggers a REST reconciliation.
  final String remoteSessionId;

  /// `RemoteSessionEndedBy` wire value, `DEVICE` for this event.
  ///
  /// Kept raw on purpose: this feature must not become a second source of
  /// truth for remote session state. It is useful for debug logging only.
  final String? endedBy;

  @override
  List<Object?> get props => [remoteSessionId, endedBy];

  @override
  String toString() =>
      'RemoteSessionClosedNotice(remoteSessionId: $remoteSessionId, '
      'endedBy: $endedBy)';
}
