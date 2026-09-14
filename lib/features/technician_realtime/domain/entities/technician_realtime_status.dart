import 'package:equatable/equatable.dart';

/// Connection state of the `/technicians` Socket.IO namespace.
///
/// This is the state of the *transport* only. Being connected says nothing
/// about having joined a remote session room: that is tracked separately,
/// because the two can and do diverge.
sealed class TechnicianRealtimeStatus extends Equatable {
  const TechnicianRealtimeStatus();

  /// Whether the socket is authenticated and usable right now.
  bool get isConnected => false;

  /// Identifies the current connection.
  ///
  /// It changes on every successful (re)connection, which is what lets the
  /// console tell "still the same socket" from "a brand new one that has to
  /// join the session again". Socket.IO rooms die with the connection.
  int? get connectionId => null;

  @override
  List<Object?> get props => const [];
}

/// Nobody asked for a connection, or it was closed on purpose (logout).
final class TechnicianRealtimeDisconnected extends TechnicianRealtimeStatus {
  const TechnicianRealtimeDisconnected();
}

/// First handshake in flight.
final class TechnicianRealtimeConnecting extends TechnicianRealtimeStatus {
  const TechnicianRealtimeConnecting();
}

/// The handshake succeeded and the socket belongs to this technician.
final class TechnicianRealtimeConnected extends TechnicianRealtimeStatus {
  const TechnicianRealtimeConnected(this.connectionId);

  @override
  final int connectionId;

  @override
  bool get isConnected => true;

  @override
  List<Object?> get props => [connectionId];
}

/// The connection dropped and Socket.IO is retrying with its own backoff.
final class TechnicianRealtimeReconnecting extends TechnicianRealtimeStatus {
  const TechnicianRealtimeReconnecting();
}

/// The connection could not be established.
///
/// [isAuthenticationError] separates the two cases that must be handled very
/// differently: a rejected User JWT ends the session — there is no refresh
/// token — while a transport problem must never sign the user out.
final class TechnicianRealtimeConnectionError extends TechnicianRealtimeStatus {
  const TechnicianRealtimeConnectionError({
    required this.isAuthenticationError,
  });

  final bool isAuthenticationError;

  @override
  List<Object?> get props => [isAuthenticationError];
}
