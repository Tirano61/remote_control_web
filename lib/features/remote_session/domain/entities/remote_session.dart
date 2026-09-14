import 'package:equatable/equatable.dart';

import 'remote_session_device.dart';
import 'remote_session_ended_by.dart';
import 'remote_session_status.dart';
import 'remote_session_technician.dart';

/// A remote session as returned by `POST /remote-sessions`,
/// `GET /remote-sessions/current` and `POST /remote-sessions/:id/close`.
///
/// All three answer the same object; `GET /remote-sessions/current` wraps it in
/// a `{ "remoteSession": ... | null }` envelope.
///
/// Only fields documented in `docs/backend/ENDPOINTS.md` exist here.
class RemoteSession extends Equatable {
  const RemoteSession({
    required this.id,
    required this.supportRequestId,
    required this.status,
    required this.createdAt,
    this.connectedAt,
    this.endedAt,
    this.endedBy,
    this.device,
    this.technician,
  });

  final String id;

  /// The `ACCEPTED` support request this session was started from.
  final String supportRequestId;

  final RemoteSessionStatus status;
  final DateTime createdAt;

  /// Set when the session reaches `ACTIVE`. No backend code path does that yet.
  final DateTime? connectedAt;

  final DateTime? endedAt;
  final RemoteSessionEndedBy? endedBy;

  final RemoteSessionDevice? device;
  final RemoteSessionTechnician? technician;

  /// Whether the session is still open (`CONNECTING` or `ACTIVE`).
  bool get isLive => status.isLive;

  bool get isConnecting => status == RemoteSessionStatus.connecting;

  bool get isActive => status == RemoteSessionStatus.active;

  bool get isClosed => status == RemoteSessionStatus.closed;

  /// Name shown in the assistance view, falling back to the readable device id.
  String get deviceLabel => device?.displayName ?? 'Dispositivo';

  String? get devicePublicId => device?.publicId;

  @override
  List<Object?> get props => [
    id,
    supportRequestId,
    status,
    createdAt,
    connectedAt,
    endedAt,
    endedBy,
    device,
    technician,
  ];

  @override
  String toString() =>
      'RemoteSession(id: $id, status: ${status.wireValue}, '
      'supportRequestId: $supportRequestId)';
}
