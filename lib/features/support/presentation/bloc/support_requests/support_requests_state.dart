part of 'support_requests_bloc.dart';

sealed class SupportRequestsState extends Equatable {
  const SupportRequestsState();

  /// The last failure the user still has to be told about, if any.
  ///
  /// The console watches it: an [AuthFailure] ends the session, a
  /// [ForbiddenFailure] does not.
  Failure? get lastFailure => null;

  @override
  List<Object?> get props => const [];
}

/// Nothing has been requested yet.
final class SupportRequestsInitial extends SupportRequestsState {
  const SupportRequestsInitial();
}

/// First load in flight.
final class SupportRequestsLoading extends SupportRequestsState {
  const SupportRequestsLoading();
}

/// The queue is available.
final class SupportRequestsLoaded extends SupportRequestsState {
  const SupportRequestsLoaded({
    required this.requests,
    this.isRefreshing = false,
    this.assigningRequestId,
    this.failure,
    this.notice,
  });

  /// The whole queue as returned by the backend, oldest first.
  final List<SupportRequest> requests;

  final bool isRefreshing;

  /// Id of the request whose `assign` call is in flight, if any.
  ///
  /// Only one assignment may be running at a time, which is what stops a
  /// double click from sending two requests.
  final String? assigningRequestId;

  /// Failure of the last refresh or assignment.
  final Failure? failure;

  /// Success message, e.g. after taking a request.
  final String? notice;

  bool get isAssigning => assigningRequestId != null;

  bool isAssigningRequest(String id) => assigningRequestId == id;

  /// Requests nobody has taken yet.
  List<SupportRequest> get waiting => requests
      .where((request) => request.status == SupportRequestStatus.waiting)
      .toList(growable: false);

  /// Requests taken but not answered yet by the user of the tablet.
  List<SupportRequest> get assigned => requests
      .where((request) => request.status == SupportRequestStatus.assigned)
      .toList(growable: false);

  /// Requests the user of the tablet authorised.
  List<SupportRequest> get accepted => requests
      .where((request) => request.status == SupportRequestStatus.accepted)
      .toList(growable: false);

  /// `ASSIGNED` / `ACCEPTED` requests belonging to the signed-in technician.
  ///
  /// [userId] comes from the authenticated backend identity and is used only to
  /// decide what to show.
  List<SupportRequest> assignedTo(String userId) => requests
      .where(
        (request) =>
            request.isActive &&
            !request.isWaiting &&
            request.isAssignedTo(userId),
      )
      .toList(growable: false);

  /// Closed requests, newest first, shown as history.
  List<SupportRequest> get history {
    final closed = requests
        .where((request) => request.isTerminal)
        .toList(growable: true)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return List.unmodifiable(closed);
  }

  @override
  Failure? get lastFailure => failure;

  SupportRequestsLoaded copyWith({
    List<SupportRequest>? requests,
    bool? isRefreshing,
    String? assigningRequestId,
    bool clearAssigningRequestId = false,
    Failure? failure,
    bool clearFailure = false,
    String? notice,
    bool clearNotice = false,
  }) => SupportRequestsLoaded(
    requests: requests ?? this.requests,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    assigningRequestId: clearAssigningRequestId
        ? null
        : assigningRequestId ?? this.assigningRequestId,
    failure: clearFailure ? null : failure ?? this.failure,
    notice: clearNotice ? null : notice ?? this.notice,
  );

  @override
  List<Object?> get props => [
    requests,
    isRefreshing,
    assigningRequestId,
    failure,
    notice,
  ];
}

/// The queue could not be loaded and there is nothing to show.
final class SupportRequestsFailure extends SupportRequestsState {
  const SupportRequestsFailure(this.failure);

  final Failure failure;

  @override
  Failure? get lastFailure => failure;

  @override
  List<Object?> get props => [failure];
}
