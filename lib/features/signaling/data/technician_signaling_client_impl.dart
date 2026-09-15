import 'dart:async';

import '../../../core/logging/debug_log.dart';
import '../../technician_realtime/domain/entities/signaling_error_code.dart';
import '../domain/client/technician_signaling_client.dart';
import '../domain/entities/remote_signaling_message.dart';
import '../domain/entities/signaling_limits.dart';
import '../domain/entities/signaling_relay_result.dart';
import '../domain/entities/webrtc_ice_candidate.dart';
import '../domain/entities/webrtc_session_description.dart';
import 'models/remote_signaling_message_dto.dart';
import 'models/signaling_relay_ack_dto.dart';
import 'signaling_contract.dart';
import 'signaling_transport.dart';

/// `webrtc:*` relay over the single `/technicians` socket.
///
/// What it owns:
///
/// * the three outgoing events and their exact payloads;
/// * the local preconditions of a relay — room membership, the right session,
///   the documented size limits — so that `INVALID_PAYLOAD` and `NOT_JOINED`
///   are never produced by this client on purpose;
/// * the acknowledgement, including its timeout;
/// * parsing and isolating the incoming messages.
///
/// What it deliberately does not own: the connection (the realtime client
/// does), the decision to join (the join BLoC does), what a refusal means for
/// the console (the coordinator does), and anything WebRTC — no
/// `RTCPeerConnection`, no SDP applied, no candidate added, and no opinion on
/// which side creates the offer.
///
/// Security: SDP and ICE candidate contents never reach the log. Only the
/// event, the session id and, at most, a length are written.
class TechnicianSignalingClientImpl implements TechnicianSignalingClient {
  TechnicianSignalingClientImpl({
    required SignalingTransport transport,
    Duration ackTimeout = defaultAckTimeout,
  }) : _transport = transport,
       _ackTimeout = ackTimeout {
    _wireSubscription = _transport.signalingEvents.listen(_onWireEvent);
  }

  /// The backend always answers its acknowledgements, so this only guards
  /// against an emission that never reaches it. Same value as the join ACK
  /// timeout: it is the same socket and the same kind of round trip.
  static const Duration defaultAckTimeout = Duration(seconds: 10);

  final SignalingTransport _transport;
  final Duration _ackTimeout;

  late final StreamSubscription<SignalingWireEvent> _wireSubscription;

  final StreamController<RemoteSignalingMessage> _incomingController =
      StreamController<RemoteSignalingMessage>.broadcast();
  final StreamController<SignalingRelayRefused> _refusalController =
      StreamController<SignalingRelayRefused>.broadcast();

  @override
  Stream<RemoteSignalingMessage> get incoming => _incomingController.stream;

  @override
  Stream<SignalingRelayRefused> get relayRefusals => _refusalController.stream;

  @override
  String? get joinedRemoteSessionId => _transport.joinedRemoteSessionId;

  @override
  Future<SignalingRelayResult> sendOffer(WebRtcOffer offer) => _relay(
    event: SignalingContract.offerEvent,
    label: 'offer',
    remoteSessionId: offer.remoteSessionId,
    violation: offer.validate(),
    payload: () => SignalingContract.sessionDescriptionPayload(
      remoteSessionId: offer.remoteSessionId,
      sdp: offer.sdp,
    ),
  );

  @override
  Future<SignalingRelayResult> sendAnswer(WebRtcAnswer answer) => _relay(
    event: SignalingContract.answerEvent,
    label: 'answer',
    remoteSessionId: answer.remoteSessionId,
    violation: answer.validate(),
    payload: () => SignalingContract.sessionDescriptionPayload(
      remoteSessionId: answer.remoteSessionId,
      sdp: answer.sdp,
    ),
  );

