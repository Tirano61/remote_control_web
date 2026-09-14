part of 'technician_realtime_bloc.dart';

sealed class TechnicianRealtimeEvent extends Equatable {
  const TechnicianRealtimeEvent();

  @override
  List<Object?> get props => const [];
}

/// The user is authenticated: open `/technicians`.
///
/// It does not wait for a remote session. The namespace also carries domain
/// notifications addressed to the technician, which must be received whether
/// or not an assistance is open.
final class TechnicianRealtimeConnectRequested extends TechnicianRealtimeEvent {
  const TechnicianRealtimeConnectRequested();
}

/// The user session ended: close the socket and stop reconnecting.
final class TechnicianRealtimeDisconnectRequested
    extends TechnicianRealtimeEvent {
  const TechnicianRealtimeDisconnectRequested();
}

/// The transport reported a new state. Internal: only the client raises it.
final class _TechnicianRealtimeStatusReported extends TechnicianRealtimeEvent {
  const _TechnicianRealtimeStatusReported(this.status);

  final TechnicianRealtimeStatus status;

  @override
  List<Object?> get props => [status];
}
