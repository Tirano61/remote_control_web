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

/// Manual refresh. There is no realtime presence in the web client yet, so the
/// list is only as fresh as the last explicit reload; polling is deliberately
/// avoided.
final class DevicesRefreshRequested extends DevicesEvent {
  const DevicesRefreshRequested();
}
