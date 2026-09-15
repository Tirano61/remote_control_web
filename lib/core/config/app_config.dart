/// Centralised backend configuration.
///
/// The backend base URL is the single place where the host of
/// `remote_control_backend` is defined. It must never be hardcoded anywhere
/// else in the application.
///
/// It is provided at compile time:
///
/// ```bash
/// flutter run -d chrome --dart-define=BACKEND_BASE_URL=http://localhost:3000
/// flutter build web --dart-define=BACKEND_BASE_URL=https://w4qb7jsw-3000.brs.devtunnels.ms
/// ```
///
/// When the define is absent, the local development default is used.
///
/// The optional STUN server of the WebRTC peer connection is configured the
/// same way, and for the same reason: one place, no hardcoded host.
///
/// ```bash
/// flutter run -d chrome --dart-define=WEBRTC_STUN_URL=stun:stun.l.google.com:19302
/// ```
class AppConfig {
  const AppConfig({
    required this.backendBaseUrl,
    this.webRtcStunUrl = '',
    this.connectTimeout = defaultConnectTimeout,
    this.receiveTimeout = defaultReceiveTimeout,
    this.sendTimeout = defaultSendTimeout,
  });

  /// Reads the configuration from the compile-time environment.
  factory AppConfig.fromEnvironment() => const AppConfig(
    backendBaseUrl: _backendBaseUrlFromEnvironment,
    webRtcStunUrl: _webRtcStunUrlFromEnvironment,
  );

  static const String defaultBackendBaseUrl = 'http://localhost:3000';

  static const Duration defaultConnectTimeout = Duration(seconds: 10);
  static const Duration defaultReceiveTimeout = Duration(seconds: 15);
  static const Duration defaultSendTimeout = Duration(seconds: 15);

  static const String _backendBaseUrlFromEnvironment = String.fromEnvironment(
    'BACKEND_BASE_URL',
    defaultValue: defaultBackendBaseUrl,
  );

  /// No default on purpose: with no define the peer connection is configured
  /// with an empty `iceServers` list, which is what LAN testing needs and what
  /// keeps the browser from contacting a third party host nobody asked for.
  static const String _webRtcStunUrlFromEnvironment = String.fromEnvironment(
    'WEBRTC_STUN_URL',
  );

  /// Raw base URL as configured, e.g. `http://localhost:3000`.
  final String backendBaseUrl;

  /// Optional STUN server, e.g. `stun:stun.l.google.com:19302`.
  ///
  /// Empty means "no ICE server at all". TURN is not configurable here yet:
  /// it needs credentials, which are secrets and must come from the backend.
  final String webRtcStunUrl;

  final Duration connectTimeout;
  final Duration receiveTimeout;
  final Duration sendTimeout;

  /// Base URL without a trailing slash, so paths can be appended safely.
  ///
  /// The backend registers no global prefix: routes are mounted at the root
  /// of the HTTP server (`<base>/auth/login`).
  String get normalizedBackendBaseUrl {
    var url = backendBaseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// The configured STUN URL, or `null` when there is none.
  String? get normalizedWebRtcStunUrl {
    final url = webRtcStunUrl.trim();
    return url.isEmpty ? null : url;
  }

  /// URL of a Socket.IO namespace, derived from the very same base URL.
  ///
  /// Socket.IO runs on the same host and port as the HTTP API, at the default
  /// `/socket.io` path, so there is no second host to configure and none may
  /// be hardcoded: `http://localhost:3000` and a Dev Tunnel URL both work by
  /// changing `BACKEND_BASE_URL` alone.
  String socketNamespaceUrl(String namespace) {
    final path = namespace.startsWith('/') ? namespace : '/$namespace';
    return '$normalizedBackendBaseUrl$path';
  }
}
