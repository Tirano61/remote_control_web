import 'package:equatable/equatable.dart';

/// The `support-request:queue-updated` notification of the `/technicians`
/// namespace: `{ "supportRequestId": "..." }`.
///
/// It says one thing only: the shared `WAITING` queue changed — a request
/// entered it, or left it because a technician took it or the tablet
/// cancelled it — and the change is already committed.
///
/// It is **a trigger, never the state**. It carries no status, no device and
/// no technician, so the console never adds, removes or rewrites a row from
/// it: it re-reads `GET /support-requests` and shows what REST answers.
///
/// It is deliberately not a `SupportRequestUpdatedNotice`: that one is
/// addressed to the technician who owns an already assigned request, while
/// this one reaches every technician and admin. Both end in the same GET
/// today, but they mean different things.
class SupportRequestQueueUpdatedNotice extends Equatable {
  const SupportRequestQueueUpdatedNotice({required this.supportRequestId});

  final String supportRequestId;

  @override
  List<Object?> get props => [supportRequestId];

  @override
  String toString() =>
      'SupportRequestQueueUpdatedNotice(supportRequestId: $supportRequestId)';
}
