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
/// It only reads: `isOnline` is backend presence and is never computed here,
/// nor taken from a realtime event. Refreshing is explicit — the ACTUALIZAR
/// button, or the console coordinator on `device:presence-updated` and after a
/// socket reconnection — so no timer and no polling exist in this BLoC.
///
/// At most one `GET /devices` is in flight. A reload asked for meanwhile is
/// neither started next to it nor lost: it is coalesced into one more GET once
/// the current one ends. That is what keeps a presence change from being
/// missed when its event arrives while an older GET — possibly read before
/// the change — is still running, and it also means responses are applied in
/// the order their requests were made, so an older answer can never overwrite
/// a newer one.
class DevicesBloc extends Bloc<DevicesEvent, DevicesState> {
  DevicesBloc({required LoadDevices loadDevices})
    : _loadDevices = loadDevices,
      super(const DevicesInitial()) {
    on<DevicesRequested>(_onRequested);
    on<DevicesRefreshRequested>(_onRefreshRequested);
    on<DevicesPendingRefreshDiscarded>(_onPendingRefreshDiscarded);
  }

  final LoadDevices _loadDevices;

  /// Events are processed concurrently by default, so a second request while
  /// the first one is still in flight would fire a duplicate `GET /devices`.
  bool _isLoading = false;

  /// A reload was asked for while another one was in flight.
  ///
  /// It is a flag, not a counter or a queue: however many requests arrive
  /// during one GET — a burst of `device:presence-updated` for one tablet or
  /// for several — they are all answered by a single GET after it, because
  /// that GET reads the whole list as it is *then*.
  bool _isRefreshPending = false;

  Future<void> _onRequested(
    DevicesRequested event,
    Emitter<DevicesState> emit,
  ) async {
    if (_deferIfLoading()) return;
    emit(const DevicesLoading());
    await _load(emit);
  }

  Future<void> _onRefreshRequested(
    DevicesRefreshRequested event,
    Emitter<DevicesState> emit,
  ) async {
    if (_deferIfLoading()) return;
    final current = state;
    if (current is DevicesLoaded) {
      emit(current.copyWith(isRefreshing: true, clearRefreshFailure: true));
    } else {
      emit(const DevicesLoading());
    }
    await _load(emit);
  }

  /// The user session is over: whatever was pending is not worth a request.
  ///
  /// A GET already in flight cannot be recalled, but nothing follows it.
  void _onPendingRefreshDiscarded(
    DevicesPendingRefreshDiscarded event,
    Emitter<DevicesState> emit,
  ) => _isRefreshPending = false;

  /// Records a reload for later instead of starting a second GET next to the
  /// one in flight. Answers whether it did.
  bool _deferIfLoading() {
    if (!_isLoading) return false;
    _isRefreshPending = true;
    return true;
  }

  /// Loads the list, then once more for as long as a reload was asked for
  /// during the previous GET.
  ///
  /// Every pass starts by clearing the flag, so a GET can only be followed by
  /// another one when something asked for it *while it was running*. That
  /// bounds a burst to one extra GET and makes a loop impossible: a failure —
  /// network or otherwise — consumes the pending reload and never creates one.
  /// A `401` stops everything; the session is being closed.
  Future<void> _load(Emitter<DevicesState> emit) async {
    _isLoading = true;
    try {
      do {
        _isRefreshPending = false;
        final isSessionOver = await _loadOnce(emit);
        if (isSessionOver) break;
      } while (_isRefreshPending && !isClosed);
    } finally {
      _isLoading = false;
      _isRefreshPending = false;
    }
  }

  /// One `GET /devices`. Answers whether it ended in a `401`.
  Future<bool> _loadOnce(Emitter<DevicesState> emit) async {
    final previous = state;
    final result = await _loadDevices();
    // Another GET follows this one, so the section keeps showing that it is
    // refreshing instead of flickering in between.
    final isFollowedUp = _isRefreshPending && !isClosed;

    switch (result) {
      case Success<List<Device>>(:final value):
        emit(DevicesLoaded(devices: value, isRefreshing: isFollowedUp));
        return false;
      case Failed<List<Device>>(:final failure):
        final isAuthFailure = failure is AuthFailure;
        if (isAuthFailure) _isRefreshPending = false;
        // A failed refresh must not throw away the rows the user is looking at.
        if (previous is DevicesLoaded) {
          emit(
            previous.copyWith(
              isRefreshing: isFollowedUp && !isAuthFailure,
              refreshFailure: failure,
            ),
          );
        } else if (!isFollowedUp || isAuthFailure) {
          // A first load that will be retried right away stays `Loading`.
          emit(DevicesFailure(failure));
        }
        return isAuthFailure;
    }
  }
}
