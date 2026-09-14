/// Supplies the handshake `auth` map for every connection attempt.
///
/// It is a function and not a fixed value on purpose: Socket.IO resends `auth`
/// on each reconnection, and `GET /auth/check-status` may have replaced the
/// stored User JWT in the meantime. The token is read when it is needed, never
/// copied into a long lived variable.
typedef RealtimeAuthProvider = Future<Map<String, dynamic>> Function();

/// The slice of Socket.IO the realtime client actually uses.
///
/// It exists so that everything above it — the client, the BLoCs, the
/// coordinator — can be tested without a server, and so that exactly one file
/// in the application imports `socket_io_client`.
abstract interface class RealtimeSocketGateway {
  bool get isConnected;

  /// The handshake succeeded.
  void onConnect(void Function() handler);

  /// The connection was lost or closed. The argument is the transport reason
  /// and is only useful for debugging.
  void onDisconnect(void Function(Object? reason) handler);

  /// The connection could not be established. The argument is the raw error;
  /// interpreting it is the caller's job.
  void onConnectError(void Function(Object? error) handler);

  /// Socket.IO started a new attempt with its own backoff.
  void onReconnectAttempt(void Function() handler);

  /// Subscribes to a server sent event.
  void onEvent(String event, void Function(Object? data) handler);

  /// Starts connecting. Reconnection is handled by Socket.IO itself.
  void connect();

  /// Closes the connection and stops reconnecting.
  void disconnect();

  /// Emits [event] and reports its acknowledgement to [onAck].
  void emitWithAck(
    String event,
    Map<String, dynamic> payload,
    void Function(Object? ack) onAck,
  );

  /// Closes everything and removes every listener.
  void dispose();
}

/// Builds a gateway for one namespace URL.
typedef RealtimeSocketGatewayFactory =
    RealtimeSocketGateway Function({
      required String url,
      required RealtimeAuthProvider auth,
    });
