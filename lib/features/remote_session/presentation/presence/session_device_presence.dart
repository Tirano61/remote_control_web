import '../../../devices/presentation/bloc/devices/devices_bloc.dart';
import '../../domain/entities/remote_session_device.dart';

/// Whether the device of the assistance on screen is `ONLINE`, as shown in the
/// header of the assistance.
///
/// Two answers of the backend carry it: `RemoteSession.device.isOnline`, from
/// `GET /remote-sessions/current`, and `Device.isOnline`, from `GET /devices`.
/// Only the second one is re-read on `device:presence-updated` — and after a
/// socket reconnection — and the [DevicesBloc] applies its answers in the order
/// they were asked for, a GET that started before a presence change always
/// being followed by one that started after it. So the device list is the
/// freshest answer the console holds about presence, and the one the header
/// shows; the session's own copy is the fallback while the list does not
/// contain the device (not loaded yet, or failed).
///
/// Reusing that read is deliberate: `device:presence-updated` costs no extra
/// request for the header, and the header can never disagree with the device
/// list next to it.
///
/// Presence is information, and only that. `ONLINE` means the tablet holds a
/// socket to the backend; it says nothing about the session being `ACTIVE`,
/// remote control being allowed, or the screen being shared — none of which is
/// ever decided from it.
bool isSessionDeviceOnline(RemoteSessionDevice device, DevicesState devices) {
  if (devices is DevicesLoaded) {
    for (final listed in devices.devices) {
      if (listed.id == device.id) return listed.isOnline;
    }
  }
  return device.isOnline;
}
