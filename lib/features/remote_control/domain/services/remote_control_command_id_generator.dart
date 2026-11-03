import '../entities/remote_control_command.dart';

/// Produces the id of each command. Injected, so a test can name them.
abstract interface class RemoteControlCommandIdGenerator {
  String next(RemoteCommandKind kind);
}

/// `tap-1`, `swipe-2`, `back-3`, `text-4`, `home-5`, ...
///
/// One counter for every kind, unique for as long as the page lives, which is
/// longer than any session: the counter does not restart with a new negotiation,
/// and an F5 destroys the peer connection that could have answered an older id.
/// The device treats the id as opaque, so nothing else is asked of it.
class SequentialRemoteControlCommandIdGenerator
    implements RemoteControlCommandIdGenerator {
  int _last = 0;

  @override
  String next(RemoteCommandKind kind) => '${kind.idPrefix}-${++_last}';
}
