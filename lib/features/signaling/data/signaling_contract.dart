/// Wire level constants of the `webrtc:*` relay.
///
/// Copied from the *Signaling* section of `docs/backend/REALTIME.md`; they are
/// the contract, so they live in exactly one place and are asserted by the
/// contract tests. The document is never edited to fit this client.
class SignalingContract {
  const SignalingContract._();

  /// Client to server and server to client: the events are the same in both
  /// directions, only `from` is added by the backend on the way out.
  static const String offerEvent = 'webrtc:offer';
  static const String answerEvent = 'webrtc:answer';
  static const String iceCandidateEvent = 'webrtc:ice-candidate';

  /// The three relayed events, in the order they are documented.
  static const List<String> relayEvents = [
    offerEvent,
    answerEvent,
    iceCandidateEvent,
  ];

  /// Payload and ACK fields.
  static const String remoteSessionIdField = 'remoteSessionId';
  static const String sdpField = 'sdp';
  static const String candidateField = 'candidate';
  static const String sdpMidField = 'sdpMid';
  static const String sdpMLineIndexField = 'sdpMLineIndex';

  /// Added by the backend to every relayed payload: `DEVICE` or `TECHNICIAN`.
  /// It is never sent by this client — identity comes from the namespace.
  static const String fromField = 'from';

  /// `SignalingRelayAck` fields.
  static const String deliveredField = 'delivered';
  static const String errorField = 'error';

  /// Payload of `webrtc:offer` and `webrtc:answer`.
  ///
  /// Exactly two properties: *"Only the validated fields are forwarded"*, and
  /// any unknown property would make the whole message `INVALID_PAYLOAD`.
  static Map<String, dynamic> sessionDescriptionPayload({
    required String remoteSessionId,
    required String sdp,
  }) => {remoteSessionIdField: remoteSessionId, sdpField: sdp};

  /// Payload of `webrtc:ice-candidate`.
  ///
  /// `sdpMid` and `sdpMLineIndex` are always present, explicitly `null` when
  /// the candidate has none. The contract accepts both forms — *"may be
  /// omitted or sent explicitly as `null`"* — and the explicit one is chosen
  /// so the payload has a single shape whatever WebRTC produced.
  static Map<String, dynamic> iceCandidatePayload({
    required String remoteSessionId,
    required String candidate,
    required String? sdpMid,
    required int? sdpMLineIndex,
  }) => {
    remoteSessionIdField: remoteSessionId,
    candidateField: candidate,
    sdpMidField: sdpMid,
    sdpMLineIndexField: sdpMLineIndex,
  };
}
