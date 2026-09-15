import 'package:equatable/equatable.dart';

/// One ICE server offered to the peer connection.
///
/// Only STUN is modelled today. TURN would additionally need a username and a
/// credential, and those are secrets that must be issued by the backend — see
/// [WebRtcIceConfiguration].
class WebRtcIceServer extends Equatable {
  const WebRtcIceServer(this.urls);

  /// A single URL, e.g. `stun:stun.l.google.com:19302`.
  final String urls;

  @override
  List<Object?> get props => [urls];

  @override
  String toString() => 'WebRtcIceServer($urls)';
}

/// ICE configuration of the technician side, in one place.
///
/// It is built once from `AppConfig` in the composition root and handed to the
/// WebRTC adapter, so no ICE server is ever written inside a widget, a BLoC or
/// the adapter itself.
///
/// ```bash
/// flutter run -d chrome --dart-define=WEBRTC_STUN_URL=stun:stun.l.google.com:19302
/// ```
///
/// With no define the list is empty, which is the right default for the LAN
/// tests this stage is about: host candidates alone are enough when the tablet
/// and the browser sit on the same network.
///
/// **TURN is deliberately absent.** Outside favourable networks — symmetric
/// NAT, mobile carriers, restrictive corporate firewalls — a STUN-only
/// configuration will fail to connect, and a TURN/coturn relay will be
/// required. TURN needs credentials, which are secrets and must be issued by
/// `remote_control_backend`; none are hardcoded here.
class WebRtcIceConfiguration extends Equatable {
  const WebRtcIceConfiguration({this.iceServers = const []});

  /// The configuration described by an optional STUN URL.
  ///
  /// A missing, empty or blank URL produces `iceServers: []` rather than a
  /// guessed public server: reaching a third party host must be an explicit
  /// decision of whoever builds the application.
  factory WebRtcIceConfiguration.fromStunUrl(String? stunUrl) {
    final url = stunUrl?.trim() ?? '';
    if (url.isEmpty) return const WebRtcIceConfiguration();
    return WebRtcIceConfiguration(iceServers: [WebRtcIceServer(url)]);
  }

  final List<WebRtcIceServer> iceServers;

  /// LAN only: no STUN, no TURN, host candidates exclusively.
  bool get isLanOnly => iceServers.isEmpty;

  @override
  List<Object?> get props => [iceServers];

  @override
  String toString() => 'WebRtcIceConfiguration(iceServers: ${iceServers.length})';
}