  @override
  Future<SignalingRelayResult> sendIceCandidate(WebRtcIceCandidate candidate) =>
      _relay(
        event: SignalingContract.iceCandidateEvent,
        label: 'ICE candidate',
        remoteSessionId: candidate.remoteSessionId,
        violation: candidate.validate(),
        payload: () => SignalingContract.iceCandidatePayload(
          remoteSessionId: candidate.remoteSessionId,
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );

  @override
  Future<void> dispose() async {
    await _wireSubscription.cancel();
    await _incomingController.close();
    await _refusalController.close();
  }

  /// One relay attempt: check, emit, wait for the acknowledgement.
  ///
  /// [payload] is a callback so the map is only built once every local
  /// precondition has passed — a payload that is never sent is never even
  /// assembled.
  Future<SignalingRelayResult> _relay({
    required String event,
    required String label,
    required String remoteSessionId,
    required SignalingPayloadViolation? violation,
    required Map<String, dynamic> Function() payload,
  }) async {
    // `remote-session:join` is mandatory before any `webrtc:*` event, and the
    // backend authorizes every single message against the session stored on
    // the socket. Sending without it could only earn a `NOT_JOINED`.
    final joined = _transport.joinedRemoteSessionId;
    if (joined == null) {
      return const SignalingRelayNotSent(SignalingNotSentReason.notJoined);
    }
    if (joined != remoteSessionId) {
      return const SignalingRelayNotSent(
        SignalingNotSentReason.sessionMismatch,
      );
    }
    if (violation != null) {
      return SignalingRelayNotSent(
        SignalingNotSentReason.invalidPayload,
        violation: violation,
      );
    }

    final completer = Completer<SignalingRelayResult>();
    final timeout = Timer(_ackTimeout, () {
      if (completer.isCompleted) return;
      completer.complete(
        const SignalingRelayUnanswered(SignalingRelayUnansweredReason.timeout),
      );
    });

    final sent = _transport.emitSignaling(event, payload(), (ack) {
      timeout.cancel();
      // The attempt already timed out: an acknowledgement that arrives after
      // its operation was given up on must not change anything.
      if (completer.isCompleted) return;
      final result = SignalingRelayAckDto.fromAck(
        ack,
        remoteSessionId: remoteSessionId,
      );
      if (result is SignalingRelayRefused) _onRefused(result);
      completer.complete(result);
    });

    if (!sent) {
      // The connection died between the membership check and the emission.
      timeout.cancel();
      return const SignalingRelayNotSent(SignalingNotSentReason.notConnected);
    }

    logDebug('$label sent $remoteSessionId');
    return completer.future;
  }

  /// The backend refused a relay.
  ///
  /// The only thing decided here is the one fact this object owns: whether the
  /// socket is still in the room. `NOT_JOINED` means it is not, whatever the
  /// join ACK said earlier, so the stored membership is dropped and every
  /// further relay is refused locally until a new join succeeds.
  ///
  /// Nothing else is interpreted and nothing is resent: what a refusal means
  /// for the console — rejoin, reconcile over REST, or neither — is a decision
  /// of the coordinator, which listens to the refusals.
  void _onRefused(SignalingRelayRefused refused) {
    logDebug(
      'relay refused: ${refused.error.wireValue} ${refused.remoteSessionId}',
    );
    if (refused.error == SignalingErrorCode.notJoined) {
      _transport.forgetJoinedRemoteSession();
    }
    if (!_refusalController.isClosed) _refusalController.add(refused);
  }

  /// A `webrtc:*` event arrived on the socket.
  void _onWireEvent(SignalingWireEvent wire) {
    final message = RemoteSignalingMessageDto.fromEvent(wire.event, wire.data);
    // Malformed: ignored, never a crash and never a half built message.
    if (message == null) return;

    // Session isolation. A message for any other session — or any message at
    // all while no session is joined, which is what a late event after a close
    // looks like — is dropped, and its id is never adopted.
    final joined = _transport.joinedRemoteSessionId;
    if (joined == null || joined != message.remoteSessionId) return;

    logDebug('${_labelOf(wire.event)} received ${message.remoteSessionId}');
    if (!_incomingController.isClosed) _incomingController.add(message);
  }

  static String _labelOf(String event) => switch (event) {
    SignalingContract.offerEvent => 'offer',
    SignalingContract.answerEvent => 'answer',
    SignalingContract.iceCandidateEvent => 'ICE candidate',
    _ => 'signaling',
  };
}
