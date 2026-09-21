import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:remote_control_web/features/signaling/domain/entities/webrtc_ice_candidate.dart';
import 'package:remote_control_web/features/signaling/domain/entities/webrtc_session_description.dart';
import 'package:remote_control_web/features/webrtc/data/flutter_webrtc_peer_client.dart';
import 'package:remote_control_web/features/webrtc/data/flutter_webrtc_remote_video_track.dart';
import 'package:remote_control_web/features/webrtc/data/mappers/rtc_ice_candidate_mapper.dart';
import 'package:remote_control_web/features/webrtc/data/mappers/rtc_state_mapper.dart';
import 'package:remote_control_web/features/webrtc/data/webrtc_contract.dart';
import 'package:remote_control_web/features/webrtc/domain/client/webrtc_peer_client.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_connection_state.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_ice_configuration.dart';
import 'package:remote_control_web/features/webrtc/domain/entities/webrtc_peer_event.dart';

/// The `flutter_webrtc` side of WebRTC, tested without a browser.
///
/// What is exercised here is exactly what the adapter owns: the configuration
/// it builds, the data channel it creates, the order of `createOffer` and
/// `setLocalDescription`, the translation of candidates and states, and the
/// teardown. The behaviour that decides *when* any of it happens lives in the
/// BLoC and is tested against the port instead — no Chromium internals are
/// simulated anywhere.
void main() {
  const sessionId = '3d1b9e64-9a0f-4c88-9d0a-6f2a5c7e8b10';
  const candidateLine =
      'candidate:842163049 1 udp 1677729535 192.0.2.10 54321 typ srflx';

  group('contract', () {
    test('the single data channel is ordered and labelled control', () {
      expect(WebRtcContract.controlChannelLabel, 'control');
      expect(WebRtcContract.controlChannelOrdered, isTrue);
    });

    test('no ICE server is configured unless one was defined', () {
      final configuration = WebRtcContract.peerConfiguration(
        const WebRtcIceConfiguration(),
      );

      expect(configuration, {'iceServers': <Object?>[]});
    });

    test('a configured STUN server reaches the peer connection', () {
      final configuration = WebRtcContract.peerConfiguration(
        WebRtcIceConfiguration.fromStunUrl('stun:stun.example.org:19302'),
      );

      expect(configuration, {
        'iceServers': [
          {'urls': 'stun:stun.example.org:19302'},
        ],
      });
    });

    test('the screen is one recvonly video section', () {
      expect(WebRtcContract.screenVideoKind, 'video');
      expect(WebRtcContract.screenVideoDirection, 'recvonly');
    });

    test('the enums handed to WebRTC carry exactly those two strings', () {
      // What `flutter_webrtc` puts in `addTransceiver` on the web: the kind
      // and the direction the contract names, and no SDP written by hand.
      expect(
        rtc.typeRTCRtpMediaTypetoString[rtc
            .RTCRtpMediaType
            .RTCRtpMediaTypeVideo],
        WebRtcContract.screenVideoKind,
      );
      expect(
        rtc.typeRtpTransceiverDirectionToString[rtc
            .TransceiverDirection
            .RecvOnly],
        WebRtcContract.screenVideoDirection,
      );
    });

    test('a blank define is the same as no STUN at all', () {
      expect(WebRtcIceConfiguration.fromStunUrl(null).isLanOnly, isTrue);
      expect(WebRtcIceConfiguration.fromStunUrl('   ').isLanOnly, isTrue);
      expect(
        WebRtcIceConfiguration.fromStunUrl(' stun:host:3478 ').iceServers.single
            .urls,
        'stun:host:3478',
      );
    });
  });

  group('state mapping', () {
    test('every peer connection state is modelled', () {
      const expected = {
        rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew:
            WebRtcPeerConnectionState.fresh,
        rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
            WebRtcPeerConnectionState.connecting,
        rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            WebRtcPeerConnectionState.connected,
        rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            WebRtcPeerConnectionState.disconnected,
        rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            WebRtcPeerConnectionState.failed,
        rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed:
            WebRtcPeerConnectionState.closed,
      };

      expected.forEach((raw, mapped) {
        expect(RtcStateMapper.peerConnectionState(raw), mapped);
      });
      expect(expected, hasLength(rtc.RTCPeerConnectionState.values.length));
    });

    test('every data channel state is modelled', () {
      const expected = {
        rtc.RTCDataChannelState.RTCDataChannelConnecting:
            WebRtcDataChannelState.connecting,
        rtc.RTCDataChannelState.RTCDataChannelOpen:
            WebRtcDataChannelState.open,
        rtc.RTCDataChannelState.RTCDataChannelClosing:
            WebRtcDataChannelState.closing,
        rtc.RTCDataChannelState.RTCDataChannelClosed:
            WebRtcDataChannelState.closed,
      };

      expected.forEach((raw, mapped) {
        expect(RtcStateMapper.dataChannelState(raw), mapped);
      });
      expect(expected, hasLength(rtc.RTCDataChannelState.values.length));
    });
  });

  group('candidate mapping', () {
    test('a gathered candidate keeps its mid and index', () {
      final mapped = RtcIceCandidateMapper.fromRtc(
        rtc.RTCIceCandidate(candidateLine, '0', 0),
        remoteSessionId: sessionId,
      );

      expect(mapped!.remoteSessionId, sessionId);
      expect(mapped.candidate, candidateLine);
      expect(mapped.sdpMid, '0');
      expect(mapped.sdpMLineIndex, 0);
    });

    test('a candidate without a line has nothing to relay', () {
      expect(
        RtcIceCandidateMapper.fromRtc(
          rtc.RTCIceCandidate(null, '0', 0),
          remoteSessionId: sessionId,
        ),
        isNull,
      );
    });

    test('a relayed candidate becomes an RTCIceCandidate', () {
      final mapped = RtcIceCandidateMapper.toRtc(
        const WebRtcIceCandidate(
          remoteSessionId: sessionId,
          candidate: candidateLine,
          sdpMid: '0',
          sdpMLineIndex: 0,
        ),
      );

      expect(mapped!.candidate, candidateLine);
      expect(mapped.sdpMid, '0');
      expect(mapped.sdpMLineIndex, 0);
    });

    test('end-of-candidates is applied, not discarded', () {
      // The contract allows `candidate: ""`, and an empty candidate line with
      // an sdpMid is the standard end-of-candidates indication.
      final mapped = RtcIceCandidateMapper.toRtc(
        const WebRtcIceCandidate(
          remoteSessionId: sessionId,
          candidate: '',
          sdpMid: '0',
          sdpMLineIndex: 0,
        ),
      );

      expect(mapped, isNotNull);
      expect(mapped!.candidate, '');
    });

    test('a candidate that names no m-section cannot be applied', () {
      expect(
        RtcIceCandidateMapper.toRtc(
          const WebRtcIceCandidate(
            remoteSessionId: sessionId,
            candidate: candidateLine,
          ),
        ),
        isNull,
      );
    });
  });

  group('the adapter', () {
    late FakeRtcPeerConnection connection;
    late FlutterWebRtcPeerClient client;
    late List<Map<String, dynamic>> configurations;

    setUp(() {
      connection = FakeRtcPeerConnection();
      configurations = [];
      client = FlutterWebRtcPeerClient(
        peerConnectionFactory: (configuration) async {
          configurations.add(configuration);
          return connection;
        },
      );
    });

    Future<WebRtcPeerSession> createSession() => client.createSession(
      remoteSessionId: sessionId,
      configuration: WebRtcIceConfiguration.fromStunUrl('stun:host:3478'),
    );

    /// The same session, seen from the data layer — where the remote track
    /// reference lives. The port does not expose it and must not.
    Future<FlutterWebRtcPeerSession> createAdapterSession() async =>
        await createSession() as FlutterWebRtcPeerSession;

    rtc.RTCTrackEvent trackEvent({
      required String kind,
      String id = 'track-0',
      List<rtc.MediaStream> streams = const [],
    }) => rtc.RTCTrackEvent(
      track: FakeMediaStreamTrack(kind: kind, id: id),
      streams: streams,
    );

    test('the peer connection is built with the configured ICE servers', () async {
      await createSession();

      expect(configurations.single, {
        'iceServers': [
          {'urls': 'stun:host:3478'},
        ],
      });
    });

    test('exactly one control channel is created', () async {
      final session = await createSession();

      await session.openControlChannel();
      await session.openControlChannel();

      expect(connection.dataChannelLabels, ['control']);
      expect(connection.dataChannelInits.single.ordered, isTrue);
      // Reliable delivery: the SCTP defaults, not a lossy channel.
      expect(connection.dataChannelInits.single.maxRetransmits, -1);
      expect(connection.dataChannelInits.single.maxRetransmitTime, -1);
    });

    test('the channel state is reported as soon as it exists', () async {
      final session = await createSession();
      final events = <WebRtcPeerEvent>[];
      session.events.listen(events.add);

      await session.openControlChannel();
      await Future<void>.delayed(Duration.zero);

      expect(
        events.single,
        const ControlChannelStateChanged(WebRtcDataChannelState.connecting),
      );
    });

    test('the offer is created and applied locally, in that order', () async {
      final session = await createSession();

      final offer = await session.createLocalOffer();

      expect(connection.calls, ['createOffer', 'setLocalDescription']);
      expect(offer.remoteSessionId, sessionId);
      expect(offer.sdp, connection.offerSdp);
      // What WebRTC produced is what is relayed: the SDP is never edited.
      expect(connection.localDescriptions.single.sdp, connection.offerSdp);
      expect(connection.localDescriptions.single.type, 'offer');
    });

    test('an offer without an SDP never reaches signaling', () async {
      connection.offerSdp = null;
      final session = await createSession();

      expect(session.createLocalOffer, throwsStateError);
    });

    test('the answer is applied as a remote description of type answer', () async {
      final session = await createSession();

      await session.applyRemoteAnswer(
        const WebRtcAnswer(remoteSessionId: sessionId, sdp: 'v=0 answer'),
      );

      expect(connection.remoteDescriptions.single.type, 'answer');
      expect(connection.remoteDescriptions.single.sdp, 'v=0 answer');
    });

    test('a remote candidate is handed to addCandidate', () async {
      final session = await createSession();

      await session.addRemoteIceCandidate(
        const WebRtcIceCandidate(
          remoteSessionId: sessionId,
          candidate: candidateLine,
          sdpMid: '0',
          sdpMLineIndex: 0,
        ),
      );

      expect(connection.addedCandidates.single.candidate, candidateLine);
    });

    test('a candidate that cannot be applied is dropped, not thrown', () async {
      final session = await createSession();

      await session.addRemoteIceCandidate(
        const WebRtcIceCandidate(
          remoteSessionId: sessionId,
          candidate: candidateLine,
        ),
      );

      expect(connection.addedCandidates, isEmpty);
    });

    test('a gathered candidate is published as a signaling model', () async {
      final session = await createSession();
      final events = <WebRtcPeerEvent>[];
      session.events.listen(events.add);

      connection.onIceCandidate!(rtc.RTCIceCandidate(candidateLine, '0', 0));
      await Future<void>.delayed(Duration.zero);

      final gathered = events.single as LocalIceCandidateGathered;
      expect(gathered.candidate.remoteSessionId, sessionId);
      expect(gathered.candidate.candidate, candidateLine);
    });

    test('connection states are published as domain states', () async {
      final session = await createSession();
      final events = <WebRtcPeerEvent>[];
      session.events.listen(events.add);

      connection.onConnectionState!(
        rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        events.single,
        const PeerConnectionStateChanged(WebRtcPeerConnectionState.connected),
      );
    });

    test('channel states and text messages are published', () async {
      final session = await createSession();
      await session.openControlChannel();
      final events = <WebRtcPeerEvent>[];
      session.events.listen(events.add);
      final channel = connection.dataChannel!;

      channel.onDataChannelState!(
        rtc.RTCDataChannelState.RTCDataChannelOpen,
      );
      channel.onMessage!(rtc.RTCDataChannelMessage('ping'));
      channel.onMessage!(
        rtc.RTCDataChannelMessage.fromBinary(Uint8List.fromList([1, 2])),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events, [
        const ControlChannelStateChanged(WebRtcDataChannelState.open),
        // Binary is not published: no protocol is defined yet.
        const ControlChannelMessageReceived('ping'),
      ]);
    });

    test('the offer declares one video section, receive only', () async {
      final session = await createSession();

      await session.prepareScreenVideoReceiver();

      expect(connection.transceiverKinds, [
        rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo,
      ]);
      expect(
        connection.transceiverInits.single.direction,
        rtc.TransceiverDirection.RecvOnly,
      );
      // The console sends nothing: no track and no stream is offered.
      expect(connection.transceiverTracks.single, isNull);
      expect(connection.transceiverInits.single.streams, isNull);
    });

    test('preparing twice does not add a second m=video', () async {
      final session = await createSession();

      await session.prepareScreenVideoReceiver();
      await session.prepareScreenVideoReceiver();

      expect(connection.transceiverKinds, hasLength(1));
    });

    test('two preparations in flight at once add one m=video', () async {
      // Idempotence that a flag set after the await would not give: both
      // callers wait on the same creation.
      final gate = Completer<void>();
      connection.addTransceiverGate = gate.future;
      final session = await createSession();

      final both = Future.wait([
        session.prepareScreenVideoReceiver(),
        session.prepareScreenVideoReceiver(),
      ]);
      gate.complete();
      await both;

      expect(connection.transceiverKinds, hasLength(1));
    });

    test('everything the offer describes exists before it is created', () async {
      final session = await createSession();

      await session.openControlChannel();
      await session.prepareScreenVideoReceiver();
      final offer = await session.createLocalOffer();

      expect(connection.calls, [
        'createDataChannel',
        'addTransceiver',
        'createOffer',
        'setLocalDescription',
      ]);
      // The SDP is whatever WebRTC produced: no m-section is written here.
      expect(offer.sdp, connection.offerSdp);
    });

    test('nothing is negotiated for a session already closed', () async {
      final session = await createSession();

      await session.close();
      await session.prepareScreenVideoReceiver();

      expect(connection.transceiverKinds, isEmpty);
    });

    test('a transceiver that arrives after the teardown is stopped', () async {
      final gate = Completer<void>();
      connection.addTransceiverGate = gate.future;
      final session = await createSession();

      final pending = session.prepareScreenVideoReceiver();
      await session.close();
      gate.complete();
      await pending;

      expect(connection.addedTransceivers.single.stopCount, 1);
    });

    test('a remote video track is published as an opaque handle', () async {
      final session = await createAdapterSession();
      final events = <WebRtcPeerEvent>[];
      session.events.listen(events.add);
      final stream = FakeMediaStream('stream-0');

      connection.onTrack!(
        trackEvent(kind: 'video', id: 'screen-0', streams: [stream]),
      );
      await Future<void>.delayed(Duration.zero);

      expect(events.single, isA<RemoteVideoTrackAvailable>());
      final track = (events.single as RemoteVideoTrackAvailable).track;
      // An identity, not media: that is the whole upward surface.
      expect(track.id, 'screen-0');
      expect(track, isA<FlutterWebRtcRemoteVideoTrack>());

      final held = session.remoteVideoTrack!;
      expect(held.mediaStreamTrack.id, 'screen-0');
      expect(held.mediaStream, same(stream));
    });

    test('a track announced without a stream is still published', () async {
      final session = await createAdapterSession();
      final events = <WebRtcPeerEvent>[];
      session.events.listen(events.add);

      connection.onTrack!(trackEvent(kind: 'video', id: 'screen-0'));
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(session.remoteVideoTrack!.mediaStream, isNull);
    });

    test('an audio track is ignored', () async {
      final session = await createAdapterSession();
      final events = <WebRtcPeerEvent>[];
      session.events.listen(events.add);

      connection.onTrack!(trackEvent(kind: 'audio', id: 'mic-0'));
      await Future<void>.delayed(Duration.zero);

      // No audio is negotiated, so none is reported and none is held.
      expect(events, isEmpty);
      expect(session.remoteVideoTrack, isNull);
    });

    test('closing releases the channel, the peer connection and the stream', () async {
      final session = await createSession();
      await session.openControlChannel();
      final channel = connection.dataChannel!;

      await session.close();

      expect(channel.closeCount, 1);
      expect(connection.closeCount, 1);
      expect(connection.disposeCount, 1);
      // Detached: a callback firing during the teardown reaches nobody.
      expect(connection.onIceCandidate, isNull);
      expect(connection.onConnectionState, isNull);
      expect(session.events.isBroadcast, isTrue);
      expect(() => session.events.listen((_) {}), returnsNormally);
    });

    test('closing lets go of the remote video track', () async {
      final session = await createAdapterSession();
      connection.onTrack!(trackEvent(kind: 'video', id: 'screen-0'));

      await session.close();

      // The track belongs to the peer connection being closed; the adapter
      // only drops its reference, and no callback can hand it another one.
      expect(session.remoteVideoTrack, isNull);
      expect(connection.onTrack, isNull);
    });

    test('closing twice is not an error', () async {
      final session = await createSession();
      await session.openControlChannel();

      await session.close();
      await session.close();

      expect(connection.closeCount, 1);
    });

    test('a teardown the browser complains about is survived', () async {
      connection.closeError = StateError('already closed');
      final session = await createSession();

      await session.close();

      expect(connection.disposeCount, 1);
    });
  });
}

