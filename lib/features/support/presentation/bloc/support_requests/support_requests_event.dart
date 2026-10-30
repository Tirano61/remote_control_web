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

/// Re-reads the queue from `GET /support-requests`.
///
/// Dispatched by the ACTUALIZAR buttons and by the console coordinator — on
/// `support-request:updated`, when the tablet answered a request assigned to
/// this technician, on `support-request:queue-updated`, when the shared
/// `WAITING` queue changed, and after a socket reconnection. Polling every few
/// seconds is deliberately not used as a stand-in.
///
/// Asked for while a GET is in flight, it is not dropped: it is coalesced into
/// a single GET that runs as soon as the current one ends.
final class SupportRequestsRefreshRequested extends SupportRequestsEvent {
  const SupportRequestsRefreshRequested();
}

/// The user session ended: a reload coalesced behind the GET in flight is
/// dropped, so no request is made on behalf of a signed-out technician.
final class SupportRequestsPendingRefreshDiscarded extends SupportRequestsEvent {
  const SupportRequestsPendingRefreshDiscarded();
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
