import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/error/failure.dart';
import '../../../../../core/error/result.dart';
import '../../../domain/entities/support_request.dart';
import '../../../domain/entities/support_request_status.dart';
import '../../../domain/usecases/assign_support_request.dart';
import '../../../domain/usecases/load_support_requests.dart';

part 'support_requests_event.dart';
part 'support_requests_state.dart';

/// Message shown after a successful assignment.
///
/// The tablet is notified through its own Socket.IO (`support:assigned`) and
/// the user still has to accept or reject, so the console only waits.
const String kAssignSucceededNotice =
    'Solicitud asignada. Esperando respuesta del usuario en la tablet...';

/// Owns the support request queue of the technician console.
///
/// REST is the source of truth: the queue is loaded on open and reloaded on
/// demand. The only write is `assign`, and at most one may be in flight.
class SupportRequestsBloc
    extends Bloc<SupportRequestsEvent, SupportRequestsState> {
  SupportRequestsBloc({
    required LoadSupportRequests loadSupportRequests,
    required AssignSupportRequest assignSupportRequest,
  }) : _loadSupportRequests = loadSupportRequests,
       _assignSupportRequest = assignSupportRequest,
       super(const SupportRequestsInitial()) {
    on<SupportRequestsRequested>(_onRequested);
    on<SupportRequestsRefreshRequested>(_onRefreshRequested);
    on<SupportRequestAssignRequested>(_onAssignRequested);
    on<SupportRequestsNoticeDismissed>(_onNoticeDismissed);
  }

  final LoadSupportRequests _loadSupportRequests;
  final AssignSupportRequest _assignSupportRequest;

  /// Events are processed concurrently by default, so a second request while
  /// the first one is still in flight would fire a duplicate
  /// `GET /support-requests`.
  bool _isLoading = false;

  Future<void> _onRequested(
    SupportRequestsRequested event,
    Emitter<SupportRequestsState> emit,
  ) async {
    if (_isLoading) return;
    emit(const SupportRequestsLoading());
    await _load(emit);
  }

  Future<void> _onRefreshRequested(
    SupportRequestsRefreshRequested event,
    Emitter<SupportRequestsState> emit,
  ) async {
    if (_isLoading) return;
    final current = state;
    if (current is SupportRequestsLoaded) {
      emit(
        current.copyWith(
          isRefreshing: true,
          clearFailure: true,
          clearNotice: true,
        ),
      );
    } else {
      emit(const SupportRequestsLoading());
    }
    await _load(emit);
  }

  Future<void> _onAssignRequested(
    SupportRequestAssignRequested event,
    Emitter<SupportRequestsState> emit,
  ) async {
    final current = state;
    if (current is! SupportRequestsLoaded) return;
    // One assignment at a time: a second click while the first call is in
    // flight is dropped here, before it reaches the network.
    if (current.isAssigning) return;

    emit(
      current.copyWith(
        assigningRequestId: event.requestId,
        clearFailure: true,
        clearNotice: true,
      ),
    );

    final result = await _assignSupportRequest(requestId: event.requestId);

    switch (result) {
      case Success<SupportRequest>(:final value):
        emit(
          _loadedState().copyWith(
            requests: _replace(value),
            clearAssigningRequestId: true,
            clearFailure: true,
            notice: kAssignSucceededNotice,
          ),
        );
      case Failed<SupportRequest>(:final failure):
        emit(
          _loadedState().copyWith(
            clearAssigningRequestId: true,
            failure: failure,
            clearNotice: true,
          ),
        );
        // The request moved on without us — taken by somebody else, already
        // answered, or the device went offline. Re-read the queue instead of
        // guessing what it looks like now.
        if (failure is ConflictFailure || failure is NotFoundFailure) {
          await _load(emit, keepFailure: true);
        }
    }
  }

  void _onNoticeDismissed(
    SupportRequestsNoticeDismissed event,
    Emitter<SupportRequestsState> emit,
  ) {
    final current = state;
    if (current is! SupportRequestsLoaded) return;
    if (current.failure == null && current.notice == null) return;
    emit(current.copyWith(clearFailure: true, clearNotice: true));
  }

  Future<void> _load(
    Emitter<SupportRequestsState> emit, {
    bool keepFailure = false,
  }) async {
    final previous = state;
    _isLoading = true;
    final Result<List<SupportRequest>> result;
    try {
      result = await _loadSupportRequests();
    } finally {
      _isLoading = false;
    }

    switch (result) {
      case Success<List<SupportRequest>>(:final value):
        final base = previous is SupportRequestsLoaded
            ? previous
            : const SupportRequestsLoaded(requests: []);
        emit(
          base.copyWith(
            requests: value,
            isRefreshing: false,
            clearAssigningRequestId: true,
            clearFailure: !keepFailure,
          ),
        );
      case Failed<List<SupportRequest>>(:final failure):
        // A failed refresh must not throw away the queue the user is reading.
        if (previous is SupportRequestsLoaded) {
          emit(
            previous.copyWith(
              isRefreshing: false,
              clearAssigningRequestId: true,
              failure: keepFailure ? previous.failure ?? failure : failure,
            ),
          );
        } else {
          emit(SupportRequestsFailure(failure));
        }
    }
  }

  SupportRequestsLoaded _loadedState() {
    final current = state;
    return current is SupportRequestsLoaded
        ? current
        : const SupportRequestsLoaded(requests: []);
  }

  /// Replaces the row the backend just returned, keeping the queue order.
  List<SupportRequest> _replace(SupportRequest updated) => _loadedState()
      .requests
      .map((request) => request.id == updated.id ? updated : request)
      .toList(growable: false);
}
