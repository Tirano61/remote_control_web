import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../../core/logging/debug_log.dart';
import '../../signaling/domain/entities/webrtc_ice_candidate.dart';
import '../../signaling/domain/entities/webrtc_session_description.dart';
import '../domain/client/webrtc_peer_client.dart';
import '../domain/entities/webrtc_ice_configuration.dart';
import '../domain/entities/webrtc_peer_event.dart';
import 'flutter_webrtc_remote_video_track.dart';
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
      ..onConnectionState = _onConnectionState
      ..onTrack = _onTrack;
  }

  @override
  final String remoteSessionId;

  final rtc.RTCPeerConnection _connection;

  final StreamController<WebRtcPeerEvent> _events =
      StreamController<WebRtcPeerEvent>.broadcast();

  rtc.RTCDataChannel? _controlChannel;

  /// The single `recvonly` video transceiver, memoised as the future that
  /// creates it.
  ///
  /// Keeping the *future* rather than a flag or the transceiver itself is what
  /// makes [prepareScreenVideoReceiver] idempotent even when it is called
  /// twice before the first call has finished: both callers await the same
  /// creation, and the offer keeps exactly one `m=video` section.
  Future<void>? _screenVideoReceiver;

  /// The last video track `onTrack` delivered, if any. Owned by the peer
  /// connection: this is a reference, not a copy, and it is dropped on close.
  FlutterWebRtcRemoteVideoTrack? _remoteVideoTrack;

  bool _isClosed = false;

  @override
  Stream<WebRtcPeerEvent> get events => _events.stream;

  /// The video track currently being received, or `null` while the tablet
  /// sends none — which is the normal state today, since screen capture is not
  /// implemented on the device yet.
  ///
  /// Not part of the port: above the data layer a track is announced by
  /// [RemoteVideoTrackAvailable] and nothing else. This getter exists for the
  /// renderer binding that will live next to this adapter, and for the tests
  /// that check the reference is dropped on close.
  FlutterWebRtcRemoteVideoTrack? get remoteVideoTrack => _remoteVideoTrack;

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
  Future<void> prepareScreenVideoReceiver() {
    if (_isClosed) return Future<void>.value();
    return _screenVideoReceiver ??= _addScreenVideoReceiver();
  }

  /// Adds the one media section the offer needs: video, receive-only.
  ///
  /// A transceiver, not `offerToReceiveVideo`: Unified Plan is what browsers
  /// and libwebrtc implement today, the legacy constraint makes libwebrtc
  /// print a deprecation warning, and a transceiver is also the object a later
  /// stage will read the direction back from. No SDP is written by hand here
  /// or anywhere — the `m=video` section is produced by `createOffer`.
  Future<void> _addScreenVideoReceiver() async {
    final transceiver = await _connection.addTransceiver(
      kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: rtc.RTCRtpTransceiverInit(
        direction: rtc.TransceiverDirection.RecvOnly,
      ),
    );
    if (_isClosed) {
      // The negotiation was abandoned while the transceiver was being added.
      await _quietly(transceiver.stop);
      return;
    }
    logDebug('video recvonly transceiver created $remoteSessionId');
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
      ..onConnectionState = null
      ..onTrack = null;
    // The remote track belongs to the peer connection being closed; letting
    // go of it is all this side has to do.
    _remoteVideoTrack = null;
    _screenVideoReceiver = null;
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

  void _onTrack(rtc.RTCTrackEvent event) {
    final track = event.track;
    if (track.kind != WebRtcContract.screenVideoKind) {
      // Only the screen is negotiated. Nothing asks for audio, so a track that
      // is not video is dropped instead of being reported upwards.
      logDebug('non-video remote track ignored $remoteSessionId');
      return;
    }

    final remoteTrack = FlutterWebRtcRemoteVideoTrack(
      mediaStreamTrack: track,
      // A sender may announce the track without an msid; a renderer will then
      // be given the track alone.
      mediaStream: event.streams.isEmpty ? null : event.streams.first,
    );
    _remoteVideoTrack = remoteTrack;
    // The safe identifier only: no frame, no codec, no track content.
    logDebug('remote video track received $remoteSessionId');
    _emit(RemoteVideoTrackAvailable(remoteTrack));
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
