import 'package:equatable/equatable.dart';

/// The `support-request:updated` notification of the `/technicians`
/// namespace: `{ "supportRequestId": "..." }`.
///
/// It says one thing only: the tablet moved a support request assigned to
/// this technician — `ACCEPTED`, `REJECTED` or `CANCELLED` — and the change is
/// already committed.
///
/// It is **a trigger, never the state**. It carries no status, so the console
/// never looks the request up and rewrites it: it re-reads
/// `GET /support-requests` and shows what REST answers.
///
/// It is also not authorization, and carries no ownership: the backend
/// addresses it to the assigned technician, and the id is never adopted.
class SupportRequestUpdatedNotice extends Equatable {
  const SupportRequestUpdatedNotice({required this.supportRequestId});

  final String supportRequestId;

  @override
  List<Object?> get props => [supportRequestId];

  @override
  String toString() =>
      'SupportRequestUpdatedNotice(supportRequestId: $supportRequestId)';
}
