import 'package:equatable/equatable.dart';

/// The `remote-session:active` notification of the `/technicians` namespace:
/// `{ "remoteSessionId": "..." }`.
///
/// It says one thing only: the backend moved that session to `ACTIVE` and
/// stamped its `connectedAt`.
///
/// It is **a trigger, never the state**. The console does not promote its own
/// session to `ACTIVE` because this arrived — not even when the ids match. It
/// re-reads `GET /remote-sessions/current` and shows what REST answers, which
/// is the only place `connectedAt` can come from.
///
/// It is also not authorization, and carries no ownership: a notice naming a
/// session this console does not hold changes nothing at all.
class RemoteSessionActiveNotice extends Equatable {
  const RemoteSessionActiveNotice({required this.remoteSessionId});

  final String remoteSessionId;

  @override
  List<Object?> get props => [remoteSessionId];

  @override
  String toString() =>
      'RemoteSessionActiveNotice(remoteSessionId: $remoteSessionId)';
}
