import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import '../entities/normalized_remote_point.dart';
import '../entities/remote_control_command.dart';

/// Whether the tablet of the current negotiation runs touch sessions.
///
/// ```text
/// unknown       nothing said yet: a hold goes out as a touch_hold
/// supported     a touch_hold was answered ok: touch_* from then on
/// unsupported   a touch_hold was answered unsupported_command: the legacy
///               long_press from then on, without paying another round trip
/// ```
///
/// Learned per negotiation and forgotten with it: a new peer connection, a new
/// generation, another `RemoteSession` or a channel that stopped being open may
/// all mean another build of the tablet's application. Only those two answers
/// teach anything: a timeout, `accessibility_unavailable`, `session_not_active`,
/// `gesture_rejected`, `touch_ended` or a closed channel say nothing about it.
enum RemoteTouchSupport { unknown, supported, unsupported }

/// Where a touch session is.
///
/// ```text
/// starting     touch_hold sent, not answered yet; moves and keepalives go out
/// active       touch_hold answered ok; moves and keepalives go out
/// releasing    touch_release sent; nothing else goes out, the answer is awaited
/// cancelling   touch_cancel sent; nothing else goes out, the answer is awaited
/// dead         over, whichever way; nothing goes out and no timer runs
/// ```
enum RemoteTouchStage { starting, active, releasing, cancelling, dead }

/// What became of the `touch_hold`.
enum RemoteTouchHoldAnswer { pending, confirmed, refused }

/// Which message of a touch an acknowledgement names.
enum RemoteTouchMessage { hold, move, release, cancel }

/// The timers of a touch session. Each one only reports: see [RemoteTouchSession].
enum RemoteTouchTimer {
  /// [RemoteTouchSession.keepaliveInterval] passed without anything sent.
  keepalive,

  /// The [RemoteTouchSession.minMoveInterval] after the last move is over.
  throttle,

  /// [RemoteTouchSession.maxLifetime] passed since the hold went out.
  lifetime,

  /// The answer to the release or the cancel did not come in time.
  deadline,
}

/// One remote finger, from the `touch_hold` that puts it down to the answer that
/// says it is gone: one interaction of the technician, and the one thing pending
/// while it lasts.
///
/// Not a `PendingRemoteCommand`: a touch is not one command waiting for one
/// answer. It is a hold that may or may not be answered before the pointer moves,
/// moves that are never answered when they are taken, keepalives, and a release
/// or a cancel whose answers can arrive right after the hold's. What is kept is
/// what it takes to number the next message, to recognise an answer about this
/// touch, and to decide when the next move goes out: positions, times and ids.
/// No frame, nothing of what is on the tablet's screen, and no command after it
/// was handed over.
///
/// It decides *what* goes out and *when*; whoever owns it sends. Its timers only
/// report, through `onTimer`, so that whatever they cause happens in its own
/// event, like the deadlines of `PendingRemoteCommands`.
///
/// ```text
/// moves        at most one per minMoveInterval, and only once the pointer is
///              minMoveDistance away from the last position sent: the latest
///              position wins, nothing piles up
/// keepalive    the last position again when keepaliveInterval passed without
///              anything sent, from the moment the hold went out and whether or
///              not it was answered: the tablet cancels a touch after 1 s of
///              silence
/// lifetime     maxLifetime after the hold, the touch is cancelled: the tablet
///              ends it at 30 s anyway, and a finger left down is worse than a
///              drag cut short
/// seq          1, 2, 3... for every move, keepalive, release and cancel, never
///              reused and never lower
/// ```
class RemoteTouchSession {
  RemoteTouchSession({
    required this.touchId,
    required this.holdId,
    required this.pointer,
    required this.generation,
    required this.remoteSessionId,
    required this.channel,
    required this.initialPoint,
    required this.support,
    required Duration answerDeadline,
    required void Function(RemoteTouchTimer timer) onTimer,
  }) : _answerDeadline = answerDeadline,
       _onTimer = onTimer,
       _lastObserved = initialPoint,
       _lastSent = initialPoint;

  /// What the tablet needs at least once every second to keep the finger down.
  static const Duration keepaliveInterval = Duration(milliseconds: 250);

