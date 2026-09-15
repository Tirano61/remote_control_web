import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../../core/logging/debug_log.dart';
import '../../signaling/domain/entities/webrtc_ice_candidate.dart';
import '../../signaling/domain/entities/webrtc_session_description.dart';
import '../domain/client/webrtc_peer_client.dart';
import '../domain/entities/webrtc_ice_configuration.dart';
import '../domain/entities/webrtc_peer_event.dart';
import 'mappers/rtc_ice_candidate_mapper.dart';
import 'mappers/rtc_state_mapper.dart';
import 'webrtc_contract.dart';

/// Builds a real `RTCPeerConnection` for every negotiation.
///
/// This file and the two mappers next to it are the only ones in the
/// application that import `package:flutter_webrtc`. Everything else — the
/// BLoC, the coordinator, the widgets — sees the port and the domain models.
class FlutterWebRtcPeerClient implements WebRtcPeerClient {
  const FlutterWebRtcPeerClient({
    RtcPeerConnectionFactory peerConnectionFactory = _createPeerConnection,
  }) : _peerConnectionFactory = peerConnectionFactory;

  final RtcPeerConnectionFactory _peerConnectionFactory;

  @override
  Future<WebRtcPeerSession> createSession({
    required String remoteSessionId,
    required WebRtcIceConfiguration configuration,
  }) async {
    final connection = await _peerConnectionFactory(
      WebRtcContract.peerConfiguration(configuration),
    );
    logDebug(
      'peer connection created $remoteSessionId '
      '(iceServers: ${configuration.iceServers.length})',
    );
    return FlutterWebRtcPeerSession(
      remoteSessionId: remoteSessionId,
      connection: connection,
    );
  }
}

/// Creates the browser peer connection. Replaced in tests.
typedef RtcPeerConnectionFactory =
    Future<rtc.RTCPeerConnection> Function(Map<String, dynamic> configuration);

Future<rtc.RTCPeerConnection> _createPeerConnection(
  Map<String, dynamic> configuration,
) => rtc.createPeerConnection(configuration);

/// One `RTCPeerConnection` and its `control` data channel.
///
/// The class is deliberately thin. It owns the WebRTC objects, translates in
/// both directions, and reports what happened; it decides nothing. When to
/// negotiate, what to do with a candidate that arrived too early and whether a
/// failure ends the assistance are orchestration questions, and they are
/// answered by the BLoC — which can be tested without a browser precisely
/// because none of that lives here.
///
/// Security: no SDP and no candidate line is ever logged, here or anywhere.
class FlutterWebRtcPeerSession implements WebRtcPeerSession {
  FlutterWebRtcPeerSession({
    required this.remoteSessionId,
    required rtc.RTCPeerConnection connection,
  }) : _connection = connection {
    _connection
      ..onIceCandidate = _onIceCandidate
      ..onConnectionState = _onConnectionState;
  }

  @override
  final String remoteSessionId;

  final rtc.RTCPeerConnection _connection;

  final StreamController<WebRtcPeerEvent> _events =
      StreamController<WebRtcPeerEvent>.broadcast();

  rtc.RTCDataChannel? _controlChannel;
  bool _isClosed = false;

  @override
  Stream<WebRtcPeerEvent> get events => _events.stream;

  @override
  Future<void> openControlChannel() async {
    if (_isClosed) return;
    // Exactly one channel per session: a second one would be a second SCTP
    // stream the tablet never asked for.
    if (_controlChannel != null) return;

    final channel = await _connection.createDataChannel(
      WebRtcContract.controlChannelLabel,
      rtc.RTCDataChannelInit()
        ..ordered = WebRtcContract.controlChannelOrdered,
    );
    if (_isClosed) {
      // The negotiation was abandoned while the channel was being created.
      await _quietly(channel.close);
      return;
    }

    _controlChannel = channel;
    channel
      ..onDataChannelState = _onDataChannelState
      ..onMessage = _onDataChannelMessage;

    logDebug('control channel created $remoteSessionId');
    final state = channel.state;
    if (state != null) _onDataChannelState(state);
  }

  @override
  Future<WebRtcOffer> createLocalOffer() async {
    final offer = await _connection.createOffer();
    // Only an offer that is applied locally may be relayed, and it is relayed
    // exactly as WebRTC produced it: the SDP is never edited.
    await _connection.setLocalDescription(offer);
    final sdp = offer.sdp;
    if (sdp == null || sdp.isEmpty) {
      throw StateError('WebRTC produced an offer without an SDP');
    }
    logDebug('offer created $remoteSessionId');
    return WebRtcOffer(remoteSessionId: remoteSessionId, sdp: sdp);
  }

  @override
  Future<void> applyRemoteAnswer(WebRtcAnswer answer) async {
    await _connection.setRemoteDescription(
      rtc.RTCSessionDescription(answer.sdp, WebRtcContract.answerType),
    );
    logDebug('remote description applied $remoteSessionId');
  }

  @override
  Future<void> addRemoteIceCandidate(WebRtcIceCandidate candidate) async {
    final mapped = RtcIceCandidateMapper.toRtc(candidate);
    if (mapped == null) {
      // Nothing to place: see RtcIceCandidateMapper. ICE still has the rest.
      logDebug('remote ICE candidate not applicable $remoteSessionId');
      return;
    }
    await _connection.addCandidate(mapped);
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    // Detached first: a callback firing during the teardown belongs to a
    // negotiation nobody listens to any more.
    _connection
      ..onIceCandidate = null
      ..onConnectionState = null;
    final channel = _controlChannel;
    _controlChannel = null;
    if (channel != null) {
      channel
        ..onDataChannelState = null
        ..onMessage = null;
      await _quietly(channel.close);
    }

    await _quietly(_connection.close);
    await _quietly(_connection.dispose);
    await _events.close();
    logDebug('peer connection closed $remoteSessionId');
  }

  void _onIceCandidate(rtc.RTCIceCandidate candidate) {
    final mapped = RtcIceCandidateMapper.fromRtc(
      candidate,
      remoteSessionId: remoteSessionId,
    );
    if (mapped == null) return;
    _emit(LocalIceCandidateGathered(mapped));
  }

  void _onConnectionState(rtc.RTCPeerConnectionState state) {
    final mapped = RtcStateMapper.peerConnectionState(state);
    logDebug('peer connection ${mapped.name} $remoteSessionId');
    _emit(PeerConnectionStateChanged(mapped));
  }

  void _onDataChannelState(rtc.RTCDataChannelState state) {
    final mapped = RtcStateMapper.dataChannelState(state);
    logDebug('control channel ${mapped.name} $remoteSessionId');
    _emit(ControlChannelStateChanged(mapped));
  }

  void _onDataChannelMessage(rtc.RTCDataChannelMessage message) {
    // No protocol exists yet, so nothing is parsed and nothing is logged.
    if (message.isBinary) return;
    _emit(ControlChannelMessageReceived(message.text));
  }

  void _emit(WebRtcPeerEvent event) {
    if (_isClosed || _events.isClosed) return;
    _events.add(event);
  }

  /// Teardown must never throw: a negotiation can end from several directions
  /// at once, and closing something the browser already closed is normal.
  Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      logDebug('peer teardown ignored an error $remoteSessionId');
    }
  }
}
