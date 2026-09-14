import 'dart:async';

import 'package:remote_control_web/features/technician_realtime/data/gateway/realtime_socket_gateway.dart';
import 'package:remote_control_web/features/technician_realtime/domain/client/technician_realtime_client.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/join_remote_session_result.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/remote_session_closed_notice.dart';
import 'package:remote_control_web/features/technician_realtime/domain/entities/technician_realtime_status.dart';

/// Scripted [TechnicianRealtimeClient].
///
/// No socket and no server: the test decides when the connection succeeds,
/// drops or is rejected, and what the join is answered with.
class FakeTechnicianRealtimeClient implements TechnicianRealtimeClient {
  final StreamController<TechnicianRealtimeStatus> _statusController =
      StreamController<TechnicianRealtimeStatus>.broadcast();
  final StreamController<RemoteSessionClosedNotice> _closedController =
      StreamController<RemoteSessionClosedNotice>.broadcast();

  TechnicianRealtimeStatus _status = const TechnicianRealtimeDisconnected();

  int connectCount = 0;
  int disconnectCount = 0;
  int disposeCount = 0;

  final List<String> joinedSessionIds = [];

  /// Answer of the next join. Defaults to an accepted one.
  JoinRemoteSessionResult? joinResult;

  /// Keeps a join in flight so a second trigger can be attempted meanwhile.
  Future<void>? joinGate;

  int _connectionCounter = 0;

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
    connectCount++;
    emitStatus(const TechnicianRealtimeConnecting());
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    emitStatus(const TechnicianRealtimeDisconnected());
  }

  @override
  Future<JoinRemoteSessionResult> joinRemoteSession(
    String remoteSessionId,
  ) async {
    joinedSessionIds.add(remoteSessionId);
    final gate = joinGate;
    if (gate != null) await gate;
    return joinResult ?? JoinRemoteSessionAccepted(remoteSessionId);
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await _statusController.close();
    await _closedController.close();
  }

  // --- test helpers -------------------------------------------------------

  void emitStatus(TechnicianRealtimeStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  /// A successful handshake. Every call is a different connection, exactly like
  /// a real reconnection.
  void emitConnected() {
    _connectionCounter++;
    emitStatus(TechnicianRealtimeConnected(_connectionCounter));
  }

  void emitReconnecting() =>
      emitStatus(const TechnicianRealtimeReconnecting());

  void emitAuthenticationError() => emitStatus(
    const TechnicianRealtimeConnectionError(isAuthenticationError: true),
  );

  void emitNetworkError() => emitStatus(
    const TechnicianRealtimeConnectionError(isAuthenticationError: false),
  );

  void emitRemoteSessionClosed(
    String remoteSessionId, {
    String? endedBy = 'DEVICE',
  }) {
    if (_closedController.isClosed) return;
    _closedController.add(
      RemoteSessionClosedNotice(
        remoteSessionId: remoteSessionId,
        endedBy: endedBy,
      ),
    );
  }
}

/// Scripted [RealtimeSocketGateway] standing in for Socket.IO.
///
/// It records what the client subscribed to and lets the test fire each
/// callback, so the whole connection lifecycle can be exercised without a
/// server.
class FakeRealtimeSocketGateway implements RealtimeSocketGateway {
  FakeRealtimeSocketGateway({required this.url, required this.auth});

  final String url;
  final RealtimeAuthProvider auth;

  @override
  bool isConnected = false;

  int connectCount = 0;
  int disconnectCount = 0;
  int disposeCount = 0;

  final List<({String event, Map<String, dynamic> payload})> emitted = [];

  void Function()? _onConnect;
  void Function(Object? reason)? _onDisconnect;
  void Function(Object? error)? _onConnectError;
  void Function()? _onReconnectAttempt;
  final Map<String, void Function(Object? data)> _eventHandlers = {};
  void Function(Object? ack)? _pendingAck;

  @override
  void onConnect(void Function() handler) => _onConnect = handler;

  @override
  void onDisconnect(void Function(Object? reason) handler) =>
      _onDisconnect = handler;

  @override
  void onConnectError(void Function(Object? error) handler) =>
      _onConnectError = handler;

  @override
  void onReconnectAttempt(void Function() handler) =>
      _onReconnectAttempt = handler;

  @override
  void onEvent(String event, void Function(Object? data) handler) =>
      _eventHandlers[event] = handler;

  @override
  void connect() => connectCount++;

  @override
  void disconnect() {
    disconnectCount++;
    isConnected = false;
  }

  @override
  void emitWithAck(
    String event,
    Map<String, dynamic> payload,
    void Function(Object? ack) onAck,
  ) {
    emitted.add((event: event, payload: payload));
    _pendingAck = onAck;
  }

  @override
  void dispose() {
    disposeCount++;
    isConnected = false;
  }

  // --- test helpers -------------------------------------------------------

  /// The handshake succeeded.
  void completeHandshake() {
    isConnected = true;
    _onConnect?.call();
  }

  /// The connection dropped; Socket.IO would start retrying.
  void dropConnection([Object? reason = 'transport close']) {
    isConnected = false;
    _onDisconnect?.call(reason);
  }

  void reportConnectError(Object? error) => _onConnectError?.call(error);

  void reportReconnectAttempt() => _onReconnectAttempt?.call();

  void emitServerEvent(String event, Object? data) =>
      _eventHandlers[event]?.call(data);

  /// Answers the acknowledgement of the last emission.
  void answerAck(Object? ack) => _pendingAck?.call(ack);

  /// The handshake `auth` map the gateway would put on the wire.
  Future<Map<String, dynamic>> currentAuth() => auth();
}

/// Records every gateway the client builds, so the test can drive them.
class RecordingGatewayFactory {
  final List<FakeRealtimeSocketGateway> gateways = [];

  FakeRealtimeSocketGateway get last => gateways.last;

  RealtimeSocketGateway call({
    required String url,
    required RealtimeAuthProvider auth,
  }) {
    final gateway = FakeRealtimeSocketGateway(url: url, auth: auth);
    gateways.add(gateway);
    return gateway;
  }
}