  /// About 30 moves a second at the most.
  static const Duration minMoveInterval = Duration(milliseconds: 33);

  /// How far, in normalized units, the pointer has to be from the last position
  /// sent for a move to be worth sending. A keepalive does not ask for it.
  static const double minMoveDistance = 0.002;

  /// Never longer than the tablet's own limit.
  static const Duration maxLifetime = Duration(seconds: 30);

  /// More than [maxLifetime] at 30 moves a second. Beyond it the oldest ids are
  /// forgotten: an answer that old would be about a touch long over.
  static const int maxTrackedMoveIds = 1024;

  /// Names the finger on the wire, `t-N`. Shared by every message about it.
  final String touchId;

  /// The id of its `touch_hold`, `hold-N`.
  final String holdId;

  /// The pointer of the console the touch follows. Whatever another pointer
  /// does is none of its business.
  final int pointer;

  /// The negotiation it belongs to, and the channel it travels on.
  final int generation;
  final String remoteSessionId;
  final Object channel;

  /// Where the hold went down.
  final NormalizedRemotePoint initialPoint;

  /// What was known about the tablet when the hold went out: `unknown` or
  /// `supported`, never `unsupported`.
  final RemoteTouchSupport support;

  final Duration _answerDeadline;
  final void Function(RemoteTouchTimer timer) _onTimer;

  /// Only measures, for the log. Nothing is decided on it: the timers decide.
  final Stopwatch _clock = Stopwatch()..start();

  RemoteTouchStage _stage = RemoteTouchStage.starting;
  RemoteTouchHoldAnswer _holdAnswer = RemoteTouchHoldAnswer.pending;
  int _lastSeq = 0;
  NormalizedRemotePoint _lastObserved;
  NormalizedRemotePoint _lastSent;
  Duration _lastSentAt = Duration.zero;
  bool _hasMoved = false;

  /// The moves sent for this touch, so that a refusal can be recognised. Ids
  /// only, never the commands.
  final LinkedHashSet<String> _moveIds = LinkedHashSet<String>();
  String? _releaseId;
  String? _cancelId;

  Timer? _keepalive;
  Timer? _throttle;
  Timer? _lifetime;
  Timer? _deadline;

  RemoteTouchStage get stage => _stage;
  RemoteTouchHoldAnswer get holdAnswer => _holdAnswer;

  /// The last `seq` used: 0 while only the hold went out.
  int get lastSeq => _lastSeq;

  /// The last position the pointer was seen at, clamped to the picture.
  NormalizedRemotePoint get lastObserved => _lastObserved;

  /// The last position sent, by the hold, a move or a keepalive.
  NormalizedRemotePoint get lastSent => _lastSent;

  /// When the last message went out, from the hold.
  Duration get lastSentAt => _lastSentAt;

  /// Since the hold went out.
  Duration get elapsed => _clock.elapsed;

  /// Whether a move that was more than a keepalive ever went out.
  bool get hasMoved => _hasMoved;

  String? get releaseId => _releaseId;
  String? get cancelId => _cancelId;

  /// How many move ids are remembered right now.
  int get trackedMoveIds => _moveIds.length;

  /// Whether the pointer is still being followed: moves and keepalives go out.
  bool get isStreaming =>
      _stage == RemoteTouchStage.starting || _stage == RemoteTouchStage.active;

  bool get isDead => _stage == RemoteTouchStage.dead;

  /// Whether a move should go out now: the pointer is far enough from the last
  /// position sent, and the last move is far enough in the past.
  bool get isMoveDue =>
      isStreaming &&
      _throttle == null &&
      _distance(_lastObserved, _lastSent) >= minMoveDistance;

  /// The hold was handed to the channel: the keepalive starts now, without
  /// waiting for its answer, and so does the lifetime.
  void start() {
    if (!isStreaming) return;
    _lastSentAt = _clock.elapsed;
    _restartKeepalive();
    _lifetime = Timer(maxLifetime, () {
      _lifetime = null;
      _onTimer(RemoteTouchTimer.lifetime);
    });
  }

  /// The pointer is at [point] now. Returns whether a move is due.
  bool observe(NormalizedRemotePoint point) {
    if (!isStreaming) return false;
    _lastObserved = point;
    return isMoveDue;
  }

