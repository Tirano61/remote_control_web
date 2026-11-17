part of 'devices_bloc.dart';

sealed class DevicesEvent extends Equatable {
  const DevicesEvent();

  @override
  List<Object?> get props => const [];
}

/// First load, dispatched when the console opens.
final class DevicesRequested extends DevicesEvent {
  const DevicesRequested();
}

/// Re-reads the list from `GET /devices`.
///
/// Dispatched by the ACTUALIZAR buttons and by the console coordinator — on
/// `device:presence-updated`, when the presence of a device changed, and after
/// a socket reconnection, when such events may have been lost. Polling every
/// few seconds is deliberately not used as a stand-in.
///
/// Asked for while a GET is in flight, it is not dropped: it is coalesced into
/// a single GET that runs as soon as the current one ends.
final class DevicesRefreshRequested extends DevicesEvent {
  const DevicesRefreshRequested();
}

/// The user session ended: a reload coalesced behind the GET in flight is
/// dropped, so no request is made on behalf of a signed-out technician.
final class DevicesPendingRefreshDiscarded extends DevicesEvent {
  const DevicesPendingRefreshDiscarded();
}
