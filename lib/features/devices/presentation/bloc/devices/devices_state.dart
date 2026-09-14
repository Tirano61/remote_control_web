part of 'devices_bloc.dart';

sealed class DevicesState extends Equatable {
  const DevicesState();

  /// The last failure the user still has to be told about, if any.
  ///
  /// The console watches it to detect an [AuthFailure], which means the User
  /// JWT stopped being valid and the whole session must end.
  Failure? get lastFailure => null;

  @override
  List<Object?> get props => const [];
}

/// Nothing has been requested yet.
final class DevicesInitial extends DevicesState {
  const DevicesInitial();
}

/// First load in flight; there is no list to show meanwhile.
final class DevicesLoading extends DevicesState {
  const DevicesLoading();
}

/// A device list is available.
///
/// A failed refresh keeps the previously loaded rows visible and reports the
/// problem through [lastFailure] instead of blanking the table.
final class DevicesLoaded extends DevicesState {
  const DevicesLoaded({
    required this.devices,
    this.isRefreshing = false,
    this.refreshFailure,
  });

  final List<Device> devices;
  final bool isRefreshing;
  final Failure? refreshFailure;

  int get onlineCount => devices.where((device) => device.isOnline).length;

  @override
  Failure? get lastFailure => refreshFailure;

  DevicesLoaded copyWith({
    List<Device>? devices,
    bool? isRefreshing,
    Failure? refreshFailure,
    bool clearRefreshFailure = false,
  }) => DevicesLoaded(
    devices: devices ?? this.devices,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    refreshFailure: clearRefreshFailure
        ? null
        : refreshFailure ?? this.refreshFailure,
  );

  @override
  List<Object?> get props => [devices, isRefreshing, refreshFailure];
}

/// The list could not be loaded and there is nothing to show.
final class DevicesFailure extends DevicesState {
  const DevicesFailure(this.failure);

  final Failure failure;

  @override
  Failure? get lastFailure => failure;

  @override
  List<Object?> get props => [failure];
}
