import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/logging/debug_log.dart';
import '../../../../devices/presentation/bloc/devices/devices_bloc.dart';
import '../../../../technician_realtime/domain/entities/remote_session_peer_joined_notice.dart';
import '../../../../technician_realtime/presentation/bloc/signaling_join/signaling_join_bloc.dart';
import '../../../../technician_realtime/presentation/bloc/technician_realtime/technician_realtime_bloc.dart';
import '../../../../webrtc/presentation/bloc/webrtc_session/webrtc_session_bloc.dart';
import '../../transmission/remote_transmission_monitor.dart';
import '../../transmission/remote_transmission_status.dart';
import '../remote_session/remote_session_bloc.dart';

/// Publishes what the console can say about the tablet's screen.
///
/// A reader, never a writer: it listens to the BLoCs the console already has
/// and to `remote-session:peer-joined`, and adds no event to any of them. In
/// particular it never touches remote control, which keeps being decided by
/// the coordinator alone. Every state of every input is looked at — none is
/// coalesced away — because a read that started and ended matters, not only
/// the last value.
class RemoteTransmissionCubit extends Cubit<RemoteTransmissionStatus> {
  RemoteTransmissionCubit({
    required RemoteSessionBloc remoteSessionBloc,
    required WebRtcSessionBloc webRtcSessionBloc,
    required TechnicianRealtimeBloc technicianRealtimeBloc,
    required DevicesBloc devicesBloc,
    required SignalingJoinBloc signalingJoinBloc,
    required Stream<RemoteSessionPeerJoinedNotice> peerJoined,
    RemoteTransmissionMonitor? monitor,
  }) : _remoteSessionBloc = remoteSessionBloc,
       _webRtcSessionBloc = webRtcSessionBloc,
       _technicianRealtimeBloc = technicianRealtimeBloc,
       _devicesBloc = devicesBloc,
       _signalingJoinBloc = signalingJoinBloc,
       _monitor = monitor ?? RemoteTransmissionMonitor(),
       super(RemoteTransmissionStatus.hidden) {
    _subscriptions.addAll([
      remoteSessionBloc.stream.listen((_) => _observe()),
      webRtcSessionBloc.stream.listen((_) => _observe()),
      technicianRealtimeBloc.stream.listen((_) => _observe()),
      devicesBloc.stream.listen((_) => _observe()),
      signalingJoinBloc.stream.listen((_) => _observe()),
      peerJoined.listen(
        (notice) => _publish(_monitor.peerJoined(notice.remoteSessionId)),
      ),
    ]);
    _observe();
  }

  final RemoteSessionBloc _remoteSessionBloc;
  final WebRtcSessionBloc _webRtcSessionBloc;
  final TechnicianRealtimeBloc _technicianRealtimeBloc;
  final DevicesBloc _devicesBloc;
  final SignalingJoinBloc _signalingJoinBloc;
  final RemoteTransmissionMonitor _monitor;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  void _observe() => _publish(
    _monitor.observe(
      RemoteTransmissionSignals(
        session: _remoteSessionBloc.state,
        webRtc: _webRtcSessionBloc.state,
        realtime: _technicianRealtimeBloc.state,
        devices: _devicesBloc.state,
        join: _signalingJoinBloc.state,
      ),
    ),
  );

  void _publish(RemoteTransmissionStatus next) {
    if (isClosed || next == state) return;
    // Identifiers only: the session id, the phase and its cause.
    if (next.remoteSessionId != null) {
      logDebug('transmission $next ${next.remoteSessionId}');
    }
    emit(next);
  }

  @override
  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    return super.close();
  }
}
