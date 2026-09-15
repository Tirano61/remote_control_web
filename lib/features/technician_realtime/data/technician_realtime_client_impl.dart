import 'dart:async';

import '../../../core/auth/user_token_provider.dart';
import '../../../core/config/app_config.dart';
import '../../../core/logging/debug_log.dart';
import '../../signaling/data/signaling_contract.dart';
import '../../signaling/data/signaling_transport.dart';
import '../domain/client/technician_realtime_client.dart';
import '../domain/entities/join_remote_session_result.dart';
import '../domain/entities/remote_session_closed_notice.dart';
import '../domain/entities/remote_session_peer_joined_notice.dart';
import '../domain/entities/signaling_error_code.dart';
import '../domain/entities/technician_realtime_status.dart';
import 'gateway/realtime_connect_error.dart';
import 'gateway/realtime_socket_gateway.dart';
import 'gateway/socket_io_realtime_socket_gateway.dart';
import 'models/join_remote_session_ack_dto.dart';
import 'models/remote_session_closed_notice_dto.dart';
import 'models/remote_session_peer_joined_dto.dart';
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
/// * `remote-session:join`, its acknowledgement, and the room membership it
///   produces.
///
/// It is also the [SignalingTransport] of the application. The `webrtc:*`
/// relay runs over this very socket — one browser, one `/technicians`
/// connection — and this class is what makes that literal: it forwards the
/// relayed events without looking inside them and emits what the signaling
/// client hands it. It never parses, stores or logs an SDP or a candidate.
///
/// What it deliberately does not own: any notion of which session should be
/// joined, or what a closed session means. Those are decisions of the BLoCs
/// and of the coordinator, taken against REST.
class TechnicianRealtimeClientImpl
    implements TechnicianRealtimeClient, SignalingTransport {
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
  final StreamController<RemoteSessionPeerJoinedNotice> _peerJoinedController =
      StreamController<RemoteSessionPeerJoinedNotice>.broadcast();

  /// Relayed `webrtc:*` events, forwarded raw to the signaling client.
  final StreamController<SignalingWireEvent> _signalingController =
      StreamController<SignalingWireEvent>.broadcast();

  RealtimeSocketGateway? _gateway;
  TechnicianRealtimeStatus _status = const TechnicianRealtimeDisconnected();

  /// Increases on every successful handshake, so consumers can tell a brand new
  /// socket from the one they already joined a session with.
  int _connectionCounter = 0;
  bool _isDisposed = false;

  /// Session this socket is in the signaling room of, or `null`.
  ///
  /// It is the client side of a server side fact: the backend stores the
  /// joined session on the socket and authorizes every `webrtc:*` against it.
  /// Kept in sync with what the acknowledgements say, and dropped with the
  /// connection, because rooms do not survive it.
  String? _joinedRemoteSessionId;

  @override
  TechnicianRealtimeStatus get status => _status;

  @override
  Stream<TechnicianRealtimeStatus> get statusChanges =>
      _statusController.stream;

  @override
  Stream<RemoteSessionClosedNotice> get remoteSessionClosed =>
      _closedController.stream;

  @override
  Stream<RemoteSessionPeerJoinedNotice> get peerJoined =>
      _peerJoinedController.stream;

  @override
  String? get joinedRemoteSessionId => _joinedRemoteSessionId;

  @override
  Stream<SignalingWireEvent> get signalingEvents =>
      _signalingController.stream;

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
      // session has to be joined again", not as a domain change. Signaling is
      // refused locally until a new join succeeds.
      _joinedRemoteSessionId = null;
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

    for (final event in SignalingContract.relayEvents) {
      // Forwarded raw and unread: what an offer, an answer or a candidate
      // contains is none of this class's business, which is exactly why no
      // SDP or ICE ever reaches its logs.
      gateway.onEvent(event, (data) {
        if (!identical(_gateway, gateway)) return;
        if (_signalingController.isClosed) return;
        _signalingController.add((event: event, data: data));
      });
    }

    gateway.onEvent(TechnicianRealtimeContract.remoteSessionPeerJoinedEvent, (
      data,
    ) {
      if (!identical(_gateway, gateway)) return;
      final notice = RemoteSessionPeerJoinedDto.fromEvent(data);
      if (notice == null) return;
      logDebug('remote-session:peer-joined received ${notice.remoteSessionId}');
      if (!_peerJoinedController.isClosed) _peerJoinedController.add(notice);
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
        _applyJoinOutcome(result);
        completer.complete(result);
      },
    );

    return completer.future;
  }

  @override
  bool emitSignaling(
    String event,
    Map<String, dynamic> payload,
    void Function(Object? ack) onAck,
  ) {
    final gateway = _gateway;
    if (gateway == null || !gateway.isConnected) return false;
    gateway.emitWithAck(event, payload, onAck);
    return true;
  }

  @override
  void forgetJoinedRemoteSession() => _joinedRemoteSessionId = null;

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _teardown();
    await _statusController.close();
    await _closedController.close();
    await _peerJoinedController.close();
    await _signalingController.close();
  }

  /// Keeps the stored room membership in step with what the backend answered.
  ///
  /// `docs/backend/REALTIME.md` describes what a join does to the session
  /// already stored on the socket:
  ///
  /// ```text
  /// payload invalid        -> the socket KEEPS its current session
  /// payload valid, join OK -> it leaves the old session and joins the new one
  /// payload valid, denied  -> it has ALREADY left and has no session at all
  /// ```
  ///
  /// An acknowledgement that never arrived says nothing, so membership is
  /// dropped there too: claiming a room this client is not sure about would
  /// let it relay into nothing, while the opposite mistake costs one join.
  void _applyJoinOutcome(JoinRemoteSessionResult result) {
    switch (result) {
      case JoinRemoteSessionAccepted(:final remoteSessionId):
        _joinedRemoteSessionId = remoteSessionId;
      case JoinRemoteSessionRejected(:final error)
          when error == SignalingErrorCode.invalidPayload:
        break;
      case JoinRemoteSessionRejected():
      case JoinRemoteSessionFailed():
        _joinedRemoteSessionId = null;
    }
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
    _joinedRemoteSessionId = null;
    gateway?.dispose();
  }

  void _emit(TechnicianRealtimeStatus status) {
    if (_status == status) return;
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }
}
