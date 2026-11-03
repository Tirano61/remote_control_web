import 'dart:async';

/// Keeps new commands away from the tablet while a global action is under way.
///
/// Android acknowledges a global action as soon as it accepts it, with the
/// transition still animating, so a tap right after the answer to a Home could
/// land on the previous screen or on the transition itself.
///
/// ```text
/// accepted    ends when it was answered AND the settle time has passed,
///             whichever comes last: an answer at 80 ms waits until 350 ms, an
///             answer at 500 ms ends it there and then
/// refused     ends at once: nothing is animating
/// ```
///
/// A deadline only reports here too: the caller decides when to give it back, so
/// that a timer never changes anything outside its own event.
class RemoteNavigationGuard {
  RemoteNavigationGuard({required Duration settleDuration})
    : _settleDuration = settleDuration;

  final Duration _settleDuration;

  /// The command being waited for. `null` when nothing is held back.
  String? _commandId;
  Timer? _settleTimer;
  bool _isAccepted = false;
  bool _hasElapsed = false;

  bool get isActive => _commandId != null;

  /// [commandId] was just sent. It replaces anything before it, although the
  /// guard itself is what keeps a second one from being sent.
  void begin(
    String commandId, {
    required void Function(String commandId) onElapsed,
  }) {
    clear();
    _commandId = commandId;
    _settleTimer = Timer(_settleDuration, () => onElapsed(commandId));
  }

  /// The settle time of [commandId] has passed.
  void elapse(String commandId) {
    if (commandId != _commandId) return;
    _hasElapsed = true;
    if (_isAccepted) clear();
  }

  /// Android accepted [commandId]. Any other command is none of its business.
  void accept(String commandId) {
    if (commandId != _commandId) return;
    _isAccepted = true;
    if (_hasElapsed) clear();
  }

  /// [commandId] ended without having been accepted, so nothing is animating.
  void release(String commandId) {
    if (commandId == _commandId) clear();
  }

  void clear() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _commandId = null;
    _isAccepted = false;
    _hasElapsed = false;
  }
}
