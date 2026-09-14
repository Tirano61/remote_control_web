import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/error/failure.dart';
import '../../../../../core/error/result.dart';
import '../../../domain/entities/device.dart';
import '../../../domain/usecases/load_devices.dart';

part 'devices_event.dart';
part 'devices_state.dart';

/// Owns the device list of the technician console.
///
/// It only reads: `isOnline` is backend presence and is never computed here.
/// Refreshing is explicit, so no timer and no polling exist in this BLoC.
class DevicesBloc extends Bloc<DevicesEvent, DevicesState> {
  DevicesBloc({required LoadDevices loadDevices})
    : _loadDevices = loadDevices,
      super(const DevicesInitial()) {
    on<DevicesRequested>(_onRequested);
    on<DevicesRefreshRequested>(_onRefreshRequested);
  }

  final LoadDevices _loadDevices;

  /// Events are processed concurrently by default, so a second request while
  /// the first one is still in flight would fire a duplicate `GET /devices`.
  bool _isLoading = false;

  Future<void> _onRequested(
    DevicesRequested event,
    Emitter<DevicesState> emit,
  ) async {
    if (_isLoading) return;
    emit(const DevicesLoading());
    await _load(emit);
  }

  Future<void> _onRefreshRequested(
    DevicesRefreshRequested event,
    Emitter<DevicesState> emit,
  ) async {
    if (_isLoading) return;
    final current = state;
    if (current is DevicesLoaded) {
      emit(current.copyWith(isRefreshing: true, clearRefreshFailure: true));
    } else {
      emit(const DevicesLoading());
    }
    await _load(emit);
  }

  Future<void> _load(Emitter<DevicesState> emit) async {
    final previous = state;
    _isLoading = true;
    final Result<List<Device>> result;
    try {
      result = await _loadDevices();
    } finally {
      _isLoading = false;
    }

    switch (result) {
      case Success<List<Device>>(:final value):
        emit(DevicesLoaded(devices: value));
      case Failed<List<Device>>(:final failure):
        // A failed refresh must not throw away the rows the user is looking at.
        if (previous is DevicesLoaded) {
          emit(previous.copyWith(isRefreshing: false, refreshFailure: failure));
        } else {
          emit(DevicesFailure(failure));
        }
    }
  }
}
