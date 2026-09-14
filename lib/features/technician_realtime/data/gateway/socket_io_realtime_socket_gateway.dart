import 'package:socket_io_client/socket_io_client.dart' as socket_io;

import 'realtime_socket_gateway.dart';

/// The only place in the application that imports `socket_io_client`.
///
/// It is a thin forwarder: no decision is taken here, so everything that can
/// go wrong — telling a rejected token from a dead network, parsing an ACK,
/// deciding when to join — lives in classes that can be unit tested.
///
/// Security: the handshake `auth` map carries the User JWT. It is built on
/// demand by [RealtimeAuthProvider] and is never logged, printed or stored.
class SocketIoRealtimeSocketGateway implements RealtimeSocketGateway {
  SocketIoRealtimeSocketGateway({
    required String url,
    required RealtimeAuthProvider auth,
  }) : _socket = socket_io.io(
         url,
         socket_io.OptionBuilder()
             // WebSocket first: the browser then needs no XHR polling round
             // trip, and polling stays as the fallback for restrictive proxies.
             .setTransports(['websocket', 'polling'])
             // Connecting is an explicit decision of the application: it
             // happens once the user is authenticated, not when the object is
             // built.
             .disableAutoConnect()
             // A fresh manager per instance, so a reconnection never reuses a
             // socket that was disposed after an authentication failure.
             .enableForceNew()
             .setReconnectionDelay(1000)
             .setReconnectionDelayMax(10000)
             // The token is read again on every attempt: a User JWT replaced
             // by `GET /auth/check-status` is picked up without reconnecting
             // by hand.
             .setAuthFn((callback) async => callback(await auth()))
             .build(),
       );

  final socket_io.Socket _socket;

  @override
  bool get isConnected => _socket.connected;

  @override
  void onConnect(void Function() handler) => _socket.onConnect((_) => handler());

  @override
  void onDisconnect(void Function(Object? reason) handler) =>
      _socket.onDisconnect((reason) => handler(reason));

  @override
  void onConnectError(void Function(Object? error) handler) =>
      _socket.onConnectError((error) => handler(error));

  @override
  void onReconnectAttempt(void Function() handler) =>
      _socket.onReconnectAttempt((_) => handler());

  @override
  void onEvent(String event, void Function(Object? data) handler) =>
      _socket.on(event, (data) => handler(data));

  @override
  void connect() => _socket.connect();

  @override
  void disconnect() => _socket.disconnect();

  @override
  void emitWithAck(
    String event,
    Map<String, dynamic> payload,
    void Function(Object? ack) onAck,
    // The acknowledgement is applied with whatever the server sent, so the
    // argument stays optional: an empty ack must reach the caller as a
    // malformed one, not as a crash inside Socket.IO.
  ) => _socket.emitWithAck(
    event,
    payload,
    ack: ([dynamic ack, dynamic _]) => onAck(ack),
  );

  @override
  void dispose() => _socket.dispose();
}

/// [RealtimeSocketGatewayFactory] backed by Socket.IO.
RealtimeSocketGateway createSocketIoRealtimeSocketGateway({
  required String url,
  required RealtimeAuthProvider auth,
}) => SocketIoRealtimeSocketGateway(url: url, auth: auth);
