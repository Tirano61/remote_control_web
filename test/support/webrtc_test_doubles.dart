import 'dart:async';

import 'package:remote_control_web/features/signaling/domain/client/technician_signaling_client.dart';
import 'package:remote_control_web/features/signaling/domain/entities/remote_signaling_message.dart';
import 'package:remote_control_web/features/signaling/domain/entities/signaling_relay_result.dart';
import 'package:remote_control_web/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_web/features/signaling/domain/entities/webrtc_session_description.dart';
import 'package:remote_control_web/features/webrtc/domain/client/webrtc_peer_client.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_peer_event.dart';

/// Scripted [WebRtcPeerClient].
///
/// No browser and no `flutter_webrtc`: the test decides when a peer connection
/// is created, what the offer looks like, when a candidate is gathered and
/// which state the connection reports. That is what lets the whole negotiation
/// be exercised on the Dart VM.
class FakeWebRtcPeerClient implements WebRtcPeerClient {
  final List<FakeWebRtcPeerSession> sessions = [];

  /// Configurations `createSession` was called with, in order.
  final List<WebRtcIceConfiguration> configurations = [];

  /// Thrown by the next `createSession`, when set.
  Object? createError;

  /// Keeps a creation in flight so the test can interleave something with it.
  Future<void>? createGate;

  FakeWebRtcPeerSession get last => sessions.last;

  @override
  Future<WebRtcPeerSession> createSession({
    required String remoteSessionId,
    required WebRtcIceConfiguration configuration,
  }) async {
    configurations.add(configuration);
    final gate = createGate;
    if (gate != null) await gate;
    final error = createError;
    if (error != null) throw error;
    final session = FakeWebRtcPeerSession(remoteSessionId);
    sessions.add(session);
    return session;
  }
}

/// Scripted [WebRtcPeerSession]: one negotiation, fully driven by the test.
class FakeWebRtcPeerSession implements WebRtcPeerSession {
  FakeWebRtcPeerSession(this.remoteSessionId);

  @override
  final String remoteSessionId;

  final StreamController<WebRtcPeerEvent> _events =
      StreamController<WebRtcPeerEvent>.broadcast();

  /// SDP the created offer carries. Never a real one: nothing parses it here.
  String offerSdp = 'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n';

  int openControlChannelCount = 0;
  int createOfferCount = 0;
  int closeCount = 0;

  /// Every call this session received, in order.
  final List<String> calls = [];

  final List<WebRtcAnswer> appliedAnswers = [];
  final List<WebRtcIceCandidate> addedIceCandidates = [];

  Object? createOfferError;
  Object? applyAnswerError;
  Object? addIceCandidateError;

  bool get isClosed => closeCount > 0;

  @override
  Stream<WebRtcPeerEvent> get events => _events.stream;

  @override
  Future<void> openControlChannel() async {
    openControlChannelCount++;
    calls.add('channel');
  }

  @override
  Future<WebRtcOffer> createLocalOffer() async {
    createOfferCount++;
    calls.add('offer');
    final error = createOfferError;
    if (error != null) throw error;
    return WebRtcOffer(remoteSessionId: remoteSessionId, sdp: offerSdp);
  }

  @override
  Future<void> applyRemoteAnswer(WebRtcAnswer answer) async {
    calls.add('answer');
    final error = applyAnswerError;
    if (error != null) throw error;
    appliedAnswers.add(answer);
  }

  @override
  Future<void> addRemoteIceCandidate(WebRtcIceCandidate candidate) async {
    calls.add('candidate');
    final error = addIceCandidateError;
    if (error != null) throw error;
    addedIceCandidates.add(candidate);
  }

  @override
  Future<void> close() async {
    closeCount++;
    calls.add('close');
    if (!_events.isClosed) await _events.close();
  }

  // --- test helpers -------------------------------------------------------

  void emitLocalCandidate(String candidate, {String sdpMid = '0'}) => _emit(
    LocalIceCandidateGathered(
      WebRtcIceCandidate(
        remoteSessionId: remoteSessionId,
        candidate: candidate,
        sdpMid: sdpMid,
        sdpMLineIndex: 0,
      ),
    ),
  );

