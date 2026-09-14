part of 'support_requests_bloc.dart';

sealed class SupportRequestsEvent extends Equatable {
  const SupportRequestsEvent();

  @override
  List<Object?> get props => const [];
}

/// First load, dispatched when the console opens.
final class SupportRequestsRequested extends SupportRequestsEvent {
  const SupportRequestsRequested();
}

/// Manual refresh.
///
/// There is no `/technicians` Socket.IO in the web client yet, so a state
/// change made on the tablet (accept/reject) becomes visible only after an
/// explicit reload. Polling every few seconds is deliberately not used as a
/// stand-in for realtime.
final class SupportRequestsRefreshRequested extends SupportRequestsEvent {
  const SupportRequestsRefreshRequested();
}

/// The technician pressed "TOMAR SOLICITUD" on a request.
final class SupportRequestAssignRequested extends SupportRequestsEvent {
  const SupportRequestAssignRequested(this.requestId);

  final String requestId;

  @override
  List<Object?> get props => [requestId];
}

/// The user dismissed the success/error banner.
final class SupportRequestsNoticeDismissed extends SupportRequestsEvent {
  const SupportRequestsNoticeDismissed();
}
