import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/client/technician_realtime_client.dart';
import '../../../domain/entities/technician_realtime_status.dart';

part 'technician_realtime_event.dart';

/// Exposes the `/technicians` connection to the presentation layer.
///
/// The state of this BLoC is the state of the *transport*. It says nothing
/// about being inside a remote session room: "socket connected" and
/// "remote session joined" are different facts, tracked by different BLoCs,
/// because a reconnection keeps the first and destroys the second.
///
/// Nothing here knows what Socket.IO is: the client port hides it.
class TechnicianRealtimeBloc
    extends Bloc<TechnicianRealtimeEvent, TechnicianRealtimeStatus> {
  TechnicianRealtimeBloc({required TechnicianRealtimeClient client})
    : _client = client,
      super(client.status) {
    on<TechnicianRealtimeConnectRequested>(_onConnectRequested);
    on<TechnicianRealtimeDisconnectRequested>(_onDisconnectRequested);
    on<_TechnicianRealtimeStatusReported>(_onStatusReported);

    _statusSubscription = _client.statusChanges.listen(
      (status) => add(_TechnicianRealtimeStatusReported(status)),
    );
  }

  final TechnicianRealtimeClient _client;
  late final StreamSubscription<TechnicianRealtimeStatus> _statusSubscription;

  Future<void> _onConnectRequested(
    TechnicianRealtimeConnectRequested event,
    Emitter<TechnicianRealtimeStatus> emit,
  ) => _client.connect();

  Future<void> _onDisconnectRequested(
    TechnicianRealtimeDisconnectRequested event,
    Emitter<TechnicianRealtimeStatus> emit,
  ) => _client.disconnect();

  void _onStatusReported(
    _TechnicianRealtimeStatusReported event,
    Emitter<TechnicianRealtimeStatus> emit,
  ) => emit(event.status);

  @override
  Future<void> close() async {
    await _statusSubscription.cancel();
    return super.close();
  }
}