  void emitPeerState(WebRtcPeerConnectionState state) =>
      _emit(PeerConnectionStateChanged(state));

  void emitControlChannelState(WebRtcDataChannelState state) =>
      _emit(ControlChannelStateChanged(state));

  void emitControlChannelMessage(String text) =>
      _emit(ControlChannelMessageReceived(text));

  void _emit(WebRtcPeerEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }
}

/// Scripted [TechnicianSignalingClient].
///
/// It records what was relayed and in which order — which is the whole point
/// of the ICE queue tests — and lets the test decide what the backend
/// acknowledged.
class FakeTechnicianSignalingClient implements TechnicianSignalingClient {
  final StreamController<RemoteSignalingMessage> _incomingController =
      StreamController<RemoteSignalingMessage>.broadcast();
  final StreamController<SignalingRelayRefused> _refusalController =
      StreamController<SignalingRelayRefused>.broadcast();

  @override
  String? joinedRemoteSessionId;

  final List<WebRtcOffer> sentOffers = [];
  final List<WebRtcAnswer> sentAnswers = [];
  final List<WebRtcIceCandidate> sentIceCandidates = [];

  /// Every relay in one list, so ordering across kinds can be asserted.
  final List<String> relayLog = [];

  /// Answers of the next relays. Delivered unless a test says otherwise.
  SignalingRelayResult? offerResult;
  SignalingRelayResult? iceCandidateResult;

  /// Keeps the offer relay in flight so the test can interleave candidates.
  Future<void>? offerGate;

  @override
  Stream<RemoteSignalingMessage> get incoming => _incomingController.stream;

  @override
  Stream<SignalingRelayRefused> get relayRefusals => _refusalController.stream;

  @override
  Future<SignalingRelayResult> sendOffer(WebRtcOffer offer) async {
    sentOffers.add(offer);
    relayLog.add('offer');
    final gate = offerGate;
    if (gate != null) await gate;
    return offerResult ?? SignalingRelayDelivered(offer.remoteSessionId);
  }

  @override
  Future<SignalingRelayResult> sendAnswer(WebRtcAnswer answer) async {
    sentAnswers.add(answer);
    relayLog.add('answer');
    return SignalingRelayDelivered(answer.remoteSessionId);
  }

  @override
  Future<SignalingRelayResult> sendIceCandidate(
    WebRtcIceCandidate candidate,
  ) async {
    sentIceCandidates.add(candidate);
    relayLog.add('ice:${candidate.candidate}');
    return iceCandidateResult ??
        SignalingRelayDelivered(candidate.remoteSessionId);
  }

  @override
  Future<void> dispose() async {
    await _incomingController.close();
    await _refusalController.close();
  }

  // --- test helpers -------------------------------------------------------

  /// A `webrtc:*` message the backend relayed to this technician.
  void emitIncoming(RemoteSignalingMessage message) {
    if (_incomingController.isClosed) return;
    _incomingController.add(message);
  }

  void emitAnswer(String remoteSessionId, {String sdp = 'v=0 answer'}) =>
      emitIncoming(
        AnswerReceived(
          answer: WebRtcAnswer(remoteSessionId: remoteSessionId, sdp: sdp),
        ),
      );

  void emitOffer(String remoteSessionId, {String sdp = 'v=0 offer'}) =>
      emitIncoming(
        OfferReceived(
          offer: WebRtcOffer(remoteSessionId: remoteSessionId, sdp: sdp),
        ),
      );

  void emitIceCandidate(
    String remoteSessionId,
    String candidate, {
    String? sdpMid = '0',
    int? sdpMLineIndex = 0,
  }) => emitIncoming(
    IceCandidateReceived(
      candidate: WebRtcIceCandidate(
        remoteSessionId: remoteSessionId,
        candidate: candidate,
        sdpMid: sdpMid,
        sdpMLineIndex: sdpMLineIndex,
      ),
    ),
  );
}