  /// The next move, to the last position observed, with the next `seq`.
  ///
  /// [isKeepalive] says it is only there to keep the finger down; a keepalive
  /// still consumes a `seq`, and still counts as a message sent.
  RemoteTouchMoveCommand move(String id, {required bool isKeepalive}) {
    assert(isStreaming);
    final command = RemoteTouchMoveCommand(
      id: id,
      touch: touchId,
      seq: ++_lastSeq,
      point: _lastObserved,
    );
    if (!isKeepalive) _hasMoved = true;
    _remember(id);
    _lastSent = _lastObserved;
    _lastSentAt = _clock.elapsed;
    _restartKeepalive();
    _throttle?.cancel();
    _throttle = Timer(minMoveInterval, () {
      _throttle = null;
      _onTimer(RemoteTouchTimer.throttle);
    });
    return command;
  }

  /// The pointer went up at [point]: the release, with the next `seq`. Nothing
  /// follows it but its answer.
  RemoteTouchReleaseCommand release(String id, NormalizedRemotePoint point) {
    assert(isStreaming);
    _lastObserved = point;
    final command = RemoteTouchReleaseCommand(
      id: id,
      touch: touchId,
      seq: ++_lastSeq,
      point: point,
    );
    _releaseId = id;
    _lastSent = point;
    _lastSentAt = _clock.elapsed;
    _awaitAnswer(RemoteTouchStage.releasing);
    return command;
  }

  /// The cancel, with the next `seq`. Nothing follows it but its answer.
  RemoteTouchCancelCommand cancel(String id) {
    assert(isStreaming);
    final command = RemoteTouchCancelCommand(
      id: id,
      touch: touchId,
      seq: ++_lastSeq,
    );
    _cancelId = id;
    _lastSentAt = _clock.elapsed;
    _awaitAnswer(RemoteTouchStage.cancelling);
    return command;
  }

  /// Which of this touch's messages [commandId] is, if any.
  RemoteTouchMessage? messageOf(String commandId) {
    if (isDead) return null;
    if (commandId == holdId) return RemoteTouchMessage.hold;
    if (commandId == _releaseId) return RemoteTouchMessage.release;
    if (commandId == _cancelId) return RemoteTouchMessage.cancel;
    if (_moveIds.contains(commandId)) return RemoteTouchMessage.move;
    return null;
  }

  /// The hold was answered `ok`.
  void confirmHold() {
    _holdAnswer = RemoteTouchHoldAnswer.confirmed;
    if (_stage == RemoteTouchStage.starting) _stage = RemoteTouchStage.active;
  }

  /// The hold was answered with an error.
  void refuseHold() => _holdAnswer = RemoteTouchHoldAnswer.refused;

  /// Over: every timer stops and every id is forgotten. Safe to call twice.
  void end() {
    _stage = RemoteTouchStage.dead;
    _stopStreaming();
    _lifetime?.cancel();
    _lifetime = null;
    _deadline?.cancel();
    _deadline = null;
    _moveIds.clear();
    _clock.stop();
  }

  void _awaitAnswer(RemoteTouchStage stage) {
    _stage = stage;
    _stopStreaming();
    _lifetime?.cancel();
    _lifetime = null;
    _deadline?.cancel();
    _deadline = Timer(_answerDeadline, () {
      _deadline = null;
      _onTimer(RemoteTouchTimer.deadline);
    });
  }

  void _stopStreaming() {
    _keepalive?.cancel();
    _keepalive = null;
    _throttle?.cancel();
    _throttle = null;
  }

  void _restartKeepalive() {
    _keepalive?.cancel();
    _keepalive = Timer(keepaliveInterval, () {
      _keepalive = null;
      _onTimer(RemoteTouchTimer.keepalive);
    });
  }

  void _remember(String id) {
    _moveIds.add(id);
    if (_moveIds.length > maxTrackedMoveIds) _moveIds.remove(_moveIds.first);
  }

  static double _distance(NormalizedRemotePoint a, NormalizedRemotePoint b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  @override
  String toString() => 'RemoteTouchSession($touchId, ${_stage.name})';
}
