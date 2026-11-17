import 'package:equatable/equatable.dart';

/// The `device:presence-updated` notification of the `/technicians` namespace:
/// `{ "deviceId": "..." }`.
///
/// It says one thing only: the effective presence of that device changed —
/// its first `/devices` socket was registered, or its last one went away. It
/// does **not** say which way, and it deliberately has no `isOnline`.
///
/// It is **an invalidation, never the state**. Presence is what
/// `GET /devices` (`Device.isOnline`) and `GET /support-requests`
/// (`SupportRequest.device.isOnline`) answer, so the console re-reads both and
/// never toggles a flag from the event. Two quick transitions produce two
/// events, and only REST knows which one is current.
///
/// Presence is "connected to the backend". It says nothing about the screen
/// being shared, the accessibility service, an accepted assistance or a
/// WebRTC session.
class DevicePresenceUpdatedNotice extends Equatable {
  const DevicePresenceUpdatedNotice({required this.deviceId});

  /// Internal `Device.id`.
  final String deviceId;

  @override
  List<Object?> get props => [deviceId];

  @override
  String toString() => 'DevicePresenceUpdatedNotice(deviceId: $deviceId)';
}
