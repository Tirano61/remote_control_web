import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../domain/entities/webrtc_connection_state.dart';

/// Turns the `flutter_webrtc` state enums into the domain ones.
///
/// It is one of the two places where a `flutter_webrtc` type is read, and it
/// exists apart from the adapter so the mapping can be unit tested without a
/// browser: these enums are plain Dart values.
class RtcStateMapper {
  const RtcStateMapper._();

  static WebRtcPeerConnectionState peerConnectionState(
    rtc.RTCPeerConnectionState state,
  ) => switch (state) {
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateNew =>
      WebRtcPeerConnectionState.fresh,
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
      WebRtcPeerConnectionState.connecting,
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
      WebRtcPeerConnectionState.connected,
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
      WebRtcPeerConnectionState.disconnected,
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
      WebRtcPeerConnectionState.failed,
    rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed =>
      WebRtcPeerConnectionState.closed,
  };

  static WebRtcDataChannelState dataChannelState(
    rtc.RTCDataChannelState state,
  ) => switch (state) {
    rtc.RTCDataChannelState.RTCDataChannelConnecting =>
      WebRtcDataChannelState.connecting,
    rtc.RTCDataChannelState.RTCDataChannelOpen => WebRtcDataChannelState.open,
    rtc.RTCDataChannelState.RTCDataChannelClosing =>
      WebRtcDataChannelState.closing,
    rtc.RTCDataChannelState.RTCDataChannelClosed =>
      WebRtcDataChannelState.closed,
  };
}