/// Base for the doubles below: anything the adapter does not use throws
/// instead of being silently answered with null.
class _UnusedRtcApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not used by the adapter',
  );
}

/// A scripted `RTCPeerConnection`. It records what the adapter asked for and
/// exposes the callbacks so the test can fire them.
class FakeRtcPeerConnection extends _UnusedRtcApi
    implements rtc.RTCPeerConnection {
  final List<String> calls = [];
  final List<String> dataChannelLabels = [];
  final List<rtc.RTCDataChannelInit> dataChannelInits = [];
  final List<rtc.RTCSessionDescription> localDescriptions = [];
  final List<rtc.RTCSessionDescription> remoteDescriptions = [];
  final List<rtc.RTCIceCandidate> addedCandidates = [];

  String? offerSdp = 'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\n';
  Object? closeError;

  FakeRtcDataChannel? dataChannel;
  int closeCount = 0;
  int disposeCount = 0;

  @override
  Function(rtc.RTCIceCandidate candidate)? onIceCandidate;

  @override
  Function(rtc.RTCPeerConnectionState state)? onConnectionState;

  @override
  Function(rtc.RTCTrackEvent event)? onTrack;

  final List<rtc.RTCRtpMediaType?> transceiverKinds = [];
  final List<rtc.RTCRtpTransceiverInit> transceiverInits = [];
  final List<rtc.MediaStreamTrack?> transceiverTracks = [];
  final List<FakeRtcRtpTransceiver> addedTransceivers = [];

  /// Keeps `addTransceiver` in flight so the test can interleave something.
  Future<void>? addTransceiverGate;

  @override
  Future<rtc.RTCRtpTransceiver> addTransceiver({
    rtc.MediaStreamTrack? track,
    rtc.RTCRtpMediaType? kind,
    rtc.RTCRtpTransceiverInit? init,
  }) async {
    calls.add('addTransceiver');
    transceiverKinds.add(kind);
    transceiverTracks.add(track);
    if (init != null) transceiverInits.add(init);
    final gate = addTransceiverGate;
    if (gate != null) await gate;
    final transceiver = FakeRtcRtpTransceiver();
    addedTransceivers.add(transceiver);
    return transceiver;
  }

  @override
  Future<rtc.RTCDataChannel> createDataChannel(
    String label,
    rtc.RTCDataChannelInit dataChannelDict,
  ) async {
    calls.add('createDataChannel');
    dataChannelLabels.add(label);
    dataChannelInits.add(dataChannelDict);
    return dataChannel = FakeRtcDataChannel();
  }

  @override
  Future<rtc.RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async {
    calls.add('createOffer');
    return rtc.RTCSessionDescription(offerSdp, 'offer');
  }

  @override
  Future<void> setLocalDescription(
    rtc.RTCSessionDescription description,
  ) async {
    calls.add('setLocalDescription');
    localDescriptions.add(description);
  }

  @override
  Future<void> setRemoteDescription(
    rtc.RTCSessionDescription description,
  ) async {
    calls.add('setRemoteDescription');
    remoteDescriptions.add(description);
  }

  @override
  Future<void> addCandidate(rtc.RTCIceCandidate candidate) async {
    calls.add('addCandidate');
    addedCandidates.add(candidate);
  }

  @override
  Future<void> close() async {
    closeCount++;
    final error = closeError;
    if (error != null) throw error;
  }

  @override
  Future<void> dispose() async => disposeCount++;
}

class FakeRtcRtpTransceiver extends _UnusedRtcApi
    implements rtc.RTCRtpTransceiver {
  int stopCount = 0;

  @override
  Future<void> stop() async => stopCount++;
}

/// A remote track. Only `kind` and `id` are ever read: no media is simulated,
/// because none crosses the adapter.
class FakeMediaStreamTrack extends _UnusedRtcApi
    implements rtc.MediaStreamTrack {
  FakeMediaStreamTrack({required this.kind, required this.id});

  @override
  final String kind;

  @override
  final String id;
}

class FakeMediaStream extends _UnusedRtcApi implements rtc.MediaStream {
  FakeMediaStream(this.id);

  @override
  final String id;
}

class FakeRtcDataChannel extends _UnusedRtcApi implements rtc.RTCDataChannel {
  int closeCount = 0;

  @override
  Function(rtc.RTCDataChannelState state)? onDataChannelState;

  @override
  Function(rtc.RTCDataChannelMessage data)? onMessage;

  @override
  rtc.RTCDataChannelState? get state =>
      rtc.RTCDataChannelState.RTCDataChannelConnecting;

  @override
  String? get label => 'control';

  @override
  Future<void> close() async => closeCount++;
}
