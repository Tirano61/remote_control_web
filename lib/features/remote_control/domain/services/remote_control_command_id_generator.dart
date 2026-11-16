import '../entities/remote_control_command.dart';

/// Produces the id of each command. Injected, so a test can name them.
abstract interface class RemoteControlCommandIdGenerator {
  String next(RemoteCommandKind kind);

  /// The name of a new touch session, the `touch` of all its messages. Never the
  /// id of a message: those come from [next].
  String nextTouch();
}

/// `tap-1`, `swipe-2`, `back-3`, `text-4`, `home-5`, `t-6`, `hold-7`, `mv-8`, ...
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

  /// From the same counter, so that a touch is never named like another one.
  @override
  String nextTouch() => 't-${++_last}';
}
