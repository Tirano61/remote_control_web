import 'dart:async';

import '../../../core/auth/user_token_provider.dart';
import '../../../core/config/app_config.dart';
import '../../../core/logging/debug_log.dart';
import '../domain/client/technician_realtime_client.dart';
import '../domain/entities/join_remote_session_result.dart';
import '../domain/entities/remote_session_closed_notice.dart';
import '../domain/entities/technician_realtime_status.dart';
import 'gateway/realtime_connect_error.dart';
import 'gateway/realtime_socket_gateway.dart';
import 'gateway/socket_io_realtime_socket_gateway.dart';
import 'models/join_remote_session_ack_dto.dart';
import 'models/remote_session_closed_notice_dto.dart';
import 'realtime_contract.dart';

/// Socket.IO implementation of the `/technicians` namespace.
///
/// What it owns:
///
/// * the namespace URL, derived from `BACKEND_BASE_URL` and nowhere else;
/// * the handshake, which carries the current User JWT in `auth.token` and
///   nothing else — no email, no userId, no technicianId, no roles;
/// * the reconnection policy: Socket.IO retries transport failures with its
///   own backoff, but a rejected token stops it immediately, because retrying
///   a JWT that will never be accepted is an infinite loop;
/// * `remote-session:join` and its acknowledgement.
///
/// What it deliberately does not own: any notion of which session should be
/// joined, or what a closed session means. Those are decisions of the BLoCs
/// and of the coordinator, taken against REST.
class TechnicianRealtimeClientImpl implements TechnicianRealtimeClient {
  TechnicianRealtimeClientImpl({
    required AppConfig config,
    required UserTokenProvider tokenProvider,
    RealtimeSocketGatewayFactory gatewayFactory =
        createSocketIoRealtimeSocketGateway,
    Duration ackTimeout = defaultAckTimeout,
  }) : _namespaceUrl = config.socketNamespaceUrl(
         TechnicianRealtimeContract.namespace,
       ),
       _tokenProvider = tokenProvider,
       _gatewayFactory = gatewayFactory,
       _ackTimeout = ackTimeout;

  /// The backend always answers its acknowledgements, so this only guards
  /// against an emission that never reaches it.
  static const Duration defaultAckTimeout = Duration(seconds: 10);

  final String _namespaceUrl;
  final UserTokenProvider _tokenProvider;
  final RealtimeSocketGatewayFactory _gatewayFactory;
  final Duration _ackTimeout;

  final StreamController<TechnicianRealtimeStatus> _statusController =
      StreamController<TechnicianRealtimeStatus>.broadcast();
  final StreamController<RemoteSessionClosedNotice> _closedController =
      StreamController<RemoteSessionClosedNotice>.broadcast();

  RealtimeSocketGateway? _gateway;
  TechnicianRealtimeStatus _status = const TechnicianRealtimeDisconnected();

  /// Increases on every successful handshake, so consumers can tell a brand new
  /// socket from the one they already joined a session with.
  int _connectionCounter = 0;
  bool _isDisposed = false;

  @override
  TechnicianRealtimeStatus get status => _status;

  @override
  Stream<TechnicianRealtimeStatus> get statusChanges =>
      _statusController.stream;

  @override
  Stream<RemoteSessionClosedNotice> get remoteSessionClosed =>
      _closedController.stream;

  @override
  Future<void> connect() async {
    if (_isDisposed) return;
    // Already connected, connecting or retrying: Socket.IO owns the attempt.
    if (_gateway != null) return;

    final token = await _tokenProvider.currentToken();
    if (token == null || token.isEmpty) {
      // Without a User JWT the handshake could only be rejected. Report it as
      // what it is so the console goes back to the login page instead of
      // hammering the backend.
      _emit(
        const TechnicianRealtimeConnectionError(isAuthenticationError: true),
      );
      return;
    }

    final gateway = _gatewayFactory(url: _namespaceUrl, auth: _currentAuth);
    _gateway = gateway;

    gateway.onConnect(() {
      if (!identical(_gateway, gateway)) return;
      _connectionCounter++;
      logDebug('socket connected (/technicians)');
      _emit(TechnicianRealtimeConnected(_connectionCounter));
    });

    gateway.onDisconnect((reason) {
      if (!identical(_gateway, gateway)) return;
      logDebug('socket disconnected (/technicians)');
      // Rooms die with the connection, so consumers must treat this as "the
      // session has to be joined again", not as a domain change.
      _emit(const TechnicianRealtimeReconnecting());
    });

    gateway.onReconnectAttempt(() {
      if (!identical(_gateway, gateway)) return;
      _emit(const TechnicianRealtimeReconnecting());
    });

    gateway.onConnectError((error) {
      if (!identical(_gateway, gateway)) return;
      final isAuthenticationError = RealtimeConnectError.isAuthenticationFailure(
        error,
      );
      if (isAuthenticationError) {
        // There is no refresh token: retrying cannot help. Stop the socket and
        // let the console reconcile the user session.
        logDebug('socket handshake rejected (/technicians)');
        _teardown();
      }
      _emit(
        TechnicianRealtimeConnectionError(
          isAuthenticationError: isAuthenticationError,
        ),
      );
    });

    gateway.onEvent(TechnicianRealtimeContract.remoteSessionClosedEvent, (
      data,
    ) {
      if (!identical(_gateway, gateway)) return;
      final notice = RemoteSessionClosedNoticeDto.fromEvent(data);
      if (notice == null) return;
      logDebug(
        'remote-session:closed received ${notice.remoteSessionId}',
      );
      if (!_closedController.isClosed) _closedController.add(notice);
    });

    _emit(const TechnicianRealtimeConnecting());
    gateway.connect();
  }

  @override
  Future<void> disconnect() async {
    if (_gateway == null && _status is TechnicianRealtimeDisconnected) return;
    _teardown();
    _emit(const TechnicianRealtimeDisconnected());
  }

  @override
  Future<JoinRemoteSessionResult> joinRemoteSession(
    String remoteSessionId,
  ) async {
    final gateway = _gateway;
    if (gateway == null || !gateway.isConnected) {
      return const JoinRemoteSessionFailed(
        JoinRemoteSessionFailureReason.notConnected,
      );
    }

    final completer = Completer<JoinRemoteSessionResult>();
    final timeout = Timer(_ackTimeout, () {
      if (completer.isCompleted) return;
      completer.complete(
        const JoinRemoteSessionFailed(JoinRemoteSessionFailureReason.timeout),
      );
    });

    logDebug('join requested $remoteSessionId');
    gateway.emitWithAck(
      TechnicianRealtimeContract.joinEvent,
      TechnicianRealtimeContract.joinPayload(remoteSessionId),
      (ack) {
        timeout.cancel();
        if (completer.isCompleted) return;
        final result = JoinRemoteSessionAckDto.fromAck(
          ack,
          requestedRemoteSessionId: remoteSessionId,
        );
        if (result is JoinRemoteSessionAccepted) {
          logDebug('join accepted $remoteSessionId');
        }
        completer.complete(result);
      },
    );

    return completer.future;
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _teardown();
    await _statusController.close();
    await _closedController.close();
  }

  /// Handshake payload. Read at connection time, and again at every Socket.IO
  /// reconnection attempt, so a renewed User JWT is picked up on its own.
  Future<Map<String, dynamic>> _currentAuth() async {
    final token = await _tokenProvider.currentToken();
    return TechnicianRealtimeContract.authPayload(token ?? '');
  }

  void _teardown() {
    final gateway = _gateway;
    _gateway = null;
    gateway?.dispose();
  }

  void _emit(TechnicianRealtimeStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }
}
