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
///
/// At most one `GET /support-requests` is in flight too. A reload asked for
/// meanwhile — by hand, by `support-request:updated`, by
/// `support-request:queue-updated` or by a reconnection — is
/// neither started next to it nor lost: it is coalesced into one more GET
/// once the current one ends.
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
    on<SupportRequestsPendingRefreshDiscarded>(_onPendingRefreshDiscarded);
  }

  final LoadSupportRequests _loadSupportRequests;
  final AssignSupportRequest _assignSupportRequest;

  /// Events are processed concurrently by default, so a second request while
  /// the first one is still in flight would fire a duplicate
  /// `GET /support-requests`.
  bool _isLoading = false;

  /// A reload was asked for while another one was in flight.
  ///
  /// The in-flight GET may have been read before the change that motivated
  /// the request — a `support-request:updated` emitted right after commit, for
  /// instance — so dropping it could leave the queue stale until somebody
  /// reloads by hand. It is a flag, not a counter: however many requests
  /// arrive during one GET, they are all answered by a single GET after it.
  bool _isRefreshPending = false;

  Future<void> _onRequested(
    SupportRequestsRequested event,
    Emitter<SupportRequestsState> emit,
  ) async {
    if (_deferIfLoading()) return;
    emit(const SupportRequestsLoading());
    await _load(emit);
  }

  Future<void> _onRefreshRequested(
    SupportRequestsRefreshRequested event,
    Emitter<SupportRequestsState> emit,
  ) async {
    if (_deferIfLoading()) return;
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
        if ((failure is ConflictFailure || failure is NotFoundFailure) &&
            !_deferIfLoading()) {
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

  /// The user session is over: whatever was pending is not worth a request.
  ///
  /// A GET already in flight cannot be recalled, but nothing follows it.
  void _onPendingRefreshDiscarded(
    SupportRequestsPendingRefreshDiscarded event,
    Emitter<SupportRequestsState> emit,
  ) => _isRefreshPending = false;

  /// Records a reload for later instead of starting a second GET next to the
  /// one in flight. Answers whether it did.
  bool _deferIfLoading() {
    if (!_isLoading) return false;
    _isRefreshPending = true;
    return true;
  }

  /// Loads the queue, then once more for as long as a reload was asked for
  /// during the previous GET.
  ///
  /// Every pass starts by clearing the flag, so a GET can only be followed by
  /// another one when something asked for it *while it was running*. That is
  /// what bounds a burst to one extra GET and makes a loop impossible: a
  /// failure — network or otherwise — consumes the pending reload and never
  /// creates one. A `401` stops everything; the session is being closed.
  Future<void> _load(
    Emitter<SupportRequestsState> emit, {
    bool keepFailure = false,
  }) async {
    _isLoading = true;
    try {
      do {
        _isRefreshPending = false;
        final isSessionOver = await _loadOnce(emit, keepFailure: keepFailure);
        if (isSessionOver) break;
      } while (_isRefreshPending && !isClosed);
    } finally {
      _isLoading = false;
      _isRefreshPending = false;
    }
  }

  /// One `GET /support-requests`. Answers whether it ended in a `401`.
  Future<bool> _loadOnce(
    Emitter<SupportRequestsState> emit, {
    required bool keepFailure,
  }) async {
    final previous = state;
    final result = await _loadSupportRequests();
    // Another GET follows this one, so the section keeps showing that it is
    // refreshing instead of flickering in between.
    final isFollowedUp = _isRefreshPending && !isClosed;

    switch (result) {
      case Success<List<SupportRequest>>(:final value):
        final base = previous is SupportRequestsLoaded
            ? previous
            : const SupportRequestsLoaded(requests: []);
        emit(
          base.copyWith(
            requests: value,
            isRefreshing: isFollowedUp,
            clearAssigningRequestId: true,
            clearFailure: !keepFailure,
          ),
        );
        return false;
      case Failed<List<SupportRequest>>(:final failure):
        if (failure is AuthFailure) _isRefreshPending = false;
        // A failed refresh must not throw away the queue the user is reading.
        if (previous is SupportRequestsLoaded) {
          emit(
            previous.copyWith(
              isRefreshing: isFollowedUp && failure is! AuthFailure,
              clearAssigningRequestId: true,
              failure: keepFailure ? previous.failure ?? failure : failure,
            ),
          );
        } else if (!isFollowedUp || failure is AuthFailure) {
          // A first load that will be retried right away stays `Loading`.
          emit(SupportRequestsFailure(failure));
        }
        return failure is AuthFailure;
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
